@preconcurrency import AVFoundation
import AppKit
import AVKit
import Combine
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelPlaybackTests: XCTestCase {
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for suiteName in defaultsSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    func testLibraryPlaybackLoadsThenPlaysAndProjectsSnapshot() async {
        let coordinator = FakePlaybackCoordinator()
        let model = makeModel(playbackCoordinator: coordinator)
        let session = makeSession(extension: "m4a")

        model.play(session: session)
        await Task.yield()

        XCTAssertEqual(coordinator.loadedSessionIDs, [session.id])
        XCTAssertEqual(coordinator.playCount, 1)
        coordinator.emit(.init(sessionID: session.id, progress: 3, duration: 12, isPlaying: true))
        XCTAssertEqual(model.playingSessionID, session.id)
        XCTAssertEqual(model.playbackProgress, 3)
        XCTAssertEqual(model.playbackDuration, 12)
        XCTAssertTrue(model.isPlaybackActive)
    }

    func testPeriodicSnapshotsPublishPlaybackPresentationWithoutRepublishingAppModel() async {
        let coordinator = FakePlaybackCoordinator()
        let model = makeModel(playbackCoordinator: coordinator)
        let session = makeSession(extension: "mp4")

        model.play(session: session)
        await Task.yield()

        var appModelPublicationCount = 0
        let observation = model.objectWillChange.sink {
            appModelPublicationCount += 1
        }
        coordinator.emit(.init(
            sessionID: session.id,
            progress: 3,
            duration: 12,
            isPlaying: true
        ))

        XCTAssertEqual(model.playbackProgress, 3)
        XCTAssertEqual(model.playbackDuration, 12)
        XCTAssertTrue(model.isPlaybackActive)
        XCTAssertEqual(
            appModelPublicationCount,
            0,
            "Periodic playback progress must update only the dedicated playback window"
        )
        withExtendedLifetime(observation) {}
    }

    func testAppModelForwardsTheInjectedPlaybackFeatureWithoutFallback() async {
        let coordinator = FakePlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let model = AppModel(
            defaults: makeDefaults(),
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            playbackFeature: feature
        )
        let session = makeSession(extension: "m4a")

        XCTAssertTrue(model.playbackFeature === feature)
        model.play(session: session)
        await Task.yield()

        XCTAssertEqual(coordinator.loadedSessionIDs, [session.id])
        XCTAssertEqual(model.playingSessionID, session.id)
    }

    func testVideoPlaybackIsNotEmbeddedInMainContentHierarchy() async {
        let coordinator = FakePlaybackCoordinator()
        let model = makeModel(playbackCoordinator: coordinator)
        let session = makeSession(
            extension: "mp4",
            screenIntervals: [
                RecordedScreenInterval(startSeconds: 0, endSeconds: 10)
            ]
        )
        model.sessions = [session]
        model.play(session: session)
        await Task.yield()

        let hostingView = NSHostingView(rootView: ContentView(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        if let scrollView = firstScrollView(in: hostingView),
           let documentView = scrollView.documentView {
            let maximumY = max(
                0,
                documentView.bounds.height -
                    scrollView.contentView.bounds.height
            )
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try? await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
        }

        XCTAssertFalse(
            containsAVPlayerView(in: hostingView),
            "Video playback must live in a dedicated window, outside the main ScrollView"
        )
        window.contentView = nil
    }

    func testContentViewRetainsOnePresenterPairAndVideoPlaybackStaysOutsideWorkspace() async throws {
        let coordinator = FakePlaybackCoordinator()
        let model = makeModel(playbackCoordinator: coordinator)
        let session = makeSession(
            extension: "mp4",
            screenIntervals: [.init(startSeconds: 0, endSeconds: 12)]
        )
        model.sessions = [session]
        let countdownFactory = CountdownPresenterFactorySpy()
        let playbackFactory = PlaybackPresenterFactorySpy()
        let navigationDriver = ContentViewNavigationDriver()
        let hostingView = NSHostingView(
            rootView: ContentView(
                model: model,
                autoMeetingPanelFactory: countdownFactory,
                playbackWindowPresenterFactory: playbackFactory,
                navigationOverride: Binding(
                    get: { navigationDriver.navigation },
                    set: { navigationDriver.navigation = $0 }
                )
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        await Task.yield()
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        navigationDriver.navigation.select(
            .recordings,
            hasUnsavedChanges: false
        )
        model.objectWillChange.send()
        try? await Task.sleep(for: .milliseconds(10))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            containsAccessibilityIdentifier(
                "recorder.destination.recordings",
                in: hostingView
            )
        )
        navigationDriver.navigation.select(.record, hasUnsavedChanges: false)
        model.objectWillChange.send()
        try? await Task.sleep(for: .milliseconds(10))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            containsAccessibilityIdentifier(
                "recorder.destination.record",
                in: hostingView
            )
        )
        XCTAssertEqual(countdownFactory.makeCount, 1)
        XCTAssertEqual(playbackFactory.makeCount, 1)

        model.play(session: session)
        await waitUntil { playbackFactory.presenter.presentCount == 1 }
        XCTAssertFalse(
            containsAVPlayerView(in: hostingView),
            "The exercised video presentation must remain outside ContentView's workspace hierarchy"
        )
        XCTAssertEqual(countdownFactory.makeCount, 1)
        XCTAssertEqual(playbackFactory.makeCount, 1)
    }

    func testContentViewPresenterLifecycleDismissesForStateStopTerminationAndDisappearance() async throws {
        let playbackCoordinator = FakePlaybackCoordinator()
        let autoMeetingCoordinator = TeamsAutoMeetingCoordinator()
        let model = makeModel(
            playbackCoordinator: playbackCoordinator,
            teamsAutoMeetingCoordinator: autoMeetingCoordinator
        )
        let session = makeSession(
            extension: "mp4",
            screenIntervals: [.init(startSeconds: 0, endSeconds: 12)]
        )
        let countdownFactory = CountdownPresenterFactorySpy()
        let playbackFactory = PlaybackPresenterFactorySpy()
        let hostingView = NSHostingView(
            rootView: ContentView(
                model: model,
                autoMeetingPanelFactory: countdownFactory,
                playbackWindowPresenterFactory: playbackFactory
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        await Task.yield()
        defer { window.orderOut(nil) }

        // The pre-existing non-countdown state first exercises the initial
        // dismissal path. A countdown then must present and its transition
        // away from countdown must dismiss through ContentView's handler.
        await waitUntil {
            countdownFactory.presenter.dismissCount == 1 &&
                playbackFactory.presenter.dismissCount == 1
        }
        autoMeetingCoordinator.setEnabled(true)
        autoMeetingCoordinator.handleMeetingState(isInMeeting: true)
        await waitUntil { countdownFactory.presenter.presentCount == 1 }
        autoMeetingCoordinator.setEnabled(false)
        await waitUntil { countdownFactory.presenter.dismissCount == 2 }

        // Playback presentation is driven by the existing playing-session
        // handler, and stopPlayback must drive the corresponding dismissal.
        model.play(session: session)
        await waitUntil { playbackFactory.presenter.presentCount == 1 }
        model.stopPlayback()
        await waitUntil { playbackFactory.presenter.dismissCount == 2 }

        // Re-present both surfaces, then prove the termination handler
        // dismisses each one without moving presenter ownership.
        autoMeetingCoordinator.setEnabled(true)
        autoMeetingCoordinator.handleMeetingState(isInMeeting: true)
        model.play(session: session)
        await waitUntil {
            countdownFactory.presenter.presentCount == 2 &&
                playbackFactory.presenter.presentCount == 2
        }
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        await waitUntil {
            countdownFactory.presenter.dismissCount == 3 &&
                playbackFactory.presenter.dismissCount == 3
        }

        // Host removal is the other teardown route: onDisappear must dismiss
        // both presenters after they have been exercised again.
        autoMeetingCoordinator.setEnabled(false)
        await waitUntil { countdownFactory.presenter.dismissCount == 4 }
        autoMeetingCoordinator.setEnabled(true)
        autoMeetingCoordinator.handleMeetingState(isInMeeting: true)
        model.stopPlayback()
        await waitUntil { playbackFactory.presenter.dismissCount == 4 }
        await waitUntil { countdownFactory.presenter.presentCount == 3 }
        model.play(session: session)
        await waitUntil { playbackFactory.presenter.presentCount == 3 }
        window.contentView = nil
        await waitUntil {
            countdownFactory.presenter.dismissCount == 5 &&
                playbackFactory.presenter.dismissCount == 5
        }
    }

    func testStopSeekPauseAndStaleSnapshotDoNotPolluteReplacementPlayback() async {
        let coordinator = FakePlaybackCoordinator()
        let model = makeModel(playbackCoordinator: coordinator)
        let first = makeSession(extension: "m4a")
        let second = makeSession(extension: "mp4")

        model.play(session: first)
        await Task.yield()
        coordinator.emit(.init(sessionID: first.id, progress: 1, duration: 10, isPlaying: true))
        model.playbackToggle()
        model.seekPlayback(to: 9)
        model.play(session: second)
        await Task.yield()
        coordinator.emit(.init(sessionID: first.id, progress: 8, duration: 10, isPlaying: true))

        XCTAssertEqual(coordinator.pauseCount, 1)
        XCTAssertEqual(coordinator.seekRequests, [9])
        XCTAssertEqual(coordinator.loadedSessionIDs, [first.id, second.id])
        XCTAssertNotEqual(model.playingSessionID, first.id)

        model.stopPlayback()
        coordinator.emit(.init(sessionID: second.id, progress: 1, duration: 10, isPlaying: true))
        XCTAssertNil(model.playingSessionID)
        XCTAssertFalse(model.isPlaybackActive)
        XCTAssertGreaterThanOrEqual(coordinator.stopCount, 1)
    }

    func testLoadFailureClearsPlaybackStateAndReportsFailure() async {
        let coordinator = FakePlaybackCoordinator()
        coordinator.loadError = PlaybackTestError.unavailable
        let model = makeModel(playbackCoordinator: coordinator)
        let session = makeSession(extension: "m4a")

        model.play(session: session)
        await Task.yield()

        XCTAssertNil(model.playingSessionID)
        XCTAssertFalse(model.isPlaybackActive)
        XCTAssertTrue(model.statusMessage.contains("Playback failed"))
    }

    func testTestRecordingAutoplayUsesCoordinatorWithSavedResultSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = TestCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in TestWriter() },
            mixerBlockFrames: 4
        )
        let coordinator = FakePlaybackCoordinator()
        let delay = TestRecordingDelay()
        let microphone = AudioDevice(id: 1, uid: "test-mic", name: "Test Mic", manufacturer: "Tests", channelCount: 1)
        let model = AppModel(
            defaults: makeDefaults(),
            recorder: engine,
            inputDevices: { [microphone] },
            defaultInputDeviceID: { microphone.id },
            performStartupWork: false,
            initialOutputFolder: root,
            permissionRequestHandler: { _, _ in },
            volumeCapacityProvider: TestCapacityProvider(),
            storageMonitorTick: { try? await Task.sleep(for: .seconds(3_600)) },
            testRecordingDelay: { await delay.wait() },
            playbackCoordinator: coordinator
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        XCTAssertEqual(model.captureReadiness, .ready)

        model.runTestRecording()
        await waitUntil { source.startCount == 1 }
        guard source.startCount == 1 else {
            XCTFail("Test recording did not start: \(model.statusMessage)")
            return
        }
        await delay.fire()
        await waitUntil { coordinator.loadedSessionIDs.count == 1 }
        guard let savedSessionID = coordinator.loadedSessionIDs.first else {
            XCTFail("Test recording did not autoplay: \(model.statusMessage)")
            return
        }

        XCTAssertEqual(coordinator.playCount, 1)
        XCTAssertTrue(savedSessionID.lastPathComponent.hasPrefix("test-"))
        XCTAssertTrue(model.statusMessage.contains("Test saved and playing"))
        XCTAssertTrue(model.lastRecordingSavedAsM4A)
    }

    func testTestRecordingDelayDoesNotRetainReleasedAppModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = TestCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in TestWriter() },
            mixerBlockFrames: 4
        )
        let delay = TestRecordingDelay()
        let microphone = AudioDevice(
            id: 1,
            uid: "test-mic",
            name: "Test Mic",
            manufacturer: "Tests",
            channelCount: 1
        )
        var model: AppModel? = AppModel(
            defaults: makeDefaults(),
            recorder: engine,
            inputDevices: { [microphone] },
            defaultInputDeviceID: { microphone.id },
            performStartupWork: false,
            initialOutputFolder: root,
            permissionRequestHandler: { _, _ in },
            volumeCapacityProvider: TestCapacityProvider(),
            storageMonitorTick: { try? await Task.sleep(for: .seconds(3_600)) },
            testRecordingDelay: { await delay.wait() },
            playbackCoordinator: FakePlaybackCoordinator()
        )
        model?.systemAudioPermission = .granted
        model?.microphonePermission = .granted

        model?.runTestRecording()
        await waitUntil {
            source.startCount == 1 && model?.isCaptureLifecycleWorking == false
        }
        var delayIsWaiting = false
        for _ in 0..<300 {
            if await delay.isWaiting {
                delayIsWaiting = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(delayIsWaiting, "The test-recording delay did not start")
        weak var weakModel = model
        model = nil

        let released = await eventually { weakModel == nil }
        XCTAssertTrue(released, "The injected test delay must not retain AppModel")
        await delay.fire()
        _ = await engine.stop()
    }

    private func makeModel(
        playbackCoordinator: FakePlaybackCoordinator,
        teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator? = nil
    ) -> AppModel {
        AppModel(
            defaults: makeDefaults(),
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            playbackCoordinator: playbackCoordinator,
            teamsAutoMeetingCoordinator: teamsAutoMeetingCoordinator
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppModelPlaybackTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSession(
        extension fileExtension: String,
        screenIntervals: [RecordedScreenInterval] = []
    ) -> RecordingSession {
        let folder = URL(fileURLWithPath: "/tmp/meeting-\(UUID().uuidString)", isDirectory: true)
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.\(fileExtension)"),
            createdAt: .now,
            duration: 12,
            fileSize: 0,
            metadata: .init(screenIntervals: screenIntervals)
        )
    }

    private func containsAVPlayerView(in view: NSView) -> Bool {
        if view is AVPlayerView { return true }
        return view.subviews.contains(where: containsAVPlayerView(in:))
    }

    private func containsAccessibilityIdentifier(_ identifier: String, in root: NSView) -> Bool {
        if root.accessibilityIdentifier() == identifier { return true }
        for subview in root.subviews {
            if containsAccessibilityIdentifier(identifier, in: subview) { return true }
        }
        return false
    }



    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        return view.subviews.lazy.compactMap(firstScrollView(in:)).first
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class ContentViewNavigationDriver: ObservableObject {
    @Published var navigation = RecorderNavigationState(selection: .record)
}

@MainActor
private final class FakePlaybackCoordinator: PlaybackCoordinating {
    let player = AVPlayer()
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    private(set) var loadedSessionIDs: [RecordingSession.ID] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var seekRequests: [TimeInterval] = []
    var loadError: Error?

    func load(_ session: RecordingSession) async throws {
        if let loadError { throw loadError }
        loadedSessionIDs.append(session.id)
    }

    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to seconds: TimeInterval) async { seekRequests.append(seconds) }
    func stop() { stopCount += 1 }
    func emit(_ snapshot: PlaybackSnapshot) { onSnapshot?(snapshot) }
}

@MainActor
private final class CountdownPresenterFactorySpy: TeamsAutoMeetingCountdownPresenterFactory {
    let presenter = CountdownPresenterSpy()
    private(set) var makeCount = 0

    func makePresenter() -> any TeamsAutoMeetingCountdownPresenting {
        makeCount += 1
        return presenter
    }
}

@MainActor
private final class CountdownPresenterSpy: TeamsAutoMeetingCountdownPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func present(seconds _: Int, cancel _: @escaping @MainActor () -> Void) {
        presentCount += 1
    }

    func dismiss() {
        dismissCount += 1
    }
}

@MainActor
private final class PlaybackPresenterFactorySpy: PlaybackWindowPresenterFactory {
    let presenter = PlaybackPresenterSpy()
    private(set) var makeCount = 0

    func makePresenter() -> any PlaybackWindowPresenting {
        makeCount += 1
        return presenter
    }
}

@MainActor
private final class PlaybackPresenterSpy: PlaybackWindowPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func present(
        presentation _: PlaybackPresentationModel,
        togglePlayback _: @escaping @MainActor () -> Void,
        stopPlayback _: @escaping @MainActor () -> Void,
        seekPlayback _: @escaping @MainActor (TimeInterval) -> Void
    ) {
        presentCount += 1
    }

    func dismiss() {
        dismissCount += 1
    }
}

