import Combine
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelMeetingIntelligenceIntegrationTests: XCTestCase {
    func testTranscriptionPublicationEntersAutomaticMeetingIntelligenceOnlyAfterSearchRebuild() async throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let rebuildStarted = expectation(description: "search rebuild started")
        let searchLoader = BlockingIntegrationSearchLoader(started: rebuildStarted)
        defer { searchLoader.release() }
        let generator = IntegrationGenerator()
        var coordinator: MeetingIntelligenceJobCoordinator!
        let model = fixture.transcribingModel(
            coordinatorFactory: { sourceID in
                let created = fixture.coordinator(
                    expectedPublicationSourceID: sourceID,
                    availability: .confirmed,
                    generator: generator
                )
                coordinator = created
                return created
            },
            searchLoader: { [searchLoader] session in searchLoader.load(session) }
        )
        model.setOutputFolder(fixture.folder)
        model.sessions = [fixture.session()]

        XCTAssertTrue(model.aiProviderSettingsModel.hasSavedProfile, model.aiProviderSettingsModel.status)

        model.transcribe(session: fixture.session())
        await fulfillment(of: [rebuildStarted], timeout: 1)

        XCTAssertEqual(generator.requests, 0,
                       "Automatic MI must wait until the published transcript is searchable.")
        searchLoader.release()
        let generatorStarted = await eventually { generator.requests == 1 }
        XCTAssertTrue(generatorStarted)
        await coordinator.waitUntilIdleForTesting(sessionID: fixture.session().id)

        XCTAssertEqual(coordinator.presentation(for: fixture.session()).phase, .ready)
    }

    func testUnconfirmedTranscriptionPublicationNeverStartsAutomaticGenerator() async throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let generator = IntegrationGenerator()
        var coordinator: MeetingIntelligenceJobCoordinator!
        let model = fixture.transcribingModel(coordinatorFactory: { sourceID in
            let created = fixture.coordinator(
                expectedPublicationSourceID: sourceID,
                availability: .unconfirmed(.modelNotAdvertised),
                generator: generator
            )
            coordinator = created
            return created
        })
        model.setOutputFolder(fixture.folder)
        model.sessions = [fixture.session()]

        XCTAssertTrue(model.aiProviderSettingsModel.hasSavedProfile, model.aiProviderSettingsModel.status)

        model.transcribe(session: fixture.session())
        let transcriptionFinished = await eventually { model.transcribingSessionID == nil }
        XCTAssertTrue(transcriptionFinished)
        let becameUnconfirmed = await eventually {
            coordinator.presentation(for: fixture.session()).unavailableReason == .modelNotAdvertised
        }
        XCTAssertTrue(becameUnconfirmed)
        await coordinator.waitUntilIdleForTesting(sessionID: fixture.session().id)

        XCTAssertEqual(generator.requests, 0)
        XCTAssertEqual(coordinator.presentation(for: fixture.session()).unavailableReason,
                       .modelNotAdvertised)
    }

    func testWorkspaceRoundTripRejectsOldPublicationAndAcceptsFutureAttemptOnce() async throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let otherWorkspace = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: otherWorkspace) }
        let service = DeferredIntegrationTranscriptionService()
        let searchLoader = CountingIntegrationSearchLoader()
        let availability = CountingIntegrationAvailability(
            result: .confirmed
        )
        let generator = IntegrationGenerator()
        var coordinator: MeetingIntelligenceJobCoordinator!
        let model = fixture.transcribingModel(
            coordinatorFactory: { sourceID in
                let created = fixture.coordinator(
                    expectedPublicationSourceID: sourceID,
                    availability: .confirmed,
                    generator: generator,
                    availabilityChecker: availability
                )
                coordinator = created
                return created
            },
            searchLoader: { [searchLoader] session in
                searchLoader.load(session)
            },
            transcriptionService: service
        )
        model.setOutputFolder(fixture.folder)
        model.sessions = [fixture.session()]

        model.transcribe(session: fixture.session())
        await service.waitForRequestCount(1)
        model.setOutputFolder(otherWorkspace)
        model.setOutputFolder(fixture.folder)
        _ = service.complete(at: 0)
        let oldAttemptFinished = await eventually {
            model.transcribingSessionID == nil
        }
        XCTAssertTrue(oldAttemptFinished)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(searchLoader.requests, 0)
        XCTAssertEqual(availability.requests, 0)
        XCTAssertEqual(generator.requests, 0)

        model.transcribe(session: fixture.session())
        await service.waitForRequestCount(2)
        _ = service.complete(at: 1)
        let futureAttemptAccepted = await eventually {
            generator.requests == 1
        }
        XCTAssertTrue(futureAttemptAccepted)
        await coordinator.waitUntilIdleForTesting(
            sessionID: fixture.session().id
        )

        XCTAssertEqual(searchLoader.requests, 1)
        XCTAssertEqual(availability.requests, 1)
        XCTAssertEqual(generator.requests, 1)
    }

    func testWorkspaceSwitchWhileSearchCompletionIsQueuedCannotStartMeetingIntelligence() async throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let otherWorkspace = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: otherWorkspace) }
        let rebuildStarted = expectation(description: "search rebuild started")
        let rebuildFinished = expectation(description: "search rebuild finished")
        let searchLoader = BlockingIntegrationSearchLoader(
            started: rebuildStarted,
            finished: rebuildFinished
        )
        defer { searchLoader.release() }
        let availability = CountingIntegrationAvailability(
            result: .confirmed
        )
        let generator = IntegrationGenerator()
        let model = fixture.transcribingModel(
            coordinatorFactory: { sourceID in
                fixture.coordinator(
                    expectedPublicationSourceID: sourceID,
                    availability: .confirmed,
                    generator: generator,
                    availabilityChecker: availability
                )
            },
            searchLoader: { [searchLoader] session in
                searchLoader.load(session)
            }
        )
        model.setOutputFolder(fixture.folder)
        model.sessions = [fixture.session()]

        model.transcribe(session: fixture.session())
        await fulfillment(of: [rebuildStarted], timeout: 1)
        model.setOutputFolder(otherWorkspace)
        searchLoader.release()
        await fulfillment(of: [rebuildFinished], timeout: 1)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertFalse(
            model.sessions.contains(where: { $0.id == fixture.session().id })
        )
        XCTAssertTrue(
            RecordingLibraryQuery(text: "published transcript")
                .filter(model.sessions)
                .isEmpty
        )
        XCTAssertEqual(availability.requests, 0)
        XCTAssertEqual(generator.requests, 0)
    }

    func testSavingEditedTranscriptImmediatelyUpdatesSearchAndMarksArtifactStaleWithoutAutomaticGeneration() async throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let generator = IntegrationGenerator()
        let coordinator = fixture.coordinator(availability: .confirmed, generator: generator)
        let model = fixture.model(coordinator: coordinator, reloader: { $0 })
        model.setOutputFolder(fixture.folder)
        model.sessions = [fixture.session()]
        let original = "original searchable transcript"
        let edited = "edited searchable transcript"
        try original.write(to: fixture.folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        // A confirmed automatic generation creates the exact artifact used by
        // the subsequent save path.
        coordinator.handleTranscriptPublished(fixture.publicationEvent())
        await coordinator.waitUntilIdleForTesting(sessionID: fixture.session().id)
        XCTAssertEqual(coordinator.presentation(for: fixture.session()).phase, .ready)
        XCTAssertEqual(generator.requests, 1)

        model.saveTranscript(edited, for: fixture.session())
        let editedBecameSearchable = await eventually {
            RecordingLibraryQuery(text: edited).filter(model.sessions).map(\.id) == [fixture.session().id]
        }
        XCTAssertTrue(editedBecameSearchable)
        await coordinator.waitUntilIdleForTesting(sessionID: fixture.session().id)

        XCTAssertEqual(coordinator.presentation(for: fixture.session()).phase, .stale)
        XCTAssertEqual(generator.requests, 1,
                       "Editing is observational; it must not trigger automatic regeneration.")
    }
    func testMeetingIntelligenceSuccessReloadsOnlyItsSessionOffMain() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let reloaded = fixture.session(with: .init(title: "Suggested", titleOrigin: .meetingIntelligence))
        let reloader = SessionReloader(result: reloaded)
        let coordinator = fixture.coordinator()
        let model = fixture.model(
            coordinator: coordinator,
            reloader: { [reloader] session in reloader.reload(session) }
        )
        model.setOutputFolder(fixture.folder)
        model.sessions = [fixture.session()]
        let updated = expectation(description: "targeted session applied on main")
        let cancellable = model.$sessions.dropFirst().sink { sessions in
            if sessions == [reloaded] { updated.fulfill() }
        }

        coordinator.onSuccessfulPublication?(fixture.session())
        wait(for: [reloader.called], timeout: 1)
        wait(for: [updated], timeout: 1)

        XCTAssertFalse(reloader.wasCalledOnMain)
        XCTAssertEqual(model.sessions, [reloaded])
        withExtendedLifetime(cancellable) {}
    }

    func testWorkspaceSwitchSuppressesOldMeetingIntelligenceCallback() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let reloader = SessionReloader(result: fixture.session())
        let model = fixture.model(coordinator: coordinator, reloader: { [reloader] session in reloader.reload(session) })
        let newWorkspace = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: newWorkspace) }

        model.setOutputFolder(newWorkspace)
        coordinator.onSuccessfulPublication?(fixture.session())

        XCTAssertEqual(reloader.callCount, 0)
        XCTAssertFalse(model.sessions.contains(where: { $0.id == fixture.session().id }))
    }

    func testLatestMeetingIntelligenceReloadWinsAfterEarlierReloadIsReleased() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let first = fixture.session(with: .init(title: "First"))
        let latest = fixture.session(with: .init(title: "Latest"))
        let reloader = SequencedSessionReloader(first: first, latest: latest)
        let coordinator = fixture.coordinator()
        let model = fixture.model(coordinator: coordinator, reloader: { [reloader] session in reloader.reload(session) })
        model.setOutputFolder(fixture.folder)
        model.sessions = [fixture.session()]
        let applied = expectation(description: "latest reload applied")
        let cancellable = model.$sessions.dropFirst().sink { sessions in
            if sessions == [latest] { applied.fulfill() }
        }

        coordinator.onSuccessfulPublication?(fixture.session())
        wait(for: [reloader.firstStarted], timeout: 1)
        coordinator.onSuccessfulPublication?(fixture.session())
        reloader.releaseFirst()
        wait(for: [applied], timeout: 1)

        XCTAssertEqual(model.sessions, [latest])
        withExtendedLifetime(cancellable) {}
    }

    func testTrashSuccessRemovesSessionFromProjection() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.remove() }
        let model = AppModel(
            performStartupWork: false,
            initialOutputFolder: fixture.folder.deletingLastPathComponent(),
            recordingSessionTrashHandler: { folder in
                try FileManager.default.removeItem(at: folder)
                return true
            }
        )
        let session = fixture.session()
        model.sessions = [session]

        model.moveSessionToTrash(session)

        XCTAssertFalse(
            model.sessions.contains(where: { $0.id == session.id }),
            model.statusMessage
        )
    }

    func testTrashFailureKeepsSessionProjected() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = RecordingSession(id: missing, folderURL: missing,
                                       recordingURL: missing.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let model = AppModel(performStartupWork: false)
        model.sessions = [session]

        model.moveSessionToTrash(session)

        XCTAssertEqual(model.sessions, [session])
        XCTAssertTrue(model.statusMessage.hasPrefix("Cannot move recording to Trash:"))
    }

    func testSavingTagsAndFavoritePreservesMeetingIntelligenceTitleOrigin() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordingURL = folder.appendingPathComponent("recording.m4a")
        try Data().write(to: recordingURL)
        try RecordingSessionMetadataStore.save(
            .init(title: "Generated", titleOrigin: .meetingIntelligence),
            in: folder
        )
        let session = RecordingSession(
            id: folder.standardizedFileURL,
            folderURL: folder,
            recordingURL: recordingURL,
            createdAt: .now,
            duration: 0,
            fileSize: 0,
            metadata: RecordingSessionMetadataStore.load(in: folder)
        )
        let model = AppModel(performStartupWork: false)

        model.saveMetadata(title: "Generated", tags: "customer", isFavorite: true, for: session)

        let saved = RecordingSessionMetadataStore.load(in: folder)
        XCTAssertEqual(saved.titleOrigin, .meetingIntelligence)
        XCTAssertEqual(saved.tags, ["customer"])
        XCTAssertTrue(saved.isFavorite)
    }

    func testTypedManualMetadataEditMarksTitleManual() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordingURL = folder.appendingPathComponent("recording.m4a")
        try Data().write(to: recordingURL)
        let session = RecordingSession(
            id: folder.standardizedFileURL, folderURL: folder,
            recordingURL: recordingURL, createdAt: .now, duration: 0,
            fileSize: 0, metadata: .init(title: "Generated", titleOrigin: .meetingIntelligence)
        )
        let model = AppModel(performStartupWork: false)

        model.saveMetadata(titleEdit: .manual("Customer review"), tags: "", isFavorite: false, for: session)

        let saved = RecordingSessionMetadataStore.load(in: folder)
        XCTAssertEqual(saved.title, "Customer review")
        XCTAssertEqual(saved.titleOrigin, .manual)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@MainActor
