@preconcurrency import AVFoundation
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
            permissionRequestHandler: { _, _ in },
            volumeCapacityProvider: TestCapacityProvider(),
            storageMonitorTick: { try? await Task.sleep(for: .seconds(3_600)) },
            testRecordingDelay: { await delay.wait() },
            playbackCoordinator: coordinator
        )
        model.outputFolder = root
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
            permissionRequestHandler: { _, _ in },
            volumeCapacityProvider: TestCapacityProvider(),
            storageMonitorTick: { try? await Task.sleep(for: .seconds(3_600)) },
            testRecordingDelay: { await delay.wait() },
            playbackCoordinator: FakePlaybackCoordinator()
        )
        model?.outputFolder = root
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
        weak let weakModel = model
        model = nil

        let released = await eventually { weakModel == nil }
        XCTAssertTrue(released, "The injected test delay must not retain AppModel")
        await delay.fire()
        _ = await engine.stop()
    }

    private func makeModel(playbackCoordinator: FakePlaybackCoordinator) -> AppModel {
        AppModel(
            defaults: makeDefaults(),
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            playbackCoordinator: playbackCoordinator
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppModelPlaybackTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSession(extension fileExtension: String) -> RecordingSession {
        let folder = URL(fileURLWithPath: "/tmp/meeting-\(UUID().uuidString)", isDirectory: true)
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.\(fileExtension)"),
            createdAt: .now,
            duration: 12,
            fileSize: 0,
            metadata: .init()
        )
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
