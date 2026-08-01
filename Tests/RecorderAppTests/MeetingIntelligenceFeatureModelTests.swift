import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceFeatureModelTests: XCTestCase {
    func testPublicationObserverTokenCannotRemoveReplacementAndShutdownClearsIt() async throws {
        let fixture = try FeatureFixture()
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        var oldCalls = 0
        var replacementCalls = 0
        let oldToken = feature.observePublication { _ in oldCalls += 1 }
        let replacementToken = feature.observePublication { _ in replacementCalls += 1 }

        feature.removePublicationObserver(oldToken)
        XCTAssertNotNil(feature.onPublished)

        feature.generate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(oldCalls, 0)
        XCTAssertEqual(replacementCalls, 1)

        feature.removePublicationObserver(replacementToken)
        XCTAssertNil(feature.onPublished)

        _ = feature.observePublication { _ in replacementCalls += 1 }
        feature.shutdown()
        XCTAssertNil(feature.onPublished)
    }

    func testFeatureForwardsManualCommandsAndTypedPublicationExactlyOnce() async throws {
        let fixture = try FeatureFixture()
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        var publications: [MeetingIntelligencePublished] = []
        feature.onPublished = { publications.append($0) }

        let availabilityFence = WorkspacePublicationFence(revision: 101)
        let generateFence = WorkspacePublicationFence(revision: 102)
        let regenerateFence = WorkspacePublicationFence(revision: 103)
        let retryFence = WorkspacePublicationFence(revision: 104)
        let explicitTitleFence = WorkspacePublicationFence(revision: 105)

        feature.checkAvailability(for: fixture.session, workspaceFence: availabilityFence)
        await fixture.waitForIdle()
        feature.generate(for: fixture.session, workspaceFence: generateFence)
        await fixture.waitForIdle()
        feature.regenerate(for: fixture.session, workspaceFence: regenerateFence)
        await fixture.waitForIdle()
        feature.retryGeneration(for: fixture.session, workspaceFence: retryFence)
        await fixture.waitForIdle()
        feature.cancel(sessionID: fixture.session.id)
        await fixture.waitForIdle()
        feature.applySuggestedTitle(for: fixture.session, workspaceFence: explicitTitleFence)
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 4)
        XCTAssertEqual(
            publications.map(\.identity.kind),
            [.artifactAndAutomaticTitle, .artifactAndAutomaticTitle, .artifactAndAutomaticTitle, .explicitSuggestedTitle]
        )
        XCTAssertEqual(fixture.counters.snapshot, .init(availability: 1, generation: 3, publication: 3))
        XCTAssertEqual(fixture.publisher.intents, [.generate, .regenerate, .retryGeneration])
        XCTAssertEqual(
            publications.map(\.identity.workspaceFence),
            [generateFence, regenerateFence, retryFence, explicitTitleFence]
        )
        XCTAssertEqual(fixture.metadata.saves, 1)
        XCTAssertTrue(publications.allSatisfy {
            $0.identity.coordinatorInstanceID == feature.publicationSourceID
        })
        XCTAssertEqual(feature.presentation(for: fixture.session).phase, .cancelled)
    }

    func testFeatureDeliversPublicationAlreadyDurableWhenShutdownClearsCallback() async throws {
        let delivery = FeatureBlockingPublicationDelivery()
        let fixture = try FeatureFixture(publicationDeliveryScheduler: delivery)
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        let fence = WorkspacePublicationFence(revision: 501)
        let delivered = expectation(description: "durable feature publication delivered")
        var publications: [MeetingIntelligencePublished] = []
        feature.onPublished = {
            publications.append($0)
            delivered.fulfill()
        }

        feature.generate(for: fixture.session, workspaceFence: fence)
        await fulfillment(of: [delivery.admitted], timeout: 1)
        feature.shutdown()
        feature.shutdown()
        await delivery.release()
        await fulfillment(of: [delivered], timeout: 1)
        await fixture.waitForIdle()

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.identity.workspaceFence, fence)
        XCTAssertEqual(publications.first?.identity.coordinatorInstanceID, feature.publicationSourceID)
        XCTAssertEqual(publications.first?.canonicalSession.id, fixture.session.id)
        XCTAssertEqual(fixture.counters.snapshot.publication, 1)
    }

    func testFeatureForwardsAutomaticPublicationAndTranscriptEditWithoutAutomaticRestart() async throws {
        let fixture = try FeatureFixture()
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        let published = expectation(description: "automatic feature publication")
        feature.onPublished = { _ in published.fulfill() }

        feature.handleTranscriptPublished(fixture.event(generation: 1))
        await fulfillment(of: [published], timeout: 1)
        await fixture.waitForIdle()
        XCTAssertEqual(feature.presentation(for: fixture.session).phase, .ready)

        fixture.replaceTranscriptForEdit()
        let beforeEdit = fixture.counters.snapshot
        feature.transcriptDidSave(fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(feature.presentation(for: fixture.session).phase, .stale)
        XCTAssertEqual(fixture.counters.snapshot, beforeEdit)
    }

    func testRemoveResetAndShutdownAreIdempotentAndDetachCallback() async throws {
        let fixture = try FeatureFixture()
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        var publications = 0
        feature.onPublished = { _ in publications += 1 }

        feature.generate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(publications, 1)

        feature.remove(sessionID: fixture.session.id)
        let afterRemove = feature.snapshot.revision
        feature.remove(sessionID: fixture.session.id)
        XCTAssertEqual(feature.snapshot.revision, afterRemove)
        feature.resetForWorkspaceChange()
        let afterReset = feature.snapshot.revision
        feature.resetForWorkspaceChange()
        XCTAssertEqual(feature.snapshot.revision, afterReset + 1)

        feature.shutdown()
        feature.shutdown()
        feature.generate(for: fixture.session)
        await fixture.waitForIdle()
        XCTAssertEqual(publications, 1)
    }

    func testAliasLifecycleCallsDoNotReadOrChangeCanonicalSnapshot() async throws {
        let fixture = try FeatureFixture()
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        feature.checkAvailability(for: fixture.session)
        await fixture.waitForIdle()
        let revision = feature.snapshot.revision
        let counts = fixture.ioSnapshot
        let aliasURL = fixture.session.folderURL.appendingPathComponent("..").appendingPathComponent(fixture.session.folderURL.lastPathComponent)
        let alias = RecordingSession(id: aliasURL, folderURL: aliasURL, recordingURL: aliasURL.appendingPathComponent("recording.m4a"), createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())

        feature.transcriptDidSave(alias)
        feature.reload(sessions: [alias])

        XCTAssertEqual(feature.snapshot.revision, revision)
        XCTAssertEqual(fixture.ioSnapshot, counts)
        XCTAssertNotNil(feature.snapshot.presentation(for: fixture.session))
    }

    func testShutdownBeforeDurablePublicationSuppressesLatePublicationAndSnapshotChanges() async throws {
        let entered = expectation(description: "feature generator entered")
        let finished = expectation(description: "feature generator finished after release")
        let gate = FeatureGenerationGate()
        let generator = BlockingFeatureGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try FeatureFixture(generator: generator)
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        var publications = 0
        feature.onPublished = { _ in publications += 1 }

        feature.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        let revisionBeforeShutdown = feature.snapshot.revision
        let presentationBeforeShutdown = feature.presentation(for: fixture.session)

        feature.shutdown()
        feature.shutdown()
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)
        await fixture.waitForIdle()

        XCTAssertEqual(publications, 0)
        XCTAssertEqual(feature.snapshot.revision, revisionBeforeShutdown)
        XCTAssertEqual(feature.presentation(for: fixture.session), presentationBeforeShutdown)
        XCTAssertEqual(generator.requests, 1)
        XCTAssertEqual(fixture.counters.snapshot.publication, 0)
    }

    func testProviderSaveDoesNotMutateActiveMeetingIntelligenceSnapshotAndLaterAttemptUsesSavedProfile() async throws {
        let entered = expectation(description: "meeting intelligence generation entered")
        let finished = expectation(description: "meeting intelligence generation finished")
        let gate = FeatureGenerationGate()
        let generator = BlockingFeatureGenerator(entered: entered, finished: finished, gate: gate)
        let provider = FeatureProvider()
        let fixture = try FeatureFixture(providerRepository: provider, generator: generator)
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        let settings = AIProviderSettingsModel(
            repository: provider,
            loadImmediately: false
        )
        settings.baseURLText = "https://api.example/v1"
        settings.asrModel = "saved-asr"
        settings.llmModel = "saved-llm"
        settings.selectedLanguage = .cantonese

        feature.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        if case .generating = feature.presentation(for: fixture.session).phase {
            // The active job must remain in place while provider settings save.
        } else {
            XCTFail("Expected active meeting intelligence generation")
        }

        settings.save()

        XCTAssertEqual(generator.requests, 1)
        XCTAssertEqual(generator.capturedModels, ["llm"])
        if case .generating = feature.presentation(for: fixture.session).phase {
            // Saving settings must not cancel or replace the active job.
        } else {
            XCTFail("Expected active meeting intelligence generation after save")
        }
        await gate.release()
        await fulfillment(of: [finished], timeout: 1)
        await fixture.waitForIdle()

        feature.generate(for: fixture.session)
        await fixture.waitForIdle()

        XCTAssertEqual(generator.capturedModels, ["llm", "saved-llm"])
    }

    func testObservedFeatureRerendersOpenTranscriptDetailFromGeneratingToReady() async throws {
        let entered = expectation(description: "renderable generation entered")
        let finished = expectation(description: "renderable generation finished")
        let published = expectation(description: "typed publication delivered")
        let gate = FeatureGenerationGate()
        let generator = BlockingFeatureGenerator(entered: entered, finished: finished, gate: gate)
        let fixture = try FeatureFixture(generator: generator)
        let feature = MeetingIntelligenceFeatureModel(coordinator: fixture.coordinator)
        feature.onPublished = { _ in published.fulfill() }
        let host = try FeatureObservedTranscriptHost(feature: feature, session: fixture.session)
        defer { host.close() }

        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceGenerate))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceSuggestedTitle))

        feature.generate(for: fixture.session)
        await fulfillment(of: [entered], timeout: 1)
        host.render()
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceCancel))
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceStatus))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceSuggestedTitle))

        await gate.release()
        await fulfillment(of: [finished, published], timeout: 1)
        await fixture.waitForIdle()
        host.render()

        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceSummary))
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceSuggestedTitle))
        XCTAssertTrue(host.containsText("Generated title"))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceCancel))
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
    }
}