private final class IntegrationFixture {
    let folder: URL
    let recordingURL: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recordingURL = folder.appendingPathComponent("recording.m4a")
        try Data().write(to: recordingURL)
        try "transcript".write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func session(with metadata: RecordingSessionMetadata = .init()) -> RecordingSession {
        .init(id: folder.standardizedFileURL, folderURL: folder, recordingURL: recordingURL,
              createdAt: .distantPast, duration: 0, fileSize: 0, metadata: metadata)
    }

    func coordinator(
        expectedPublicationSourceID: UUID? = nil,
        availability: MeetingIntelligenceAvailability = .unconfirmed(.connectionFailed),
        generator: IntegrationGenerator = .init(),
        availabilityChecker: (any MeetingIntelligenceAvailabilityChecking)? = nil
    ) -> MeetingIntelligenceJobCoordinator {
        let gate = RecordingSessionMutationGate()
        let checker: any MeetingIntelligenceAvailabilityChecking =
            availabilityChecker ?? IntegrationAvailability(result: availability)
        return MeetingIntelligenceJobCoordinator(
            providerRepository: IntegrationRepository(), expectedPublicationSourceID: expectedPublicationSourceID ?? publicationSourceID,
            availabilityChecker: checker, generator: generator,
            publisher: MeetingIntelligencePublisher(mutationGate: gate, artifactStore: MeetingIntelligenceArtifactStore(mutationGate: gate)), artifactStore: MeetingIntelligenceArtifactStore(mutationGate: gate),
            stateStore: MeetingIntelligenceStateStore(mutationGate: gate)
        )
    }

