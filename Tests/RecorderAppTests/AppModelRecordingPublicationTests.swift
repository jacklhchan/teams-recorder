import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelRecordingPublicationTests: XCTestCase {
    func testRestoredDestinationIsLibraryWorkspaceButRecordingStartsInPendingRoot() async throws {
        let fixture = try AppModelPublicationFixture()

        XCTAssertEqual(fixture.model.startRecordingFromControl(), .accepted)
        await fixture.waitForRecorderStart()

        XCTAssertEqual(fixture.model.outputFolder, fixture.destination)
        XCTAssertEqual(fixture.engine.outputFolder?.deletingLastPathComponent(), fixture.pendingRoot)
    }

    func testStopEnqueuesPendingSessionWithoutFinalizingLibrary() async throws {
        let fixture = try AppModelPublicationFixture()
        _ = fixture.model.startRecordingFromControl()
        await fixture.waitForRecorderStart()

        fixture.model.startOrStop()
        await fixture.waitForRecorderStop()

        let request = try XCTUnwrap(fixture.publication.requests.single)
        XCTAssertEqual(request.sessionDirectoryName, fixture.localResultFolderName)
        XCTAssertTrue(fixture.library.sessions.isEmpty)
        XCTAssertEqual(fixture.model.statusMessage, "Recording saved locally; publishing")
    }

    func testCurrentPublishedCompletionFinalizesDestinationWithCapturedFence() async throws {
        let fixture = try AppModelPublicationFixture()
        _ = fixture.model.startRecordingFromControl()
        await fixture.waitForRecorderStart()
        fixture.model.startOrStop()
        await fixture.waitForRecorderStop()
        let request = try XCTUnwrap(fixture.publication.requests.single)
        let completion = try fixture.makeDestinationCompletion(for: request)

        fixture.publication.complete(with: completion)
        await fixture.waitForLibraryFinalization()

        let session = try XCTUnwrap(fixture.library.sessions.single)
        XCTAssertEqual(session.folderURL, completion.folderURL.standardizedFileURL)
        XCTAssertEqual(session.recordingURL, completion.recordingURL.standardizedFileURL)
    }

    func testDestinationChangeRejectsStalePublishedCompletion() async throws {
        let fixture = try AppModelPublicationFixture()
        _ = fixture.model.startRecordingFromControl()
        await fixture.waitForRecorderStart()
        fixture.model.startOrStop()
        await fixture.waitForRecorderStop()
        let completion = try fixture.makeDestinationCompletion(for: XCTUnwrap(fixture.publication.requests.single))

        fixture.model.setOutputFolder(fixture.otherDestination)
        fixture.publication.complete(with: completion)
        for _ in 0 ..< 20 { await Task.yield() }

        XCTAssertTrue(fixture.library.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completion.folderURL.path))
    }

    func testNeedsFolderAccessStillRecordsLocallyAndQueuesCapturedIdentity() async throws {
        let fixture = try AppModelPublicationFixture(destinationState: .needsFolderAccess)

        XCTAssertEqual(fixture.model.startRecordingFromControl(), .accepted)
        await fixture.waitForRecorderStart()
        fixture.model.startOrStop()
        await fixture.waitForRecorderStop()

        XCTAssertEqual(fixture.model.recordingDestinationState, .needsFolderAccess)
        XCTAssertEqual(fixture.publication.requests.single?.destinationIdentity, fixture.destinationStore.identity)
    }

    func testDestinationChangeDuringRecordingQueuesOldIdentityAndFence() async throws {
        let fixture = try AppModelPublicationFixture()
        XCTAssertEqual(fixture.model.startRecordingFromControl(), .accepted)
        await fixture.waitForRecorderStart()
        let capturedIdentity = try XCTUnwrap(fixture.model.recordingDestinationIdentity)
        fixture.model.setOutputFolder(fixture.otherDestination)
        fixture.model.startOrStop()
        await fixture.waitForRecorderStop()

        let request = try XCTUnwrap(fixture.publication.requests.single)
        XCTAssertEqual(request.destinationIdentity, capturedIdentity)
        XCTAssertEqual(request.workspaceFence, .initial)
    }

    func testSaveFailureLeavesCurrentDestinationAndFenceUnchanged() throws {
        let fixture = try AppModelPublicationFixture()
        let originalFolder = fixture.model.outputFolder
        let originalIdentity = fixture.model.recordingDestinationIdentity
        fixture.destinationStore.saveError = PublicationDestinationStoreError.saveFailed

        fixture.model.setOutputFolder(fixture.otherDestination)

        XCTAssertEqual(fixture.model.outputFolder, originalFolder)
        XCTAssertEqual(fixture.model.recordingDestinationIdentity, originalIdentity)
    }

    func testInitialOutputFolderIsSavedAsTheAuthoritativeDestination() throws {
        let fixture = try AppModelPublicationFixture(initialOutputFolder: true)

        XCTAssertEqual(fixture.model.outputFolder, fixture.otherDestination)
        XCTAssertEqual(fixture.destinationStore.url, fixture.otherDestination)
        XCTAssertEqual(fixture.model.recordingDestinationState, .ready)
    }

    func testStartupCompletionFinalizesWithoutAnInMemoryEnqueueContext() async throws {
        let fixture = try AppModelPublicationFixture()
        await fixture.settleInitialLibraryLoad()
        let request = fixture.makeRequest()
        let completion = try fixture.makeDestinationCompletion(for: request)

        fixture.publication.complete(with: completion)
        await fixture.waitForLibraryFinalization()

        XCTAssertEqual(fixture.library.sessions.single?.folderURL, completion.folderURL.standardizedFileURL)
    }

    func testStartupCompletionRejectsMismatchedIdentityOrFence() async throws {
        let fixture = try AppModelPublicationFixture()
        await fixture.settleInitialLibraryLoad()
        let request = fixture.makeRequest()
        let completion = try fixture.makeDestinationCompletion(for: request)
        let wrongIdentity = RecordingDestinationIdentity(id: UUID())

        fixture.publication.complete(with: .init(
            itemID: completion.itemID,
            destinationIdentity: wrongIdentity,
            folderURL: completion.folderURL,
            recordingURL: completion.recordingURL,
            workspaceFence: completion.workspaceFence,
            source: completion.source,
            health: completion.health,
            metadataWarning: completion.metadataWarning
        ))
        fixture.publication.complete(with: .init(
            itemID: completion.itemID,
            destinationIdentity: request.destinationIdentity,
            folderURL: completion.folderURL,
            recordingURL: completion.recordingURL,
            workspaceFence: .init(revision: completion.workspaceFence.revision + 1),
            source: completion.source,
            health: completion.health,
            metadataWarning: completion.metadataWarning
        ))
        for _ in 0 ..< 20 { await Task.yield() }

        XCTAssertTrue(fixture.library.sessions.isEmpty)
    }
}