private enum PlaybackTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "unavailable" }
}

private final class TestCapacityProvider: VolumeCapacityProviding, @unchecked Sendable {
    func availableBytes(onVolumeContaining _: URL) throws -> Int64 { 20 * 1_024 * 1_024 * 1_024 }
}

private actor TestRecordingDelay {
    private var continuation: CheckedContinuation<Void, Never>?
    private var pendingFire = false

    func wait() async {
        if pendingFire {
            pendingFire = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fire() {
        if let continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            pendingFire = true
        }
    }

    var isWaiting: Bool {
        continuation != nil
    }
}

private final class TestCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: 0)
    private(set) var startCount = 0

    func refreshContent() async throws -> [CaptureApplication] { [] }
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}
    func updateVideoTarget(_: TeamsWindowIdentity?) async throws -> CaptureFilterRevision { .init(sessionGeneration: 0, revision: 0) }
    func start(selection _: ResolvedCaptureSelection, microphoneUID _: String?, onAudio _: @escaping (AudioFrameBlock) -> Void, onVideo _: @escaping (ScreenVideoFrame) -> Void, onEvent _: @escaping (CaptureEvent) -> Void) async throws {
        startCount += 1
    }
    func stop() async {}
}

private final class TestWriter: MixedAudioWriting {
    func write(_: MixedAudioBlock) throws {}
    func close() throws {}
}
