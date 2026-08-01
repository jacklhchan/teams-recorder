import CryptoKit
import Foundation
import XCTest
@testable import RecorderApp

/// Composition tests for the Task 5 bridge.  These deliberately use real
/// AppModel/feature instances rather than the bridge Routes recorder: the
/// workspace transition must make old durable work invisible to the new
/// Library/MI projections.
@MainActor
final class PRBWorkspaceTransitionIntegrationTests: XCTestCase {
    func testWorkspaceChangeCancelsDelayedMeetingIntelligenceAndLeavesNoVisibleProjection() async throws {
        let fixture = try WorkspaceTransitionFixture()
        defer { fixture.remove() }
        let generator = DelayedWorkspaceGenerator()
        var feature: MeetingIntelligenceFeatureModel?
        var coordinator: MeetingIntelligenceJobCoordinator?
        let model = fixture.makeModel(
            meetingIntelligenceFeatureFactory: { repository, sourceID, gate in
                let artifacts = MeetingIntelligenceArtifactStore(mutationGate: gate)
                let createdCoordinator = MeetingIntelligenceJobCoordinator(
                    providerRepository: repository,
                    expectedPublicationSourceID: sourceID,
                    availabilityChecker: ConfirmedWorkspaceAvailability(),
                    generator: generator,
                    publisher: MeetingIntelligencePublisher(
                        mutationGate: gate,
                        artifactStore: artifacts
                    ),
                    artifactStore: artifacts,
                    stateStore: MeetingIntelligenceStateStore(mutationGate: gate)
                )
                coordinator = createdCoordinator
                let created = MeetingIntelligenceFeatureModel(
                    coordinator: createdCoordinator
                )
                feature = created
                return created
            }
        )
        defer { model.shutdown() }

        model.setOutputFolder(fixture.workspace)
        model.seedLibrarySessionsForTesting([fixture.session])
        try TranscriptDocumentStore.save("old transcript", in: fixture.session.folderURL)

        let intelligence = try XCTUnwrap(feature)
        let intelligenceCoordinator = try XCTUnwrap(coordinator)
        intelligence.generate(for: fixture.session, workspaceFence: .init(revision: 1))
        await generator.waitUntilStarted()

        model.setOutputFolder(fixture.newWorkspace)
        XCTAssertNil(intelligence.snapshot.presentation(for: fixture.session))

        generator.release()
        await intelligenceCoordinator.waitUntilIdleForTesting(
            sessionID: fixture.session.id
        )

        XCTAssertNil(intelligence.snapshot.presentation(for: fixture.session))
        XCTAssertFalse(model.sessions.contains { $0.id == fixture.session.id })
    }

    func testOldWorkspaceASRCanPublishArtifactButCannotUpdateNewLibraryOrMeetingIntelligence() async throws {
        let fixture = try WorkspaceTransitionFixture()
        defer { fixture.remove() }
        let preparer = DelayedWorkspacePreparer()
        let service = OldWorkspaceTranscriptService()
        let transcription = TranscriptionFeatureModel(coordinator: .init(
            providerRepository: fixture.repository,
            audioPreparer: preparer,
            service: service,
            mutationGate: fixture.gate
        ))
        let model = fixture.makeModel(transcriptionFeature: transcription)
        defer { model.shutdown() }

        model.setOutputFolder(fixture.workspace)
        model.seedLibrarySessionsForTesting([fixture.session])
        transcription.start(session: fixture.session, providerIsConfigured: true)
        await preparer.waitUntilStarted()

        model.setOutputFolder(fixture.newWorkspace)
        preparer.release(audioURL: fixture.audioURL)
        await eventually { transcription.presentation.transcribingSessionID == nil }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: TranscriptDocumentStore.editableURL(in: fixture.session.folderURL).path
            ),
            "The old attempt may finish its durable artifact on its original disk workspace."
        )
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.meetingIntelligenceFeature.snapshot.presentation(for: fixture.session))
    }

    private func eventually(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}

@MainActor
private final class WorkspaceTransitionFixture {
    let workspace: URL
    let newWorkspace: URL
    let gate = RecordingSessionMutationGate()
    let repository = WorkspaceTransitionRepository()
    let session: RecordingSession
    let audioURL: URL