    private let publicationSourceID = UUID()

    func publicationEvent() -> TranscriptPublished {
        let snapshot = try! SecureTranscriptDocumentReader().readCanonical(in: folder, allowLegacy: false)
        return .init(
            session: session(), canonicalURL: snapshot.url, revision: snapshot.revision,
            normalizedSessionFolder: folder.resolvingSymlinksInPath().standardizedFileURL,
            identity: .init(coordinatorInstanceID: publicationSourceID, generation: 1, attemptID: UUID())
        )
    }

    func model(coordinator: MeetingIntelligenceJobCoordinator,
               reloader: @escaping @Sendable (RecordingSession) -> RecordingSession) -> AppModel {
        AppModel(performStartupWork: false, recordingSessionReloader: reloader,
                 meetingIntelligenceCoordinatorFactory: { _, _, _ in coordinator })
    }

    func transcribingModel(
        coordinatorFactory: @escaping (UUID) -> MeetingIntelligenceJobCoordinator,
        searchLoader: @escaping @Sendable (RecordingSession) -> RecordingLibrarySearchDocument = { session in
            RecordingLibrarySearchDocument.load(folderURL: session.folderURL, displayName: session.displayName, createdAt: session.createdAt, metadata: session.metadata)
        },
        transcriptionService: any TranscriptionServicing =
            IntegrationTranscriptionService()
    ) -> AppModel {
        let model = AppModel(
            providerRepository: IntegrationRepository(),
            inputDevices: { [] }, defaultInputDeviceID: { nil }, performStartupWork: false,
            recordingSearchDocumentLoader: searchLoader,
            transcriptionAudioPreparer: IntegrationAudioPreparer(),
            transcriptionService: transcriptionService,
            meetingIntelligenceCoordinatorFactory: { _, sourceID, _ in
                coordinatorFactory(sourceID)
            }
        )
        model.aiProviderSettingsModel.baseURLText = "https://api.example.com/v1"
        model.aiProviderSettingsModel.asrModel = "asr"
        model.aiProviderSettingsModel.llmModel = "llm"
        model.aiProviderSettingsModel.language = "en"
        model.aiProviderSettingsModel.save()
        return model
    }
}