@MainActor
private final class AppModelPublicationFixture {
    let root: URL
    let destination: URL
    let otherDestination: URL
    let pendingRoot: URL
    let engine: RecordingEngine
    let publication = PublicationCoordinatorSpy()
    let destinationStore: PublicationDestinationStore
    let library: LibraryFeatureModel
    let model: AppModel

    init(
        destinationState: RecordingDestinationState = .ready,
        initialOutputFolder: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        destination = root.appendingPathComponent("OneDrive", isDirectory: true)
        otherDestination = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDestination, withIntermediateDirectories: true)
        let paths = AppPaths(homeDirectory: root, applicationSupportRoot: root)
        pendingRoot = paths.pendingRecordingsDirectory
        destinationStore = PublicationDestinationStore(url: destination, state: destinationState)
        engine = RecordingEngine(captureSource: PublicationCaptureSource(), writerFactory: { PublicationWriter(outputURL: $0) }, mixerBlockFrames: 4)
        library = LibraryFeatureModel(
            sessionLoader: { RecordingSessionStore.load(from: $0) },
            sessionReloader: { RecordingSessionStore.session(for: $0.folderURL, recordingURL: $0.recordingURL) },
            searchDocumentLoader: { session in
                RecordingLibrarySearchDocument.load(
                    folderURL: session.folderURL,
                    displayName: session.displayName,
                    createdAt: session.createdAt,
                    metadata: session.metadata
                )
            },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        model = AppModel(
            appPaths: paths,
            recorder: engine,
            recordingDestinationStore: destinationStore,
            recordingPublicationCoordinator: publication,
            inputDevices: {
                [.init(id: 1, uid: "publication-mic", name: "Publication Mic", manufacturer: "Tests", channelCount: 1)]
            },
            defaultInputDeviceID: { 1 },
            performStartupWork: false,
            initialOutputFolder: initialOutputFolder ? otherDestination : nil,
            libraryFeature: library
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        let application = CaptureApplication(
            processID: 1,
            bundleIdentifier: "com.example.publication",
            name: "Publication Tests"
        )
        model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: application.bundleIdentifier
        )
        model.resolvedCaptureSelection = .application(application)
        model.refreshSessions()
    }