    init() throws {
        workspace = try Self.makeFolder()
        newWorkspace = try Self.makeFolder()
        let folder = workspace.appendingPathComponent("old-session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        audioURL = folder.appendingPathComponent("recording.m4a")
        try Data([0]).write(to: audioURL)
        session = .init(
            id: folder,
            folderURL: folder,
            recordingURL: audioURL,
            createdAt: .distantPast,
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
    }

    func makeModel(
        transcriptionFeature: TranscriptionFeatureModel? = nil,
        meetingIntelligenceFeatureFactory: MeetingIntelligenceFeatureFactory? = nil
    ) -> AppModel {
        let library = LibraryFeatureModel(
            sessionLoader: { RecordingSessionStore.load(from: $0) },
            sessionReloader: { $0 },
            searchDocumentLoader: { session in
                RecordingLibrarySearchDocument.load(
                    folderURL: session.folderURL,
                    displayName: session.displayName,
                    createdAt: session.createdAt,
                    metadata: session.metadata
                )
            },
            recovery: { _ in },
            trashHandler: { _ in true },
            mutationGate: gate
        )
        return AppModel(
            providerRepository: repository,
            performStartupWork: false,
            initialOutputFolder: workspace,
            transcriptionFeatureFactory: transcriptionFeature.map { feature in
                { _, _, _, _ in feature }
            },
            libraryFeature: library,
            meetingIntelligenceFeatureFactory: meetingIntelligenceFeatureFactory
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(at: newWorkspace)
    }

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class WorkspaceTransitionRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    private var profile = try! OpenAICompatibleProviderProfile.validated(
        baseURLText: "https://api.example.com/v1",
        asrModel: "asr",
        llmModel: "llm",
        language: "en",
        prompt: ""
    )

    func loadProfile() throws -> OpenAICompatibleProviderProfile? { profile }
    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey _: String?) throws { self.profile = profile }
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { try .validated(profile: profile, apiKey: nil) }
    func snapshot(overriding profile: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { try .validated(profile: profile, apiKey: nil) }
    func hasAPIKey() throws -> Bool { false }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL _: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private struct ConfirmedWorkspaceAvailability: MeetingIntelligenceAvailabilityChecking {
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability { .confirmed }
}

private final class DelayedWorkspaceGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var started: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func generate(transcript _: TranscriptDocumentSnapshot, snapshot _: OpenAICompatibleProviderSnapshot, onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let start = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                didStart = true
                let waiting = started
                started = nil
                releaseContinuation = continuation
                return waiting
            }
            start?.resume()
        }
        return .init(title: "Old title", summary: "Old summary")
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if didStart { return true }
                started = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let value = releaseContinuation
            releaseContinuation = nil
            return value
        }
        continuation?.resume()
    }
}

private final class DelayedWorkspacePreparer: TranscriptionAudioPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var started: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<URL, Never>?
    private var didStart = false

    func prepare(for _: RecordingSession) async throws -> PreparedTranscriptionAudio {
        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL, Never>) in
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                didStart = true
                let value = started
                started = nil
                releaseContinuation = continuation
                return value
            }
            waiting?.resume()
        }
        return .init(audioURL: url, cleanupURL: nil)
    }

    func cleanup(_: PreparedTranscriptionAudio) {}

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if didStart { return true }
                started = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release(audioURL: URL) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Never>? in
            let value = releaseContinuation
            releaseContinuation = nil
            return value
        }
        continuation?.resume(returning: audioURL)
    }
}

private struct OldWorkspaceTranscriptService: TranscriptionServicing {
    func transcribe(_ request: TranscriptionServiceRequest, onProgress _: @escaping @Sendable (TranscriptionServiceProgress) -> Void) async throws -> TranscriptionServiceResult {
        let text = "old workspace transcript"
        try TranscriptDocumentStore.save(text, in: request.sessionFolder)
        let data = Data(text.utf8)
        return .init(
            transcriptURL: TranscriptDocumentStore.editableURL(in: request.sessionFolder),
            rawTranscriptURL: nil,
            manifestURL: nil,
            logURL: nil,
            committedTranscriptRevision: .init(sha256: SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined(), byteCount: data.count)
        )
    }
}
