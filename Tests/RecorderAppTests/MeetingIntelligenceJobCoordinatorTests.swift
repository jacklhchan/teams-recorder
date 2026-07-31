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

    func testCrossSourcePublicationIsRejectedBeforeAnyIOOrAvailability() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var event = fixture.event(generation: 1)
        event = .init(session: event.session, canonicalURL: event.canonicalURL, revision: event.revision,
                      normalizedSessionFolder: event.normalizedSessionFolder,
                      identity: .init(coordinatorInstanceID: UUID(), generation: 1, attemptID: UUID()))

        fixture.coordinator.handleTranscriptPublished(event)
        await Task.yield()

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
    }

    func testExactDigestArtifactSkipsAutomaticDiscoveryAndGeneration() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testCheckAvailabilityPerformsDiscoveryOnly() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)

        fixture.coordinator.checkAvailability(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.availability.requests, 1)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
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
        await fixture.waitForIdle()
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
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .stale)
        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
    }

    func testUnreadableAutomaticArtifactNeedsAttentionWithoutProviderRequests() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loadError = MeetingIntelligenceStoreError.malformed

        fixture.coordinator.handleTranscriptPublished(fixture.event(generation: 1))
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .failed)
        XCTAssertEqual(fixture.availability.requests, 0)
        XCTAssertEqual(fixture.generator.requests, 0)
        XCTAssertEqual(fixture.publisher.requests, 0)
    }

    func testReloadDoesNotReplaceOrCancelActiveGeneration() async throws {
        let entered = expectation(description: "generator entered")
        let gate = GenerationGate()
        let blockingGenerator = BlockingCoordinatorGenerator(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: blockingGenerator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        // A scan that temporarily omits the session is observational; only an
        // explicit remove/trash path may cancel its work.
        fixture.coordinator.reload(sessions: [])
        await gate.release()
        await fixture.waitForIdle()

        XCTAssertEqual(blockingGenerator.requests, 1)
        XCTAssertEqual(fixture.publisher.requests, 1)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testReloadRestoresReadyStaleAndInterruptedPresentations() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        fixture.artifactStore.loaded = fixture.artifact(revision: fixture.reader.snapshot.revision)
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)

        fixture.reader.snapshot = .init(url: fixture.reader.snapshot.url, data: Data("changed".utf8),
                                        revision: .init(sha256: "sha256:changed", byteCount: 7))
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .stale)

        fixture.artifactStore.loaded = nil
        fixture.stateStore.loaded = .init(schemaVersion: 1, phase: .interrupted, message: "Interrupted",
                                          sourceTranscriptSHA256: nil, startedAt: .distantPast, finishedAt: .distantPast)
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .interrupted)
    }

    func testCancellationSuppressesLateGeneratorProgress() async throws {
        let entered = expectation(description: "generator entered")
        let finished = expectation(description: "late generator completed")
        let gate = GenerationGate()
        let blockingGenerator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate, emitsLateProgress: true)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: blockingGenerator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await fixture.waitForIdle()
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .cancelled)
    }

    func testCancelledTerminalStateWinsAfterQueuedGeneratingWrite() async throws {
        let entered = expectation(description: "generating state save entered")
        let release = DispatchSemaphore(value: 0)
        let states = BlockingStateStore(entered: entered, release: release)
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        release.signal()
        await fixture.waitForIdle()

        XCTAssertEqual(states.saved.map(\.phase), [.generating, .cancelled])
        XCTAssertEqual(states.saved.last?.phase, .cancelled)
    }

    func testSuccessfulGenerationEmitsOneSemanticPublicationCallback() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        var callbackCount = 0
        fixture.coordinator.onSuccessfulPublication = { _ in callbackCount += 1 }

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(callbackCount, 1)
    }

    func testGenerationRetainsExactProviderSnapshotAfterRepositoryChanges() async throws {
        let entered = expectation(description: "generator entered")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.repository.snapshotValue = try fixture.snapshot(llmModel: "changed-after-start")
        await gate.release()
        await fixture.waitForIdle()

        XCTAssertEqual(generator.capturedModels, ["llm"])
        XCTAssertEqual(fixture.publisher.capturedModels, ["llm"])
    }

    func testTwoSessionsMaintainIndependentAttempts() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)
        let second = RecordingSession(id: fixture.root.appendingPathComponent("second"),
                                      folderURL: fixture.root.appendingPathComponent("second"),
                                      recordingURL: fixture.root.appendingPathComponent("second/recording.m4a"),
                                      createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())

        fixture.coordinator.generate(for: fixture.session)
        fixture.coordinator.generate(for: second)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: second.id)

        XCTAssertEqual(fixture.publisher.requests, 2)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
        XCTAssertEqual(fixture.coordinator.presentation(for: second).phase, .ready)
    }

    func testRemoveThenReloadAllowsNewAttemptToPersist() async throws {
        let fixture = try CoordinatorFixture(availability: .confirmed)

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()
        fixture.coordinator.remove(sessionID: fixture.session.id)
        fixture.coordinator.reload(sessions: [fixture.session])
        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.publisher.requests, 2)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testCancellationDuringAvailabilityKeepsCancelledPresentation() async throws {
        let entered = expectation(description: "availability entered")
        let gate = GenerationGate()
        let availability = BlockingAvailability(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, availabilityOverride: availability)

        fixture.coordinator.checkAvailability(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await fixture.waitForIdle()
        await gate.release()

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .cancelled)
    }

    func testCancellationDuringPublisherKeepsCancelledPresentationAndNoCallback() async throws {
        let entered = expectation(description: "publisher entered")
        let gate = GenerationGate()
        let publisher = BlockingPublisher(entered: entered, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, publisherOverride: publisher)
        var callbacks = 0
        fixture.coordinator.onSuccessfulPublication = { _ in callbacks += 1 }

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.cancel(sessionID: fixture.session.id)
        await fixture.waitForIdle()
        await gate.release()
        await fulfillment(of: [publisher.finished], timeout: 1)

        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .cancelled)
        XCTAssertEqual(callbacks, 0)
    }

    func testRemoveInvalidatesBlockedGenerationWithoutLatePublication() async throws {
        let entered = expectation(description: "generator entered")
        let finished = expectation(description: "generator finished")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.remove(sessionID: fixture.session.id)
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.publisher.requests, 0)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session), .empty)
    }

    func testShutdownInvalidatesBlockedGenerationWithoutLatePublication() async throws {
        let entered = expectation(description: "generator entered")
        let finished = expectation(description: "generator finished")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.shutdown()
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.publisher.requests, 0)
        // shutdown retains the last projection for teardown safety; no late
        // work may publish or mutate it afterwards.
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase,
                       .generating(.init(stage: .generatingFinal, current: 0, total: 0)))
    }

    func testRemoveCancelsStateWriteQueuedBeforeCommitBoundary() async throws {
        let entered = expectation(description: "state write admitted")
        let released = expectation(description: "state admission released")
        let gate = GenerationGate()
        let scheduler = BlockingStateSaveScheduler(entered: entered, released: released, gate: gate)
        let states = RecordingStateStore()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states,
                                             stateSaveSchedulerOverride: scheduler)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.remove(sessionID: fixture.session.id)
        await gate.release()
        await fulfillment(of: [released], timeout: 1)

        XCTAssertTrue(states.saved.isEmpty)
    }

    func testShutdownCancelsStateWriteQueuedBeforeCommitBoundary() async throws {
        let entered = expectation(description: "state write admitted")
        let released = expectation(description: "state admission released")
        let gate = GenerationGate()
        let scheduler = BlockingStateSaveScheduler(entered: entered, released: released, gate: gate)
        let states = RecordingStateStore()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states,
                                             stateSaveSchedulerOverride: scheduler)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.shutdown()
        await gate.release()
        await fulfillment(of: [released], timeout: 1)

        XCTAssertTrue(states.saved.isEmpty)
    }

    func testWorkspaceResetSuppressesOldLateJobAndAcceptsNewWork() async throws {
        let entered = expectation(description: "old generator entered")
        let finished = expectation(description: "old generator finished")
        let gate = GenerationGate()
        let generator = BlockingCoordinatorGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try CoordinatorFixture(availability: .confirmed, generatorOverride: generator)

        fixture.coordinator.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        fixture.coordinator.resetForWorkspaceChange()
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixture.publisher.requests, 0)

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(fixture.publisher.requests, 1)
        XCTAssertEqual(fixture.coordinator.presentation(for: fixture.session).phase, .ready)
    }

    func testWorkspaceResetReturningToSameFolderKeepsStateWriteGenerationMonotonic() async throws {
        let states = RecordingStateStore()
        let fixture = try CoordinatorFixture(availability: .confirmed, stateStoreOverride: states)

        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()
        fixture.coordinator.regenerate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(states.saved.count, 4)

        fixture.coordinator.resetForWorkspaceChange()
        fixture.coordinator.reload(sessions: [fixture.session])
        await fixture.waitForIdle()
        fixture.coordinator.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(states.saved.count, 6)
        XCTAssertEqual(states.saved.last?.phase, .completed)
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

    init(availability: MeetingIntelligenceAvailability,
         generatorOverride: (any MeetingIntelligenceGenerating)? = nil,
         stateStoreOverride: (any MeetingIntelligenceStateStoring)? = nil,
         availabilityOverride: (any MeetingIntelligenceAvailabilityChecking)? = nil,
         publisherOverride: (any MeetingIntelligencePublishing)? = nil,
         stateSaveSchedulerOverride: (any MeetingIntelligenceStateSaveScheduling)? = nil) throws {
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
        coordinator = .init(providerRepository: repository, expectedPublicationSourceID: coordinatorID, transcriptReader: reader,
                            availabilityChecker: availabilityOverride ?? self.availability, generator: generatorOverride ?? generator,
                            publisher: publisherOverride ?? publisher, artifactStore: artifactStore, stateStore: stateStoreOverride ?? stateStore,
                            stateSaveScheduler: stateSaveSchedulerOverride ?? ImmediateTestStateSaveScheduler(),
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
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
    }

    private static func makeSnapshot(llmModel: String) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: .validated(baseURLText: "http://127.0.0.1:8080", asrModel: "asr", llmModel: llmModel,
                                            language: "en", prompt: ""), apiKey: nil)
    }
}