private final class SessionReloader: @unchecked Sendable {
    let result: RecordingSession
    let called = XCTestExpectation(description: "targeted session reload")
    private(set) var wasCalledOnMain = true
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.withLock { count } }
    init(result: RecordingSession) { self.result = result }
    func reload(_: RecordingSession) -> RecordingSession {
        lock.withLock { count += 1 }
        wasCalledOnMain = Thread.isMainThread
        called.fulfill()
        return result
    }
}

private final class SequencedSessionReloader: @unchecked Sendable {
    let firstStarted = XCTestExpectation(description: "first reload started")
    private let first: RecordingSession
    private let latest: RecordingSession
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    init(first: RecordingSession, latest: RecordingSession) { self.first = first; self.latest = latest }
    func reload(_: RecordingSession) -> RecordingSession {
        let call = lock.withLock { count += 1; return count }
        if call == 1 { firstStarted.fulfill(); release.wait(); return first }
        return latest
    }
    func releaseFirst() { release.signal() }
}

private final class IntegrationRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    private var savedProfile: OpenAICompatibleProviderProfile?
    func loadProfile() throws -> OpenAICompatibleProviderProfile? { savedProfile }
    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey _: String?) throws { savedProfile = profile }
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { try snapshot(overriding: savedProfile ?? profile) }
    func snapshot(overriding _: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { try .validated(profile: profile, apiKey: "test") }
    func hasAPIKey() throws -> Bool { true }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL _: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}
