import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class TranscriptionJobCoordinatorTests: XCTestCase {
    func testCoordinatorOwnsLifecycleAndPublishesCompletedArtifacts() async throws {
        let fixture = try CoordinatorFixture.make()
        defer { fixture.remove() }
        let service = CoordinatorService(
            result: .success(
                .init(
                    transcriptURL: fixture.transcriptURL,
                    rawTranscriptURL: nil,
                    manifestURL: nil,
                    logURL: fixture.logURL
                )
            )
        )
        let coordinator = TranscriptionJobCoordinator(
            providerRepository: CoordinatorRepository(
                snapshot: try fixture.snapshot()
            ),
            audioPreparer: CoordinatorPreparer(
                result: .success(
                    .init(
                        audioURL: fixture.audioURL,
                        cleanupURL: fixture.audioURL
                    )
                )
            ),
            service: service
        )

        coordinator.start(session: fixture.session)
        await waitForIdle(coordinator)

        XCTAssertEqual(
            coordinator.transcriptionStatesBySessionID[
                fixture.session.id
            ]?.phase,
            .completed
        )
        XCTAssertEqual(
            coordinator.transcriptURLsBySessionID[fixture.session.id],
            fixture.transcriptURL
        )
        XCTAssertEqual(
            coordinator.transcriptLogURLsBySessionID[fixture.session.id],
            fixture.logURL
        )
        XCTAssertEqual(service.requests.count, 1)
    }

    func testCancellationDuringPreparationSettlesWithoutCallingService() async throws {
        let fixture = try CoordinatorFixture.make()
        defer { fixture.remove() }
        let preparer = CoordinatorPreparer()
        let service = CoordinatorService(
            result: .failure(CoordinatorError.failed)
        )
        let coordinator = TranscriptionJobCoordinator(
            providerRepository: CoordinatorRepository(
                snapshot: try fixture.snapshot()
            ),
            audioPreparer: preparer,
            service: service
        )

        coordinator.start(session: fixture.session)
        await preparer.waitUntilStarted()
        coordinator.cancel()
        await waitForIdle(coordinator)

        XCTAssertTrue(preparer.cancelled)
        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertEqual(
            coordinator.transcriptionStatesBySessionID[
                fixture.session.id
            ]?.phase,
            .cancelled
        )
    }

    func testProviderSecretIsRedactedFromFailureAndPersistedState() async throws {
        let fixture = try CoordinatorFixture.make()
        defer { fixture.remove() }
        let secret = "coordinator-private-key"
        let coordinator = TranscriptionJobCoordinator(
            providerRepository: CoordinatorRepository(
                snapshot: try fixture.snapshot(apiKey: secret)
            ),
            audioPreparer: CoordinatorPreparer(
                result: .success(
                    .init(
                        audioURL: fixture.audioURL,
                        cleanupURL: nil
                    )
                )
            ),
            service: CoordinatorService(
                result: .failure(
                    NSError(
                        domain: "Provider \(secret) failed",
                        code: 1
                    )
                )
            )
        )

        coordinator.start(session: fixture.session)
        await waitForIdle(coordinator)

        XCTAssertFalse(coordinator.lastTranscriptionStatus.contains(secret))
        let persisted = try XCTUnwrap(
            try TranscriptionStateStore.load(
                in: fixture.session.folderURL
            )
        )
        XCTAssertFalse(persisted.message.contains(secret))
    }

    func testResponseTooLargeUsesTransportGenericUserFacingMessage() async throws {
        let fixture = try CoordinatorFixture.make()
        defer { fixture.remove() }
        let coordinator = TranscriptionJobCoordinator(
            providerRepository: CoordinatorRepository(
                snapshot: try fixture.snapshot()
            ),
            audioPreparer: CoordinatorPreparer(
                result: .success(
                    .init(
                        audioURL: fixture.audioURL,
                        cleanupURL: nil
                    )
                )
            ),
            service: CoordinatorService(
                result: .failure(
                    ProviderHTTPTransportError.responseTooLarge
                )
            )
        )

        coordinator.start(session: fixture.session)
        await waitForIdle(coordinator)

        XCTAssertEqual(
            coordinator.lastTranscriptionStatus,
            "Transcription launch failed: "
                + "The provider response was too large."
        )
        XCTAssertEqual(
            coordinator.transcriptionStatesBySessionID[
                fixture.session.id
            ]?.message,
            coordinator.lastTranscriptionStatus
        )
    }

    private func waitForIdle(
        _ coordinator: TranscriptionJobCoordinator
    ) async {
        for _ in 0..<500 {
            if coordinator.transcribingSessionID == nil {
                return
            }
            await Task.yield()
        }
        XCTFail("Coordinator did not become idle")
    }
}