private actor GenerationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private final class BlockingCoordinatorGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    let entered: XCTestExpectation
    let finished: XCTestExpectation?
    let gate: GenerationGate
    private(set) var requests = 0
    private(set) var capturedModels: [String] = []
    let emitsLateProgress: Bool
    init(entered: XCTestExpectation, finished: XCTestExpectation? = nil, gate: GenerationGate, emitsLateProgress: Bool = false) {
        self.entered = entered; self.finished = finished; self.gate = gate; self.emitsLateProgress = emitsLateProgress
    }
    func generate(transcript _: TranscriptDocumentSnapshot, snapshot: OpenAICompatibleProviderSnapshot,
                  onProgress: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        requests += 1
        capturedModels.append(snapshot.profile.llmModel)
        if requests == 1 { entered.fulfill() }
        await gate.wait()
        if emitsLateProgress { onProgress(.init(stage: .generatingFinal, current: 99, total: 99)) }
        if requests == 1 { finished?.fulfill() }
        return .init(title: "Generated", summary: "Summary")
    }
}

private final class BlockingAvailability: MeetingIntelligenceAvailabilityChecking, @unchecked Sendable {
    let entered: XCTestExpectation
    let gate: GenerationGate
    init(entered: XCTestExpectation, gate: GenerationGate) { self.entered = entered; self.gate = gate }
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability {
        entered.fulfill()
        await gate.wait()
        return .confirmed
    }
}