@MainActor
private final class FeatureFixture {
    let session: RecordingSession
    let coordinator: MeetingIntelligenceJobCoordinator
    let counters = FeatureCounters()
    let metadata = FeatureMetadataStore()
    let artifacts = FeatureArtifactStore()
    let states = FeatureStateStore()
    let publisher: FeaturePublisher
    private let reader: FeatureTranscriptReader

    init(
        providerRepository: (any OpenAICompatibleProviderManaging)? = nil,
        generator: (any MeetingIntelligenceGenerating)? = nil,
        publicationDeliveryScheduler: any MeetingIntelligencePublicationDeliveryScheduling = ImmediateMeetingIntelligencePublicationDeliveryScheduler()
    ) throws {
        let folder = RecordingLibraryURLIdentity.normalized(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        session = .init(
            id: folder, folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init()
        )
        let data = Data("Feature transcript".utf8)
        reader = .init(.init(
            url: TranscriptDocumentStore.editableURL(in: folder), data: data,
            revision: .init(sha256: "sha256:" + String(repeating: "a", count: 64), byteCount: data.count)
        ))
        publisher = .init(artifacts: artifacts, counters: counters)
        coordinator = .init(
            providerRepository: providerRepository ?? FeatureProvider(), expectedPublicationSourceID: FeatureFixture.transcriptionSource,
            transcriptReader: reader, availabilityChecker: FeatureAvailability(counters: counters),
            generator: generator ?? FeatureGenerator(counters: counters), publisher: publisher,
            artifactStore: artifacts, stateStore: states,
            titleApplier: MeetingIntelligenceSuggestedTitleApplier(
                mutationGate: RecordingSessionMutationGate(), transcriptReader: reader, metadataStore: metadata
            ),
            publicationDeliveryScheduler: publicationDeliveryScheduler
        )
    }

    func event(generation: UInt64) -> TranscriptPublished {
        .init(
            session: session, canonicalURL: reader.snapshot.url, revision: reader.snapshot.revision,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            identity: .init(coordinatorInstanceID: Self.transcriptionSource, generation: generation, attemptID: UUID())
        )
    }

    func waitForIdle() async {
        await coordinator.waitUntilIdleForTesting(sessionID: session.id)
    }

    var ioSnapshot: FeatureIOSnapshot { .init(reader: reader.reads, artifact: artifacts.loads, state: states.loads) }

    func replaceTranscriptForEdit() {
        let data = Data("Edited feature transcript".utf8)
        reader.snapshot = .init(
            url: reader.snapshot.url, data: data,
            revision: .init(sha256: "sha256:" + String(repeating: "b", count: 64), byteCount: data.count)
        )
    }

    private static let transcriptionSource = UUID()
}

private final class FeatureProvider: OpenAICompatibleProviderManaging, @unchecked Sendable {
    private var value = try! OpenAICompatibleProviderSnapshot.validated(
        profile: .validated(baseURLText: "http://127.0.0.1:8080", asrModel: "asr", llmModel: "llm", language: "en", prompt: ""),
        apiKey: nil
    )
    func loadProfile() throws -> OpenAICompatibleProviderProfile? { value.profile }
    func setActiveProviderKind(_: AIProviderKind) throws {}
    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey _: String?) throws {
        value = try .validated(profile: profile, apiKey: value.apiKey)
    }
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { value }
    func snapshot(overriding _: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { value }
    func hasAPIKey() throws -> Bool { false }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL _: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private struct FeatureAvailability: MeetingIntelligenceAvailabilityChecking {
    let counters: FeatureCounters
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability {
        counters.availability += 1
        return .confirmed
    }
}

private struct FeatureGenerator: MeetingIntelligenceGenerating {
    let counters: FeatureCounters
    func generate(transcript _: TranscriptDocumentSnapshot, snapshot _: OpenAICompatibleProviderSnapshot,
                  onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        counters.generation += 1
        return .init(title: "Generated title", summary: "Generated summary")
    }
}

private actor FeatureGenerationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class BlockingFeatureGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    let entered: XCTestExpectation
    let finished: XCTestExpectation
    let gate: FeatureGenerationGate
    private let lock = NSLock()
    private var requestCount = 0
    private var models: [String] = []

    init(entered: XCTestExpectation, finished: XCTestExpectation, gate: FeatureGenerationGate) {
        self.entered = entered
        self.finished = finished
        self.gate = gate
    }

    var requests: Int { lock.withLock { requestCount } }
    var capturedModels: [String] { lock.withLock { models } }

    func generate(
        transcript _: TranscriptDocumentSnapshot,
        snapshot: OpenAICompatibleProviderSnapshot,
        onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent {
        let request = lock.withLock { () -> Int in
            requestCount += 1
            models.append(snapshot.profile.llmModel)
            return requestCount
        }
        if request == 1 { entered.fulfill() }
        await gate.wait()
        if request == 1 { finished.fulfill() }
        return .init(title: "Generated title", summary: "Generated summary")
    }
}

private final class FeaturePublisher: MeetingIntelligencePublishing, @unchecked Sendable {
    let artifacts: FeatureArtifactStore
    let counters: FeatureCounters
    private let lock = NSLock()
    private var publishedRequests: [MeetingIntelligencePublicationRequest] = []

    init(artifacts: FeatureArtifactStore, counters: FeatureCounters) {
        self.artifacts = artifacts
        self.counters = counters
    }

    var intents: [MeetingIntelligenceIntent] {
        lock.withLock { publishedRequests.map(\.intent) }
    }

    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        lock.withLock { publishedRequests.append(request) }
        counters.publication += 1
        let artifact = MeetingIntelligenceArtifact(
            schemaVersion: 1, summary: "Generated summary", suggestedTitle: "Generated title",
            sourceTranscriptSHA256: request.sourceRevision.sha256,
            sourceTranscriptByteCount: request.sourceRevision.byteCount,
            model: request.snapshot.profile.llmModel, generatedAt: .distantPast, intent: request.intent
        )
        artifacts.artifact = artifact
        return .init(artifact: artifact, titleOutcome: .applied)
    }
}

private final class FeatureBlockingPublicationDelivery: MeetingIntelligencePublicationDeliveryScheduling, @unchecked Sendable {
    let admitted = XCTestExpectation(description: "feature durable publication delivery admitted")
    private let gate = FeatureGenerationGate()

