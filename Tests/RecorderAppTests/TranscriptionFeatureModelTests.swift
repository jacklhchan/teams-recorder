import XCTest
@testable import RecorderApp

@MainActor
final class TranscriptionFeatureModelTests: XCTestCase {
    func testPublicationObserverTokenCannotRemoveReplacementAndShutdownClearsIt() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let feature = fixture.makeFeature()
        var oldCalls = 0
        var replacementCalls = 0
        let oldToken = feature.observeSuccessfulPublication { _ in oldCalls += 1 }
        let replacementToken = feature.observeSuccessfulPublication { _ in replacementCalls += 1 }

        feature.removeSuccessfulPublicationObserver(oldToken)
        XCTAssertNotNil(feature.onSuccessfulPublication)

        feature.start(session: fixture.session, providerIsConfigured: true)
        await eventually { feature.presentation.transcribingSessionID == nil }
        XCTAssertEqual(oldCalls, 0)
        XCTAssertEqual(replacementCalls, 1)

        feature.removeSuccessfulPublicationObserver(replacementToken)
        XCTAssertNil(feature.onSuccessfulPublication)

        _ = feature.observeSuccessfulPublication { _ in replacementCalls += 1 }
        feature.shutdown()
        XCTAssertNil(feature.onSuccessfulPublication)
    }

    func testUnconfiguredProviderPublishesRecoveryWithoutStartingAJob() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let preparer = FeaturePreparer()
        let feature = fixture.makeFeature(preparer: preparer)
        var messages: [String] = []
        feature.onStatusMessage = { messages.append($0) }

        feature.start(session: fixture.session, providerIsConfigured: false)
        await Task.yield()

        XCTAssertEqual(
            messages,
            ["Configure and save an AI provider before starting transcription."]
        )
        XCTAssertEqual(preparer.prepareCount, 0)
        XCTAssertNil(feature.presentation.transcribingSessionID)
    }

    func testSuccessProjectsStateTranscriptAndLogAndEmitsOnePublication() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let feature = fixture.makeFeature()
        var publications: [TranscriptPublished] = []
        feature.onSuccessfulPublication = { publications.append($0) }

        feature.start(session: fixture.session, providerIsConfigured: true)
        await eventually { feature.presentation.transcribingSessionID == nil }

        XCTAssertEqual(feature.presentation.transcriptionStatesBySessionID[fixture.session.id]?.phase, .completed)
        XCTAssertEqual(feature.presentation.transcriptURLsBySessionID[fixture.session.id], fixture.transcriptURL)
        XCTAssertEqual(
            feature.presentation.transcriptLogURLsBySessionID[fixture.session.id],
            fixture.logURL
        )
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.identity.coordinatorInstanceID, feature.publicationSourceID)
    }

    func testSecondStartWhileActiveTakesNoSecondProviderSnapshot() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let repository = FeatureRepository(snapshot: try fixture.snapshot())
        let preparer = FeatureBlockingPreparer()
        let feature = fixture.makeFeature(
            repository: repository,
            preparer: preparer
        )

        feature.start(session: fixture.session, providerIsConfigured: true)
        await preparer.waitUntilStarted()
        feature.start(session: fixture.session, providerIsConfigured: true)

        XCTAssertEqual(repository.snapshotCount, 1)
        feature.shutdown()
    }

    func testProviderSaveDoesNotMutateActiveASRSnapshotAndLaterAttemptUsesSavedProfile() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let repository = FeatureRepository(snapshot: try fixture.snapshot())
        let preparer = FeatureBlockingPreparer()
        let service = FeatureCapturingService(result: .init(
            transcriptURL: fixture.transcriptURL,
            rawTranscriptURL: nil,
            manifestURL: nil,
            logURL: fixture.logURL,
            committedTranscriptRevision: fixture.revision
        ))
        let feature = fixture.makeFeature(
            repository: repository,
            preparer: preparer,
            service: service
        )
        let settings = AIProviderSettingsModel(
            repository: repository,
            loadImmediately: false
        )
        settings.baseURLText = "https://api.example/v1"
        settings.asrModel = "saved-asr"
        settings.llmModel = "saved-llm"
        settings.selectedLanguage = .cantonese

        feature.start(session: fixture.session, providerIsConfigured: true)
        await preparer.waitUntilStarted()
        XCTAssertEqual(feature.presentation.transcribingSessionID, fixture.session.id)

        settings.save()

        XCTAssertEqual(repository.snapshotCount, 1)
        XCTAssertEqual(feature.presentation.transcribingSessionID, fixture.session.id)
        preparer.release(with: fixture.audioURL)
        await eventually { feature.presentation.transcribingSessionID == nil }
        XCTAssertEqual(service.requests.map(\.snapshot.profile.asrModel), ["asr"])

        feature.start(session: fixture.session, providerIsConfigured: true)
        await preparer.waitForStartCount(2)
        preparer.release(with: fixture.audioURL)
        await eventually { feature.presentation.transcribingSessionID == nil }

        XCTAssertEqual(repository.snapshotCount, 2)
        XCTAssertEqual(
            service.requests.map(\.snapshot.profile.asrModel),
            ["asr", "saved-asr"]
        )
    }

    func testWorkspaceFenceAndClearProjectionAreFeatureOwned() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let feature = fixture.makeFeature()
        var publications: [TranscriptPublished] = []
        feature.onSuccessfulPublication = { publications.append($0) }
        feature.advanceWorkspacePublicationFence(
            to: WorkspacePublicationFence(revision: 1)
        )
        feature.setTranscriptURL(fixture.transcriptURL, for: fixture.session.id)
        feature.start(session: fixture.session, providerIsConfigured: true)
        await eventually { feature.presentation.transcribingSessionID == nil }

        XCTAssertEqual(publications.map(\.workspaceFence.revision), [1])
        feature.clearProjections()
        XCTAssertTrue(feature.presentation.transcriptURLsBySessionID.isEmpty)
        XCTAssertTrue(feature.presentation.transcriptionStatesBySessionID.isEmpty)
    }

    func testShutdownIsIdempotentSuppressesLateCallbacksAndCannotRestart() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let preparer = FeatureBlockingPreparer()
        let feature = fixture.makeFeature(preparer: preparer)
        var publications = 0
        feature.onSuccessfulPublication = { _ in publications += 1 }
        feature.start(session: fixture.session, providerIsConfigured: true)
        await preparer.waitUntilStarted()

        feature.shutdown()
        feature.shutdown()
        feature.start(session: fixture.session, providerIsConfigured: true)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(preparer.startCount, 1)
        XCTAssertEqual(publications, 0)
        XCTAssertNil(feature.presentation.transcribingSessionID)
    }

    func testLoadedStatesInterruptPersistedWorkButPreserveLiveProjection() async throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let preparer = FeatureBlockingPreparer()
        let feature = fixture.makeFeature(preparer: preparer)
        feature.start(session: fixture.session, providerIsConfigured: true)
        await preparer.waitUntilStarted()
        let state = TranscriptionState(
            phase: .uploading,
            message: "Uploading",
            startedAt: Date()
        )

        feature.replaceLoadedStates([fixture.session.id: state])

        XCTAssertEqual(feature.presentation.transcriptionStatesBySessionID[fixture.session.id]?.phase, .queued)
        feature.shutdown()
    }

    func testLoadedNonActiveInFlightStateBecomesInterrupted() throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let feature = fixture.makeFeature()
        feature.replaceLoadedStates([
            fixture.session.id: .init(
                phase: .uploading,
                message: "Persisted upload",
                startedAt: Date()
            )
        ])

        XCTAssertEqual(
            feature.presentation.transcriptionStatesBySessionID[
                fixture.session.id
            ]?.phase,
            .interrupted
        )
    }

    func testRemoveProjectionRemovesOnlyTheRequestedSession() throws {
        let fixture = try FeatureFixture.make()
        defer { fixture.remove() }
        let otherFolder = fixture.root.appendingPathComponent("other", isDirectory: true)
        let other = RecordingSession(
            id: otherFolder,
            folderURL: otherFolder,
            recordingURL: otherFolder.appendingPathComponent("recording.m4a"),
            createdAt: Date(),
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
        let feature = fixture.makeFeature()
        feature.setTranscriptURL(fixture.transcriptURL, for: fixture.session.id)
        feature.setTranscriptURL(fixture.transcriptURL, for: other.id)

        feature.removeProjection(for: fixture.session.id)

        XCTAssertNil(feature.presentation.transcriptURLsBySessionID[fixture.session.id])
        XCTAssertEqual(feature.presentation.transcriptURLsBySessionID[other.id], fixture.transcriptURL)
    }
}