    deinit { try? FileManager.default.removeItem(at: root) }
    var localResultFolderName: String { engine.outputFolder!.lastPathComponent }

    func waitForRecorderStart() async { await waitUntil { self.engine.isRecording } }
    func waitForRecorderStop() async { await waitUntil { !self.engine.isRecording && !self.publication.requests.isEmpty } }
    func waitForLibraryFinalization() async { await waitUntil { !self.library.sessions.isEmpty } }

    func settleInitialLibraryLoad() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    func makeDestinationCompletion(for request: RecordingPublicationRequest) throws -> RecordingPublicationCompleted {
        let folder = destination.appendingPathComponent(request.sessionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("recording.m4a")
        try Data("published".utf8).write(to: recording)
        try RecordingSessionMetadataStore.save(.init(source: request.source), in: folder)
        return .init(itemID: request.id, destinationIdentity: request.destinationIdentity, folderURL: folder.standardizedFileURL, recordingURL: recording.standardizedFileURL, workspaceFence: request.workspaceFence, source: request.source, health: request.health, metadataWarning: request.metadataWarning)
    }

    func makeRequest() -> RecordingPublicationRequest {
        .init(
            id: UUID(),
            sessionDirectoryName: "meeting-startup-completion",
            destinationIdentity: destinationStore.identity,
            workspaceFence: .initial,
            source: .manual,
            health: .init(),
            metadataWarning: nil
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0 ..< 400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "status: \(model.statusMessage)")
    }
}

@MainActor
private final class PublicationCoordinatorSpy: RecordingPublicationCoordinating {
    var presentation = RecordingPublicationPresentation(stateText: "Up to date", pendingCount: 0, waitingCount: 0, needsAttentionCount: 0)
    var onPresentationChange: ((RecordingPublicationPresentation) -> Void)?
    var onCompleted: ((RecordingPublicationCompleted) -> Void)?
    private(set) var requests: [RecordingPublicationRequest] = []
    func enqueue(_ request: RecordingPublicationRequest) { requests.append(request) }
    func resume() {}
    func retryNow() {}
    func shutdown() {}
    func complete(with completion: RecordingPublicationCompleted) { onCompleted?(completion) }
}

private final class PublicationDestinationStore: RecordingDestinationStoring {
    let identity = RecordingDestinationIdentity(id: UUID())
    var url: URL
    var state: RecordingDestinationState
    var saveError: Error?
    init(url: URL, state: RecordingDestinationState = .ready) { self.url = url; self.state = state }
    var currentIdentity: RecordingDestinationIdentity? { identity }
    func restore(defaultURL _: URL) -> RecordingDestinationSelection { .init(identity: identity, url: url, state: state) }
    func save(_ url: URL) throws {
        if let saveError { throw saveError }
        self.url = url
        state = .ready
    }
    func access(identity _: RecordingDestinationIdentity) throws -> RecordingDestinationAccess { .init(url: url, close: {}) }
    func prune(keeping _: Set<RecordingDestinationIdentity>) {}
}

private enum PublicationDestinationStoreError: Error { case saveFailed }

private final class PublicationCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1, height: 1, pixelFormat: 0)
    func refreshContent() async throws -> [CaptureApplication] { [] }
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}
    func updateVideoTarget(_: TeamsWindowIdentity?) async throws -> CaptureFilterRevision { .init(sessionGeneration: 0, revision: 0) }
    func start(selection _: ResolvedCaptureSelection, microphoneUID _: String?, onAudio _: @escaping (AudioFrameBlock) -> Void, onVideo _: @escaping (ScreenVideoFrame) -> Void, onEvent _: @escaping (CaptureEvent) -> Void) async throws {}
    func stop() async {}
}

private final class PublicationWriter: MixedAudioWriting {
    let outputURL: URL
    init(outputURL: URL) { self.outputURL = outputURL }
    func write(_: MixedAudioBlock) throws {}
    func close() throws { try Data("local".utf8).write(to: outputURL) }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