    func awaitDeliveryAdmission() async {
        admitted.fulfill()
        await gate.wait()
    }

    func release() async { await gate.release() }
}

private final class FeatureCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var values = (availability: 0, generation: 0, publication: 0)
    var availability: Int { get { lock.withLock { values.availability } } set { lock.withLock { values.availability = newValue } } }
    var generation: Int { get { lock.withLock { values.generation } } set { lock.withLock { values.generation = newValue } } }
    var publication: Int { get { lock.withLock { values.publication } } set { lock.withLock { values.publication = newValue } } }
    var snapshot: FeatureCounterSnapshot {
        lock.withLock { .init(availability: values.availability, generation: values.generation, publication: values.publication) }
    }
}

private struct FeatureCounterSnapshot: Equatable {
    let availability: Int
    let generation: Int
    let publication: Int
}

private final class FeatureTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    var snapshot: TranscriptDocumentSnapshot
    private(set) var reads = 0
    init(_ snapshot: TranscriptDocumentSnapshot) { self.snapshot = snapshot }
    func readCanonical(in _: URL, allowLegacy _: Bool) throws -> TranscriptDocumentSnapshot { reads += 1; return snapshot }
}

private final class FeatureArtifactStore: MeetingIntelligenceArtifactStoring, @unchecked Sendable {
    var artifact: MeetingIntelligenceArtifact?
    private(set) var loads = 0
    func load(in _: URL) throws -> MeetingIntelligenceArtifact? { loads += 1; return artifact }
    func stage(_: MeetingIntelligenceArtifact, in _: URL) throws -> URL { URL(fileURLWithPath: "/tmp/staged") }
    func promoteStaged(_: URL, in _: URL) throws {}
    func removeStaged(_: URL, in _: URL) throws {}
}