private extension IntegrationRepository {
    var profile: OpenAICompatibleProviderProfile { try! .validated(baseURLText: "https://api.example.com/v1", asrModel: "asr", llmModel: "llm", language: "en", prompt: "") }
}
private struct IntegrationAvailability: MeetingIntelligenceAvailabilityChecking {
    let result: MeetingIntelligenceAvailability
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability { result }
}
private final class CountingIntegrationAvailability:
    MeetingIntelligenceAvailabilityChecking,
    @unchecked Sendable
{
    private let result: MeetingIntelligenceAvailability
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }

    init(result: MeetingIntelligenceAvailability) {
        self.result = result
    }

    func availability(
        for _: OpenAICompatibleProviderSnapshot
    ) async -> MeetingIntelligenceAvailability {
        lock.withLock { count += 1 }
        return result
    }
}
private final class IntegrationGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    func generate(transcript _: TranscriptDocumentSnapshot, snapshot _: OpenAICompatibleProviderSnapshot, onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void) async throws -> MeetingIntelligenceGeneratedContent {
        lock.withLock { count += 1 }
        return .init(title: "Customer Review", summary: "Summary")
    }
}
private struct IntegrationAudioPreparer: TranscriptionAudioPreparing {
    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio { .init(audioURL: session.recordingURL, cleanupURL: nil) }
    func cleanup(_: PreparedTranscriptionAudio) {}
}
private struct IntegrationTranscriptionService: TranscriptionServicing {
    func transcribe(_ request: TranscriptionServiceRequest, onProgress _: @escaping @Sendable (TranscriptionServiceProgress) -> Void) async throws -> TranscriptionServiceResult {
        let transcriptURL = request.sessionFolder.appendingPathComponent("transcript.txt")
        try "published transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let revision = try SecureTranscriptDocumentReader().readCanonical(in: request.sessionFolder, allowLegacy: false).revision
        return .init(transcriptURL: transcriptURL, rawTranscriptURL: nil, manifestURL: nil,
                     logURL: nil, committedTranscriptRevision: revision)
    }
}
private final class DeferredIntegrationTranscriptionService:
    TranscriptionServicing,
    @unchecked Sendable
{
    private struct Pending {
        let request: TranscriptionServiceRequest
        var continuation:
            CheckedContinuation<TranscriptionServiceResult, Error>?
    }

    private let lock = NSLock()
    private var pending: [Pending] = []

    func transcribe(
        _ request: TranscriptionServiceRequest,
        onProgress _: @escaping @Sendable (
            TranscriptionServiceProgress
        ) -> Void
    ) async throws -> TranscriptionServiceResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                pending.append(.init(
                    request: request,
                    continuation: continuation
                ))
            }
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while lock.withLock({ pending.count < count }) {
            await Task.yield()
        }
    }

    func complete(at index: Int) -> Bool {
        let value: Pending? = lock.withLock {
            guard pending.indices.contains(index),
                  pending[index].continuation != nil else {
                return nil
            }
            let value = pending[index]
            pending[index].continuation = nil
            return value
        }
        guard let value, let continuation = value.continuation else {
            return false
        }
        do {
            let transcriptURL = value.request.sessionFolder
                .appendingPathComponent("transcript.txt")
            try "published transcript \(index)".write(
                to: transcriptURL,
                atomically: true,
                encoding: .utf8
            )
            let revision = try SecureTranscriptDocumentReader()
                .readCanonical(
                    in: value.request.sessionFolder,
                    allowLegacy: false
                ).revision
            continuation.resume(returning: .init(
                transcriptURL: transcriptURL,
                rawTranscriptURL: nil,
                manifestURL: nil,
                logURL: nil,
                committedTranscriptRevision: revision
            ))
        } catch {
            continuation.resume(throwing: error)
        }
        return true
    }
}
private final class CountingIntegrationSearchLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }

    func load(
        _ session: RecordingSession
    ) -> RecordingLibrarySearchDocument {
        lock.withLock { count += 1 }
        return RecordingLibrarySearchDocument.load(
            folderURL: session.folderURL,
            displayName: session.displayName,
            createdAt: session.createdAt,
            metadata: session.metadata
        )
    }
}
private final class BlockingIntegrationSearchLoader: @unchecked Sendable {
    private let started: XCTestExpectation
    private let finished: XCTestExpectation?
    private let semaphore = DispatchSemaphore(value: 0)
    init(
        started: XCTestExpectation,
        finished: XCTestExpectation? = nil
    ) {
        self.started = started
        self.finished = finished
    }
    func load(_ session: RecordingSession) -> RecordingLibrarySearchDocument {
        started.fulfill()
        semaphore.wait()
        defer { finished?.fulfill() }
        return RecordingLibrarySearchDocument.load(
            folderURL: session.folderURL,
            displayName: session.displayName,
            createdAt: session.createdAt,
            metadata: session.metadata
        )
    }
    func release() { semaphore.signal() }
}
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 { if condition() { return true }; await Task.yield() }
    return false
}
private enum IntegrationError: Error { case unavailable }
