import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceJobCoordinatorTests: XCTestCase {
    func testConfirmedPublicationRunsDiscoveryGenerationAndOnePublication() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let event = fixture.event(generation: 1)

        fixture.coordinator.handleTranscriptPublished(event)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 1)
        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testUnconfirmedAutomaticPublicationNeverGenerates() async throws {
        let fixture = try CoordinatorFixture(availability: .unconfirmed(.modelNotAdvertised))

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 1)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertEqual(
            fixture.coordinator.presentation(for: fixture.session).unavailableReason,
            .modelNotAdvertised
        )
    }

    func testManualGenerateBypassesDiscoveryButRejectsPlaceholder() async throws {
        let fixture = try CoordinatorFixture(availability: .unconfirmed(.discoveryUnsupported))

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)

        fixture.repository.snapshotValue = try fixture.snapshot(llmModel: "legacy-unconfigured-llm")
        fixture.coordinator.generate(for: fixture.session)
        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(
            fixture.coordinator.presentation(for: fixture.session).unavailableReason,
            .placeholderModel
        )
    }

    func testDuplicateOrOlderPublicationDoesNotRepeatAutomaticWork() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let latest = fixture.event(generation: 2)
        fixture.coordinator.handleTranscriptPublished(latest)
        await fixture.waitForIdle()
        fixture.coordinator.handleTranscriptPublished(latest)
        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.generator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)
    }

    func testTranscriptSaveMarksChangedArtifactStaleWithoutAutomaticGeneration() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        fixture.reader.snapshot = .init(
            url: fixture.reader.snapshot.url,
            data: Data("changed".utf8),
            revision: .init(sha256: "sha256:changed", byteCount: 7)
        )

        fixture.coordinator.transcriptDidSave(fixture.session)

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .stale)
        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
    }
}

@MainActor
private final class CoordinatorFixture {
    let root: URL
    let session: RecordingSession
    let reader: CoordinatorTranscriptReader
    let repository: CoordinatorRepository
    let availability: CoordinatorAvailability
    let generator = CoordinatorGenerator()
    let publisher = CoordinatorPublisher()
    let artifactStore = CoordinatorArtifactStore()
    let stateStore = CoordinatorStateStore()
    let coordinator: MeetingIntelligenceJobCoordinator
    private let coordinatorID = UUID()

    init(availability: MeetingIntelligenceAvailability) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptURL = root.appendingPathComponent("transcript.txt")
        let data = Data("Original transcript".utf8)
        try data.write(to: transcriptURL)
        let revision = TranscriptDocumentRevision(sha256: "sha256:original", byteCount: data.count)
        reader = .init(snapshot: .init(url: transcriptURL, data: data, revision: revision))
        session = .init(id: root, folderURL: root, recordingURL: root.appendingPathComponent("recording.m4a"),
                        createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        repository = .init(snapshotValue: try Self.makeSnapshot(llmModel: "llm"))
        self.availability = .init(value: availability)
        coordinator = .init(providerRepository: repository, transcriptReader: reader,
                            availabilityChecker: self.availability, generator: generator,
                            publisher: publisher, artifactStore: artifactStore, stateStore: stateStore,
                            now: { .distantPast })
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func event(generation: UInt64) -> TranscriptPublished {
        .init(session: session, canonicalURL: reader.snapshot.url, revision: reader.snapshot.revision,
              normalizedSessionFolder: root.standardizedFileURL,
              identity: .init(coordinatorInstanceID: coordinatorID, generation: generation, attemptID: UUID()))
    }

    func snapshot(llmModel: String) throws -> OpenAICompatibleProviderSnapshot { try Self.makeSnapshot(llmModel: llmModel) }
    func artifact(revision: TranscriptDocumentRevision) -> MeetingIntelligenceArtifact {
        .init(schemaVersion: 1, summary: "Old", suggestedTitle: "Old title", sourceTranscriptSHA256: revision.sha256,
              sourceTranscriptByteCount: revision.byteCount, model: "llm", generatedAt: .distantPast, intent: .generate)
    }

    func waitForIdle() async {
        for _ in 0 ..< 100 {
            if generator.requests == publisher.requests, publisher.requests > 0 || availability.requests > 0 { await Task.yield() }
            await Task.yield()
        }
    }

    private static func makeSnapshot(llmModel: String) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: .validated(baseURLText: "http://127.0.0.1:8080", asrModel: "asr", llmModel: llmModel,
                                            language: "en", prompt: ""), apiKey: nil)
    }
}

private final class CoordinatorTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    var snapshot: TranscriptDocumentSnapshot
    init(snapshot: TranscriptDocumentSnapshot) { self.snapshot = snapshot }
    func readCanonical(in _: URL, allowLegacy _: Bool) throws -> TranscriptDocumentSnapshot { snapshot }
}

private final class CoordinatorRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    var snapshotValue: OpenAICompatibleProviderSnapshot
    init(snapshotValue: OpenAICompatibleProviderSnapshot) { self.snapshotValue = snapshotValue }
    func loadProfile() throws -> OpenAICompatibleProviderProfile? { snapshotValue.profile }
    func save(profile _: OpenAICompatibleProviderProfile, replacementAPIKey _: String?) throws {}
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { snapshotValue }
    func snapshot(overriding profile: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { try .validated(profile: profile, apiKey: snapshotValue.apiKey) }
    func hasAPIKey() throws -> Bool { snapshotValue.apiKey != nil }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL _: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private final class CoordinatorAvailability: MeetingIntelligenceAvailabilityChecking, @unchecked Sendable {
    let value: MeetingIntelligenceAvailability
    private(set) var requests = 0
    init(value: MeetingIntelligenceAvailability) { self.value = value }
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability { requests += 1; return value }
}

private final class CoordinatorGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private(set) var requests = 0
    func generate(transcript _: TranscriptDocumentSnapshot, snapshot _: OpenAICompatibleProviderSnapshot,
                  onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        requests += 1
        return .init(title: "Generated", summary: "Summary")
    }
}

private final class CoordinatorPublisher: MeetingIntelligencePublishing, @unchecked Sendable {
    private(set) var requests = 0
    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        requests += 1
        return .init(artifact: .init(schemaVersion: 1, summary: request.content.summary, suggestedTitle: request.content.title,
                                     sourceTranscriptSHA256: request.sourceRevision.sha256, sourceTranscriptByteCount: request.sourceRevision.byteCount,
                                     model: request.snapshot.profile.llmModel, generatedAt: request.generatedAt, intent: request.intent),
                     titleWasApplied: false, titleWarning: nil)
    }
}

private final class CoordinatorArtifactStore: MeetingIntelligenceArtifactStoring, @unchecked Sendable {
    var loaded: MeetingIntelligenceArtifact?
    func load(in _: URL) throws -> MeetingIntelligenceArtifact? { loaded }
    func stage(_: MeetingIntelligenceArtifact, in folder: URL) throws -> URL { folder }
    func promoteStaged(_: URL, in _: URL) throws {}
    func removeStaged(_: URL, in _: URL) throws {}
}

private final class CoordinatorStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    func load(in _: URL) throws -> MeetingIntelligenceState? { nil }
    func save(_: MeetingIntelligenceState, in _: URL) throws {}
    func remove(in _: URL) throws {}
}
