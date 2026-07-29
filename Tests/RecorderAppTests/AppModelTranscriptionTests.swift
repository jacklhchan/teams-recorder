import XCTest
@testable import RecorderApp

@MainActor
final class AppModelTranscriptionTests: XCTestCase {
    func testPreparedAudioIsPassedToLauncherAndCleanedAfterSuccess() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "prepared audio cleaned")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)
        let transcriptURL = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        try "done".write(to: transcriptURL, atomically: true, encoding: .utf8)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        XCTAssertEqual(launcher.requests.last?.audioURL, fixture.temporaryAudioURL)
        XCTAssertEqual(launcher.requests.last?.folderURL, fixture.session.folderURL)
        process.complete(exitStatus: 0, output: "TRANSCRIPT_PATH=\(transcriptURL.path)")

        await fulfillment(of: [cleanup], timeout: 1)
        XCTAssertEqual(preparer.cleaned, [.init(audioURL: fixture.temporaryAudioURL, cleanupURL: fixture.temporaryAudioURL)])
        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .completed)
    }

    func testSavedProfileAllowsTranscriptionWhenAPIKeyStatusFails() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let repository = RecordingProviderRepository(
            profile: try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example.com/v1",
                asrModel: "asr",
                llmModel: "llm",
                language: "",
                prompt: ""
            ),
            apiKeyStatusError: TestError.failed
        )
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        guard model.aiProviderSettingsModel.hasSavedProfile else {
            XCTFail("A saved profile must remain available when API key status fails")
            return
        }
        model.transcribe(session: fixture.session)

        let process = await launcher.nextProcess()
        process.complete(exitStatus: 0)
        await waitForIdle(model)
    }

    func testCancelDuringPreparationCancelsWithoutLaunchingAndSettlesState() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let started = expectation(description: "prepare started")
        let preparer = ControlledPreparer(.suspended(started: started))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        await fulfillment(of: [started], timeout: 1)
        model.cancelTranscription()
        await waitForIdle(model)

        XCTAssertTrue(preparer.cancelled)
        XCTAssertTrue(launcher.requests.isEmpty)
        XCTAssertTrue(preparer.cleaned.isEmpty)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .cancelled)
    }

    func testReleasingModelDuringPreparationCancelsWithoutRetainCycle() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let started = expectation(description: "prepare started")
        let preparer = ControlledPreparer(.suspended(started: started))
        let launcher = ControlledLauncher()
        var model: AppModel? = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher
        )
        weak let weakModel = model

        model?.transcribe(session: fixture.session)
        await fulfillment(of: [started], timeout: 1)
        model = nil

        let released = await eventually { weakModel == nil }
        XCTAssertTrue(released, "The transcription task must not retain AppModel while preparation is suspended")
        if !released {
            weakModel?.cancelTranscription()
        }
        XCTAssertTrue(preparer.cancelled)
        XCTAssertTrue(launcher.requests.isEmpty)
    }

    func testCompleteDrainedOutputIsParsedBeforeAttemptClears() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)
        let transcriptURL = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        try "done".write(to: transcriptURL, atomically: true, encoding: .utf8)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 0,
            output: "STATUS=Processing transcript\nTRANSCRIPT_PATH=\(transcriptURL.path)"
        )
        await waitForIdle(model)

        XCTAssertEqual(model.transcriptURLsBySessionID[fixture.session.id], transcriptURL)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .completed)
    }

    func testProviderSnapshotIsCapturedBeforeAudioPreparation() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let started = expectation(description: "prepare started")
        let first = try makeSnapshot(asrModel: "first-model")
        let repository = SnapshotProviderRepository(snapshot: first)
        let preparer = ControlledPreparer(.suspended(started: started))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        model.transcribe(session: fixture.session)
        await fulfillment(of: [started])
        repository.snapshotValue = try makeSnapshot(asrModel: "second-model")
        preparer.resume(.success(.init(audioURL: fixture.temporaryAudioURL, cleanupURL: nil)))
        _ = await launcher.nextProcess()

        let payload = try JSONDecoder().decode(
            OpenAICompatibleTranscriptionLaunchPayload.self,
            from: try XCTUnwrap(launcher.requests.last?.configurationInput)
        )
        XCTAssertEqual(payload.asrModel, "first-model")
    }

    func testMissingProfileFailsBeforeAudioPreparation() throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let repository = SnapshotProviderRepository(
            profile: try makeProfile(),
            snapshotError: ProviderRepositoryError.missingProfile
        )
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        model.transcribe(session: fixture.session)

        XCTAssertTrue(preparer.requests.isEmpty)
        XCTAssertTrue(model.lastTranscriptionDidFail)
        XCTAssertTrue(model.lastTranscriptionStatus.contains("Configure"))
    }

    func testTranscriptPathOutsideSessionFolderIsRejected() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(exitStatus: 0, output: "TRANSCRIPT_PATH=/tmp/untrusted.txt")
        await waitForIdle(model)

        XCTAssertNil(model.transcriptURLsBySessionID[fixture.session.id])
        XCTAssertTrue(model.lastTranscriptionDidFail)
    }

    func testLogSymlinkEscapingSessionFolderIsRejected() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.log")
        try Data().write(to: outside)
        let link = fixture.session.folderURL.appendingPathComponent("transcription.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(exitStatus: 0, output: "LOG_PATH=\(link.path)")
        await waitForIdle(model)

        XCTAssertNil(model.transcriptLogURLsBySessionID[fixture.session.id])
        XCTAssertTrue(model.lastTranscriptionDidFail)
    }

    func testFinalResultLinesPublishTranscriptEvenWhenLiveCallbackIsDelayed() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let transcript = fixture.session.folderURL.appendingPathComponent("transcript.txt")
        try "done".write(to: transcript, atomically: true, encoding: .utf8)
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 0,
            output: "TRANSCRIPT_PATH=\(transcript.path)",
            deliverLiveCallbacks: false
        )
        await waitForIdle(model)

        XCTAssertEqual(model.transcriptURLsBySessionID[fixture.session.id], transcript)
        XCTAssertFalse(model.lastTranscriptionDidFail)
    }

    func testCancelAfterLaunchTerminatesOnceAndCleansPreparedAudio() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "cleanup after cancellation")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        model.cancelTranscription()
        await fulfillment(of: [cleanup], timeout: 1)

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .cancelled)
    }

    func testCancelRejectsTranscriptPathArrivingInFinalProcessOutput() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let transcriptURL = fixture.root.appendingPathComponent("cancelled-transcript.txt")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher(
            processTerminationOutput: "TRANSCRIPT_PATH=\(transcriptURL.path)"
        )
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        _ = await launcher.nextProcess()
        model.cancelTranscription()
        await waitForIdle(model)

        XCTAssertNil(model.transcriptURLsBySessionID[fixture.session.id])
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .cancelled)
    }

    func testPreparationFailureClearsActiveOwnerWithoutCleanup() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.failure(TestError.failed)))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        await waitForIdle(model)

        XCTAssertTrue(launcher.requests.isEmpty)
        XCTAssertTrue(preparer.cleaned.isEmpty)
        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
    }

    func testLaunchFailureCleansPreparedAudioAndClearsActiveOwner() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "cleanup after launch failure")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher(makeError: TestError.failed)
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        await fulfillment(of: [cleanup], timeout: 1)

        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
    }

    func testProcessRunFailureCleansPreparedAudioAndClearsActiveOwner() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let cleanup = expectation(description: "cleanup after process run failure")
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))), cleanup: cleanup)
        let launcher = ControlledLauncher(processRunError: TestError.failed)
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        _ = await launcher.nextProcess()
        await fulfillment(of: [cleanup], timeout: 1)

        XCTAssertNil(model.transcribingSessionID)
        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
        XCTAssertTrue(model.lastTranscriptionStatus.hasPrefix("Transcription launch failed"))
    }

    func testStaleOutputAndCompletionCannotMutateNewerAttempt() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let first = await launcher.nextProcess()
        first.complete(exitStatus: 0)
        await waitForIdle(model)

        model.transcribe(session: fixture.session)
        let second = await launcher.nextProcess()
        first.emit("STATUS=old output\nTRANSCRIPT_PATH=/tmp/old.txt\n")
        first.complete(exitStatus: 9)
        await Task.yield()

        XCTAssertEqual(model.transcribingSessionID, fixture.session.id)
        XCTAssertNotEqual(model.transcriptionStatus, "old output")
        XCTAssertNil(model.transcriptURLsBySessionID[fixture.session.id])
        second.complete(exitStatus: 0)
        await waitForIdle(model)
    }

    func testNonzeroExitPersistsFailure() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: fixture.temporaryAudioURL
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(fixture: fixture, preparer: preparer, launcher: launcher)

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(exitStatus: 7)
        await waitForIdle(model)

        XCTAssertEqual(model.transcriptionStatesBySessionID[fixture.session.id]?.phase, .failed)
        XCTAssertTrue(model.lastTranscriptionStatus.contains("exit code 7"))
    }

    func testProviderErrorContainingSnapshotAPIKeyIsNotPublishedOrPersisted() async throws {
        let fixture = try TranscriptionFixture.make()
        defer { fixture.remove() }
        let secret = "exact-private-api-key"
        let repository = SnapshotProviderRepository(
            snapshot: .init(profile: try makeProfile(), apiKey: secret)
        )
        let preparer = ControlledPreparer(.immediate(.success(.init(
            audioURL: fixture.temporaryAudioURL,
            cleanupURL: nil
        ))))
        let launcher = ControlledLauncher()
        let model = makeModel(
            fixture: fixture,
            preparer: preparer,
            launcher: launcher,
            repository: repository,
            configureProvider: false
        )
        model.aiProviderSettingsModel.reload()

        model.transcribe(session: fixture.session)
        let process = await launcher.nextProcess()
        process.complete(
            exitStatus: 7,
            output: "ERROR=Provider rejected \(secret) while uploading"
        )
        await waitForIdle(model)

        let persisted = try XCTUnwrap(
            try TranscriptionStateStore.load(in: fixture.session.folderURL)
        )
        XCTAssertFalse(model.transcriptionStatus.contains(secret))
        XCTAssertFalse(model.lastTranscriptionStatus.contains(secret))
        XCTAssertFalse(model.statusMessage.contains(secret))
        XCTAssertFalse(persisted.message.contains(secret))
    }

    private func makeModel(
        fixture: TranscriptionFixture,
        preparer: ControlledPreparer,
        launcher: ControlledLauncher,
        repository: any OpenAICompatibleProviderManaging = RecordingProviderRepository(),
        configureProvider: Bool = true
    ) -> AppModel {
        let model = AppModel(
            providerRepository: repository,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            transcriptionAudioPreparer: preparer,
            transcriptionProcessLauncher: launcher,
            transcriptionScriptURL: fixture.scriptURL
        )
        if configureProvider {
            model.aiProviderSettingsModel.baseURLText = "https://api.example.com/v1"
            model.aiProviderSettingsModel.asrModel = "asr"
            model.aiProviderSettingsModel.llmModel = "llm"
            model.aiProviderSettingsModel.save()
        }
        return model
    }

    private func waitForIdle(
        _ model: AppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard await eventually({ model.transcribingSessionID == nil }) else {
            XCTFail("Transcription did not become idle", file: file, line: line)
            return
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeSnapshot(asrModel: String) throws -> OpenAICompatibleProviderSnapshot {
        .init(profile: try makeProfile(asrModel: asrModel), apiKey: "saved")
    }

    private func makeProfile(asrModel: String = "asr") throws -> OpenAICompatibleProviderProfile {
        try OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: asrModel,
            llmModel: "llm",
            language: "",
            prompt: ""
        )
    }
}