private enum CoordinatorError: Error {
    case failed
}

private struct CoordinatorFixture {
    let root: URL
    let session: RecordingSession
    let audioURL: URL
    let transcriptURL: URL
    let logURL: URL

    static func make() throws -> CoordinatorFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "transcription-coordinator-\(UUID().uuidString)",
                isDirectory: true
            )
        let folder = root.appendingPathComponent(
            "meeting-test",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let audio = root.appendingPathComponent("prepared.m4a")
        let transcript = folder.appendingPathComponent("transcript.txt")
        let log = folder.appendingPathComponent("transcription.log")
        try Data([1]).write(to: audio)
        try "done".write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: log)
        return .init(
            root: root,
            session: RecordingSession(
                id: folder,
                folderURL: folder,
                recordingURL: folder.appendingPathComponent(
                    "recording.m4a"
                ),
                createdAt: Date(),
                duration: 1,
                fileSize: 1,
                metadata: .init()
            ),
            audioURL: audio,
            transcriptURL: transcript,
            logURL: log
        )
    }

    func snapshot(
        apiKey: String? = nil
    ) throws -> OpenAICompatibleProviderSnapshot {
        .init(
            profile: try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example/v1",
                asrModel: "asr",
                llmModel: "llm",
                language: "yue",
                prompt: ""
            ),
            apiKey: apiKey
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CoordinatorRepository:
    OpenAICompatibleProviderManaging,
    @unchecked Sendable
{
    private let value: OpenAICompatibleProviderSnapshot

    init(snapshot: OpenAICompatibleProviderSnapshot) {
        value = snapshot
    }

    func loadProfile() throws -> OpenAICompatibleProviderProfile? {
        value.profile
    }

    func save(
        profile _: OpenAICompatibleProviderProfile,
        replacementAPIKey _: String?
    ) throws {}

    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        value
    }

    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot {
        .init(profile: profile, apiKey: value.apiKey)
    }

    func hasAPIKey() throws -> Bool {
        value.apiKey != nil
    }

    func removeAPIKey() throws {}

    func migrateLegacyIfNeeded(
        settingsURL _: URL
    ) throws -> LegacyProviderMigrationOutcome {
        .notFound
    }
}

private final class CoordinatorPreparer:
    TranscriptionAudioPreparing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: Result<PreparedTranscriptionAudio, Error>?
    private var continuation:
        CheckedContinuation<PreparedTranscriptionAudio, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private(set) var cancelled = false

    init(
        result: Result<PreparedTranscriptionAudio, Error>? = nil
    ) {
        self.result = result
    }

    func prepare(
        for _: RecordingSession
    ) async throws -> PreparedTranscriptionAudio {
        if let result {
            return try result.get()
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let started = lock.withLock {
                    self.continuation = continuation
                    didStart = true
                    let started = startedContinuation
                    startedContinuation = nil
                    return started
                }
                started?.resume()
            }
        }, onCancel: {
            let continuation = self.lock.withLock {
                self.cancelled = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        })
    }

    func cleanup(_: PreparedTranscriptionAudio) {}

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if didStart {
                    return true
                }
                startedContinuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}

private final class CoordinatorService:
    TranscriptionServicing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: Result<TranscriptionServiceResult, Error>
    private(set) var requests: [TranscriptionServiceRequest] = []

    init(result: Result<TranscriptionServiceResult, Error>) {
        self.result = result
    }

    func transcribe(
        _ request: TranscriptionServiceRequest,
        onProgress: @escaping @Sendable (
            TranscriptionServiceProgress
        ) -> Void
    ) async throws -> TranscriptionServiceResult {
        lock.withLock { requests.append(request) }
        onProgress(.uploading(chunk: 1, total: 1))
        return try result.get()
    }
}