private final class FeatureStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    private(set) var loads = 0
    func load(in _: URL) throws -> MeetingIntelligenceState? { loads += 1; return nil }
    func save(_: MeetingIntelligenceState, in _: URL) throws {}
    func remove(in _: URL) throws {}
}

private struct FeatureIOSnapshot: Equatable { let reader: Int; let artifact: Int; let state: Int }

private final class FeatureMetadataStore: RecordingSessionMetadataStoring, @unchecked Sendable {
    var value = RecordingSessionMetadata()
    private(set) var saves = 0
    func load(in _: URL) -> RecordingSessionMetadata { value }
    func save(_ metadata: RecordingSessionMetadata, in _: URL) throws {
        saves += 1
        value = metadata
    }
}

private struct FeatureObservedTranscriptRoot: View {
    @ObservedObject var feature: MeetingIntelligenceFeatureModel
    let session: RecordingSession

    var body: some View {
        TranscriptEditorView(
            session: session,
            load: { "Transcript draft" },
            save: { _ in .saved(sessionID: session.id, .transcript) },
            export: {},
            copy: {},
            meetingIntelligencePresentation: { feature.presentation(for: $0) },
            meetingIntelligenceActions: { session in
                .init(
                    generate: { feature.generate(for: session) },
                    regenerate: { feature.regenerate(for: session) },
                    checkAgain: { feature.checkAvailability(for: session) },
                    retryGeneration: { feature.retryGeneration(for: session) },
                    cancel: { feature.cancel(sessionID: session.id) },
                    applySuggestedTitle: { feature.applySuggestedTitle(for: session) }
                )
            }
        )
    }
}