private extension TranscriptionFeatureModelTests {
    func eventually(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private struct FeatureFixture {
    let root: URL
    let session: RecordingSession
    let audioURL: URL
    let transcriptURL: URL
    let logURL: URL
    let revision: TranscriptDocumentRevision

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-feature-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = root.appendingPathComponent("prepared.m4a")
        let transcriptURL = folder.appendingPathComponent("transcript.txt")
        let logURL = folder.appendingPathComponent("transcription.log")
        try Data([1]).write(to: audioURL)
        try "feature transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: logURL)
        let revision = try SecureTranscriptDocumentReader().readCanonical(in: folder, allowLegacy: false).revision
        return .init(
            root: root,
            session: .init(
                id: folder,
                folderURL: folder,
                recordingURL: folder.appendingPathComponent("recording.m4a"),
                createdAt: Date(), duration: 1, fileSize: 1, metadata: .init()
            ),
            audioURL: audioURL,
            transcriptURL: transcriptURL,
            logURL: logURL,
            revision: revision
        )
    }

    func makeFeature(
        repository: FeatureRepository? = nil,
        preparer: (any TranscriptionAudioPreparing)? = nil,
        service: (any TranscriptionServicing)? = nil
    ) -> TranscriptionFeatureModel {
        let actualPreparer = preparer ?? FeaturePreparer(audioURL: audioURL)
        let actualService = service ?? FeatureService(result: .init(
            transcriptURL: transcriptURL,
            rawTranscriptURL: nil,
            manifestURL: nil,
            logURL: logURL,
            committedTranscriptRevision: revision
        ))
        return .init(coordinator: .init(
            providerRepository: repository ?? FeatureRepository(snapshot: try! snapshot()),
            audioPreparer: actualPreparer,
            service: actualService
        ))
    }

    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        try .validated(
            profile: try .validated(
                baseURLText: "https://api.example/v1",
                asrModel: "asr", llmModel: "llm", language: "yue", prompt: ""
            ),
            apiKey: nil
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class FeatureRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    private var value: OpenAICompatibleProviderSnapshot
    private(set) var snapshotCount = 0
    init(snapshot: OpenAICompatibleProviderSnapshot) { value = snapshot }
    func loadProfile() throws -> OpenAICompatibleProviderProfile? { value.profile }
    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey: String?) throws {
        value = try .validated(profile: profile, apiKey: value.apiKey)
    }
    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        snapshotCount += 1
        return value
    }
    func snapshot(overriding profile: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { try .validated(profile: profile, apiKey: value.apiKey) }
    func hasAPIKey() throws -> Bool { false }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private final class FeaturePreparer: TranscriptionAudioPreparing, @unchecked Sendable {
    var prepareCount = 0
    let audioURL: URL?
    init(audioURL: URL? = nil) { self.audioURL = audioURL }
    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        prepareCount += 1
        return .init(audioURL: audioURL ?? session.recordingURL, cleanupURL: nil)
    }
    func cleanup(_ prepared: PreparedTranscriptionAudio) {}
}

private struct FeatureService: TranscriptionServicing {
    let result: TranscriptionServiceResult
    func transcribe(_ request: TranscriptionServiceRequest, onProgress: @escaping @Sendable (TranscriptionServiceProgress) -> Void) async throws -> TranscriptionServiceResult {
        onProgress(.uploading(chunk: 1, total: 1))
        return result
    }
}

private final class FeatureCapturingService: TranscriptionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: TranscriptionServiceResult
    private var capturedRequests: [TranscriptionServiceRequest] = []