private final class BlockingPublisher: MeetingIntelligencePublishing, @unchecked Sendable {
    let entered: XCTestExpectation
    let finished = XCTestExpectation(description: "publisher finished")
    let gate: GenerationGate
    init(entered: XCTestExpectation, gate: GenerationGate) { self.entered = entered; self.gate = gate }
    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        entered.fulfill()
        await gate.wait()
        finished.fulfill()
        return .init(artifact: .init(schemaVersion: 1, summary: request.content.summary, suggestedTitle: request.content.title,
                                     sourceTranscriptSHA256: request.sourceRevision.sha256,
                                     sourceTranscriptByteCount: request.sourceRevision.byteCount,
                                     model: request.snapshot.profile.llmModel, generatedAt: request.generatedAt, intent: request.intent),
                     titleWasApplied: false, titleWarning: nil)
    }
}

private struct ImmediateTestStateSaveScheduler: MeetingIntelligenceStateSaveScheduling {
    func awaitAdmission() async {}
}

private final class BlockingStateSaveScheduler: MeetingIntelligenceStateSaveScheduling, @unchecked Sendable {
    let entered: XCTestExpectation
    let released: XCTestExpectation
    let gate: GenerationGate
    init(entered: XCTestExpectation, released: XCTestExpectation, gate: GenerationGate) {
        self.entered = entered; self.released = released; self.gate = gate
    }
    func awaitAdmission() async { entered.fulfill(); await gate.wait(); released.fulfill() }
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
    private(set) var capturedModels: [String] = []
    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        requests += 1
        capturedModels.append(request.snapshot.profile.llmModel)
        return .init(artifact: .init(schemaVersion: 1, summary: request.content.summary, suggestedTitle: request.content.title,
                                     sourceTranscriptSHA256: request.sourceRevision.sha256, sourceTranscriptByteCount: request.sourceRevision.byteCount,
                                     model: request.snapshot.profile.llmModel, generatedAt: request.generatedAt, intent: request.intent),
                     titleWasApplied: false, titleWarning: nil)
    }
}