private enum TestError: Error { case failed }

private final class ControlledPreparer: TranscriptionAudioPreparing, @unchecked Sendable {
    enum Mode {
        case immediate(Result<PreparedTranscriptionAudio, Error>)
        case suspended(started: XCTestExpectation)
    }

    private let lock = NSLock()
    private let mode: Mode
    private let cleanupExpectation: XCTestExpectation?
    private var continuation: CheckedContinuation<PreparedTranscriptionAudio, Error>?
    private(set) var cancelled = false
    private(set) var cleaned: [PreparedTranscriptionAudio] = []
    private(set) var requests: [RecordingSession] = []

    init(_ mode: Mode, cleanup: XCTestExpectation? = nil) {
        self.mode = mode
        cleanupExpectation = cleanup
    }

    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        lock.withLock {
            requests.append(session)
        }
        switch mode {
        case .immediate(let result):
            return try result.get()
        case .suspended(let started):
            started.fulfill()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock {
                        self.continuation = continuation
                    }
                }
            }, onCancel: { [weak self] in
                self?.cancelPreparation()
            })
        }
    }

    func cleanup(_ prepared: PreparedTranscriptionAudio) {
        lock.withLock {
            cleaned.append(prepared)
        }
        cleanupExpectation?.fulfill()
    }

    private func cancelPreparation() {
        let continuation: CheckedContinuation<PreparedTranscriptionAudio, Error>? = lock.withLock {
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func resume(_ result: Result<PreparedTranscriptionAudio, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class ControlledLauncher: TranscriptionProcessLaunching {
    private let lock = NSLock()
    private let makeError: Error?
    private let processRunError: Error?
    private let processTerminationOutput: String
    private var processContinuation: CheckedContinuation<ControlledProcess, Never>?
    private var pendingProcesses: [ControlledProcess] = []
    private(set) var requests: [TranscriptionProcessRequest] = []

    init(
        makeError: Error? = nil,
        processRunError: Error? = nil,
        processTerminationOutput: String = ""
    ) {
        self.makeError = makeError
        self.processRunError = processRunError
        self.processTerminationOutput = processTerminationOutput
    }

    func makeProcess(
        request: TranscriptionProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> any TranscriptionProcessing {
        if let makeError { throw makeError }
        let process = ControlledProcess(
            onOutput: onOutput,
            runError: processRunError,
            terminationOutput: processTerminationOutput
        )
        let continuation: CheckedContinuation<ControlledProcess, Never>? = lock.withLock {
            requests.append(request)
            let continuation = processContinuation
            processContinuation = nil
            if continuation == nil {
                pendingProcesses.append(process)
            }
            return continuation
        }
        continuation?.resume(returning: process)
        return process
    }

    func nextProcess() async -> ControlledProcess {
        await withCheckedContinuation { continuation in
            let pending: ControlledProcess? = lock.withLock {
                if !pendingProcesses.isEmpty {
                    return pendingProcesses.removeFirst()
                }
                precondition(processContinuation == nil, "Only one nextProcess waiter is supported")
                processContinuation = continuation
                return nil
            }
            if let pending {
                continuation.resume(returning: pending)
            }
        }
    }
}

private final class ControlledProcess: TranscriptionProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private let onOutput: @Sendable (String) -> Void
    private let runError: Error?
    private let terminationOutput: String
    private var exitContinuation: CheckedContinuation<TranscriptionProcessResult, Never>?
    private var completedResult: TranscriptionProcessResult?
    private(set) var terminateCount = 0

    init(
        onOutput: @escaping @Sendable (String) -> Void,
        runError: Error? = nil,
        terminationOutput: String = ""
    ) {
        self.onOutput = onOutput
        self.runError = runError
        self.terminationOutput = terminationOutput
    }

    func run() throws {
        if let runError {
            throw runError
        }
    }

    func waitForExit() async -> TranscriptionProcessResult {
        await withCheckedContinuation { continuation in
            let result: TranscriptionProcessResult? = lock.withLock {
                if let completedResult {
                    return completedResult
                }
                exitContinuation = continuation
                return nil
            }
            if let result {
                continuation.resume(returning: result)
            }
        }
    }

    func terminate() {
        lock.withLock {
            terminateCount += 1
        }
        complete(exitStatus: -15, output: terminationOutput)
    }

    func emit(_ output: String) {
        onOutput(output)
    }

    func complete(
        exitStatus: Int32,
        output: String = "",
        deliverLiveCallbacks: Bool = true
    ) {
        let protocolLines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter {
                $0.hasPrefix("STATUS=")
                    || $0.hasPrefix("TRANSCRIPT_PATH=")
                    || $0.hasPrefix("LOG_PATH=")
                    || $0.hasPrefix("ERROR=")
            }
        let completion: (
            TranscriptionProcessResult,
            CheckedContinuation<TranscriptionProcessResult, Never>?
        )? = lock.withLock {
            guard completedResult == nil else { return nil }
            let result = TranscriptionProcessResult(
                exitStatus: exitStatus,
                output: output,
                protocolLines: protocolLines
            )
            completedResult = result
            let continuation = exitContinuation
            exitContinuation = nil
            return (result, continuation)
        }
        if let completion {
            if deliverLiveCallbacks {
                for line in protocolLines {
                    onOutput(line)
                }
            }
            completion.1?.resume(returning: completion.0)
        }
    }
}

private final class SnapshotProviderRepository: OpenAICompatibleProviderManaging {
    var snapshotValue: OpenAICompatibleProviderSnapshot
    private let profile: OpenAICompatibleProviderProfile?
    private let snapshotError: Error?

    init(
        snapshot: OpenAICompatibleProviderSnapshot? = nil,
        profile: OpenAICompatibleProviderProfile? = nil,
        snapshotError: Error? = nil
    ) {
        snapshotValue = snapshot ?? .init(profile: profile!, apiKey: nil)
        self.profile = profile ?? snapshot?.profile
        self.snapshotError = snapshotError
    }

    func loadProfile() throws -> OpenAICompatibleProviderProfile? { profile }
    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey: String?) throws {}
    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        if let snapshotError { throw snapshotError }
        return snapshotValue
    }
    func snapshot(overriding profile: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot {
        .init(profile: profile, apiKey: snapshotValue.apiKey)
    }
    func hasAPIKey() throws -> Bool { snapshotValue.apiKey != nil }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private struct TranscriptionFixture {
    let root: URL
    let session: RecordingSession
    let temporaryAudioURL: URL
    let scriptURL: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("transcribe-qwen-asr.sh")
        FileManager.default.createFile(atPath: scriptURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return .init(
            root: root,
            session: .init(
                id: root,
                folderURL: root,
                recordingURL: root.appendingPathComponent("recording.mp4"),
                createdAt: .now,
                duration: 0,
                fileSize: 0,
                metadata: .init()
            ),
            temporaryAudioURL: root.appendingPathComponent("prepared.m4a"),
            scriptURL: scriptURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