    init(result: TranscriptionServiceResult) { self.result = result }

    var requests: [TranscriptionServiceRequest] { lock.withLock { capturedRequests } }

    func transcribe(
        _ request: TranscriptionServiceRequest,
        onProgress: @escaping @Sendable (TranscriptionServiceProgress) -> Void
    ) async throws -> TranscriptionServiceResult {
        lock.withLock { capturedRequests.append(request) }
        onProgress(.uploading(chunk: 1, total: 1))
        return result
    }
}

private final class FeatureBlockingPreparer: TranscriptionAudioPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PreparedTranscriptionAudio, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private(set) var startCount = 0

    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let started = lock.withLock {
                    self.continuation = continuation
                    didStart = true
                    startCount += 1
                    let value = startedContinuation
                    startedContinuation = nil
                    return value
                }
                started?.resume()
            }
        }, onCancel: {
            let continuation = self.lock.withLock {
                let value = self.continuation
                self.continuation = nil
                return value
            }
            continuation?.resume(throwing: CancellationError())
        })
    }

    func cleanup(_ prepared: PreparedTranscriptionAudio) {}

    func release(with audioURL: URL) {
        let continuation = lock.withLock { () -> CheckedContinuation<PreparedTranscriptionAudio, Error>? in
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: .init(audioURL: audioURL, cleanupURL: nil))
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if didStart { return true }
                startedContinuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitForStartCount(_ expected: Int) async {
        while lock.withLock({ startCount < expected }) {
            await Task.yield()
        }
    }
}