private final class CoordinatorArtifactStore: MeetingIntelligenceArtifactStoring, @unchecked Sendable {
    var loaded: MeetingIntelligenceArtifact?
    var loadError: Error?
    func load(in _: URL) throws -> MeetingIntelligenceArtifact? {
        if let loadError { throw loadError }
        return loaded
    }
    func stage(_: MeetingIntelligenceArtifact, in folder: URL) throws -> URL { folder }
    func promoteStaged(_: URL, in _: URL) throws {}
    func removeStaged(_: URL, in _: URL) throws {}
}

private final class CoordinatorStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    var loaded: MeetingIntelligenceState?
    func load(in _: URL) throws -> MeetingIntelligenceState? { loaded }
    func save(_: MeetingIntelligenceState, in _: URL) throws {}
    func remove(in _: URL) throws {}
}

private final class BlockingStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    let entered: XCTestExpectation
    let release: DispatchSemaphore
    private(set) var saved: [MeetingIntelligenceState] = []
    private var shouldBlock = true
    init(entered: XCTestExpectation, release: DispatchSemaphore) { self.entered = entered; self.release = release }
    func load(in _: URL) throws -> MeetingIntelligenceState? { nil }
    func save(_ state: MeetingIntelligenceState, in _: URL) throws {
        if shouldBlock {
            shouldBlock = false
            entered.fulfill()
            release.wait()
        }
        saved.append(state)
    }
    func remove(in _: URL) throws {}
}

private final class RecordingStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    private(set) var saved: [MeetingIntelligenceState] = []
    func load(in _: URL) throws -> MeetingIntelligenceState? { nil }
    func save(_ state: MeetingIntelligenceState, in _: URL) throws { saved.append(state) }
    func remove(in _: URL) throws {}
}