@MainActor
private final class FeatureObservedTranscriptHost {
    private let hostingView: NSHostingView<FeatureObservedTranscriptRoot>
    private let window: NSWindow

    init(feature: MeetingIntelligenceFeatureModel, session: RecordingSession) throws {
        hostingView = NSHostingView(rootView: .init(feature: feature, session: session))
        let frame = NSRect(x: 0, y: 0, width: 860, height: 680)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }

    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func contains(_ identifier: String) -> Bool {
        allViews(startingAt: hostingView).contains { $0.accessibilityIdentifier() == identifier }
    }

    func containsText(_ text: String) -> Bool {
        let viewText = allViews(startingAt: hostingView).contains { view in
            view.accessibilityLabel() == text
                || view.accessibilityValue() as? String == text
                || view.accessibilityTitle() == text
        }
        return viewText || accessibilityElements(startingAt: hostingView).contains { element in
            accessibilityString(element, key: "accessibilityLabel") == text
                || accessibilityString(element, key: "accessibilityValue") == text
                || accessibilityString(element, key: "accessibilityTitle") == text
        }
    }

    func containsView(named className: String) -> Bool {
        allViews(startingAt: hostingView).contains { String(describing: type(of: $0)).contains(className) }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(startingAt: $0) }
    }

    private func accessibilityElements(startingAt object: NSObject) -> [NSObject] {
        let children = (object.value(forKey: "accessibilityChildren") as? [Any]) ?? []
        return children.compactMap { $0 as? NSObject }.flatMap { [$0] + accessibilityElements(startingAt: $0) }
    }

    private func accessibilityString(_ object: NSObject, key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }
}
