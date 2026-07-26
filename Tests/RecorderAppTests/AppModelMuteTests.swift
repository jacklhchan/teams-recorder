import XCTest
@testable import RecorderApp

@MainActor
final class AppModelMuteTests: XCTestCase {
    func testRefreshSessionsLoadsRecordingLibraryOffMainThread() async {
        let loaderCalled = expectation(description: "recording library loader called")
        let model = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            recordingSessionLoader: { _ in
                XCTAssertFalse(Thread.isMainThread)
                loaderCalled.fulfill()
                return []
            }
        )

        model.refreshSessions()

        await fulfillment(of: [loaderCalled], timeout: 1)
    }

    func testRefreshSessionsCannotInterruptTranscriptionStartedWhileLoadIsInFlight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("manual-race", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: Date(),
            duration: 0,
            fileSize: 0,
            metadata: .init()
        )
        let loaderCalled = expectation(description: "recording library loader called")
        let releaseLoader = DispatchSemaphore(value: 0)
        defer { releaseLoader.signal() }
        let model = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            recordingSessionLoader: { _ in
                loaderCalled.fulfill()
                releaseLoader.wait()
                return [session]
            }
        )

        model.refreshSessions()
        await fulfillment(of: [loaderCalled], timeout: 1)

        let activeState = TranscriptionState(
            phase: .uploading,
            message: "Uploading audio",
            startedAt: Date()
        )
        model.transcribingSessionID = session.id
        model.transcriptionStatesBySessionID[session.id] = activeState
        try TranscriptionStateStore.save(activeState, in: session.folderURL)
        releaseLoader.signal()

        await waitUntil { model.sessions == [session] }

        XCTAssertEqual(model.transcriptionStatesBySessionID[session.id], activeState)
        XCTAssertEqual(
            try TranscriptionStateStore.load(in: session.folderURL)?.phase,
            .uploading
        )
    }

    func testRefreshSessionsProjectsStaleTranscriptionAsInterruptedWithoutRewritingFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("meeting-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: Date(),
            duration: 0,
            fileSize: 0,
            metadata: .init()
        )
        let staleState = TranscriptionState(
            phase: .transcribing,
            message: "Transcribing",
            startedAt: Date()
        )
        try TranscriptionStateStore.save(staleState, in: session.folderURL)
        let model = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            recordingSessionLoader: { _ in [session] }
        )

        model.refreshSessions()
        await waitUntil { model.sessions == [session] }

        XCTAssertEqual(model.transcriptionStatesBySessionID[session.id]?.phase, .interrupted)
        XCTAssertEqual(
            try TranscriptionStateStore.load(in: session.folderURL)?.phase,
            .transcribing
        )
    }

    func testChangingOutputFolderInvalidatesOldSessionsBeforeBackgroundLoadCompletes() async {
        let oldFolder = URL(fileURLWithPath: "/tmp/meeting-old", isDirectory: true)
        let oldSession = RecordingSession(
            id: oldFolder,
            folderURL: oldFolder,
            recordingURL: oldFolder.appendingPathComponent("recording.m4a"),
            createdAt: Date(),
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
        let loaderCalled = expectation(description: "new output folder loader called")
        let releaseLoader = DispatchSemaphore(value: 0)
        defer { releaseLoader.signal() }
        let model = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            recordingSessionLoader: { _ in
                loaderCalled.fulfill()
                releaseLoader.wait()
                return []
            }
        )
        model.sessions = [oldSession]
        model.transcriptionStatesBySessionID[oldSession.id] = .init(
            phase: .completed,
            message: "Done",
            startedAt: Date(),
            finishedAt: Date()
        )

        model.setOutputFolder(URL(fileURLWithPath: "/tmp/recordings-new", isDirectory: true))

        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.transcriptionStatesBySessionID.isEmpty)
        await fulfillment(of: [loaderCalled], timeout: 1)
    }

    func testOlderSessionRefreshCannotOverwriteNewerResult() async {
        let oldFolder = URL(fileURLWithPath: "/tmp/meeting-old", isDirectory: true)
        let newFolder = URL(fileURLWithPath: "/tmp/meeting-new", isDirectory: true)
        let oldSession = makeSession(folder: oldFolder)
        let newSession = makeSession(folder: newFolder)
        let firstLoaderCalled = expectation(description: "first loader called")
        let releaseFirstLoader = DispatchSemaphore(value: 0)
        let callCounter = LockedCallCounter()
        defer { releaseFirstLoader.signal() }
        let model = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            recordingSessionLoader: { _ in
                let currentCall = callCounter.next()
                if currentCall == 1 {
                    firstLoaderCalled.fulfill()
                    releaseFirstLoader.wait()
                    return [oldSession]
                }
                return [newSession]
            }
        )

        model.refreshSessions()
        await fulfillment(of: [firstLoaderCalled], timeout: 1)
        model.refreshSessions()
        releaseFirstLoader.signal()
        await waitUntil { model.sessions == [newSession] }

        XCTAssertEqual(model.sessions, [newSession])
    }

    func testRefreshDevicesAlsoRefreshesVirtualMicInstallationState() {
        var installationState = VirtualMicInstallationState.absent
        let recorder = RecordingEngine(
            virtualMicPublisher: AppModelMuteFakePublisher()
        )
        let model = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            virtualMicStateProvider: { installationState }
        )
        XCTAssertEqual(model.virtualMicInstallationState, .absent)

        installationState = .ready
        model.refreshDevices()

        XCTAssertEqual(model.virtualMicInstallationState, .ready)
    }

    func testInstallAppliesExistingSystemMuteToAudioPathsAndDisplay() {
        let publisher = AppModelMuteFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        var controller: AppModelMuteFakeController!
        let model = makeModel(recorder: recorder) { applyMute in
            controller = AppModelMuteFakeController(
                initiallyMuted: true,
                applyMuteToAudioPaths: applyMute
            )
            return controller
        }

        model.installInputMuteHandling()

        XCTAssertTrue(model.inputMuteControlAvailable)
        XCTAssertTrue(recorder.micMuted)
        XCTAssertEqual(publisher.muteCalls, [true])
        XCTAssertEqual(controller.installCount, 1)
    }

    func testButtonImmediatelyAppliesAudioGateAndDisplayWithoutWaitingForNotification() {
        let publisher = AppModelMuteFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        var controller: AppModelMuteFakeController!
        let model = makeModel(recorder: recorder) { applyMute in
            controller = AppModelMuteFakeController(
                initiallyMuted: false,
                applyMuteToAudioPaths: applyMute
            )
            return controller
        }
        model.installInputMuteHandling()

        model.toggleRecorderMicMute(source: "Button")

        XCTAssertEqual(controller.setMutedCalls, [])
        XCTAssertEqual(publisher.muteCalls, [false, true])
        XCTAssertTrue(recorder.micMuted)
        XCTAssertEqual(model.statusMessage, "Button: recorder mic muted")
    }

    func testAccessoryGestureUsesSameAudioGateAndDisplayPath() async {
        let publisher = AppModelMuteFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        var controller: AppModelMuteFakeController!
        let model = makeModel(recorder: recorder) { applyMute in
            controller = AppModelMuteFakeController(
                initiallyMuted: false,
                applyMuteToAudioPaths: applyMute
            )
            return controller
        }
        model.installInputMuteHandling()

        controller.simulateAccessoryGesture(muted: true)
        await settle()

        XCTAssertEqual(publisher.muteCalls, [false, true])
        XCTAssertTrue(recorder.micMuted)
        XCTAssertEqual(model.statusMessage, "AirPods / input: recorder mic muted")
    }

    func testNativeUnmuteCannotClearIndependentManualMute() async {
        let publisher = AppModelMuteFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        var controller: AppModelMuteFakeController!
        let model = makeModel(recorder: recorder) { applyMute in
            controller = AppModelMuteFakeController(
                initiallyMuted: false,
                applyMuteToAudioPaths: applyMute
            )
            return controller
        }
        model.installInputMuteHandling()
        model.toggleRecorderMicMute(source: "Button")

        controller.simulateAccessoryGesture(muted: false)
        await settle()

        XCTAssertTrue(model.localMicMuted)
        XCTAssertTrue(recorder.micMuted)
        XCTAssertEqual(publisher.muteCalls, [false, true])
    }

    func testClearingManualMuteNamesRemainingNativeInputMute() async {
        let publisher = AppModelMuteFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        var controller: AppModelMuteFakeController!
        let model = makeModel(recorder: recorder) { applyMute in
            controller = AppModelMuteFakeController(
                initiallyMuted: false,
                applyMuteToAudioPaths: applyMute
            )
            return controller
        }
        model.installInputMuteHandling()
        model.toggleRecorderMicMute(source: "Button")
        controller.simulateAccessoryGesture(muted: true)
        await settle()

        model.toggleRecorderMicMute(source: "Button")

        XCTAssertFalse(model.localMicMuted)
        XCTAssertTrue(model.nativeInputMicMuted)
        XCTAssertEqual(
            model.statusMessage,
            "Button: recorder mic remains muted by the input device"
        )
    }

    private func makeModel(
        recorder: RecordingEngine,
        inputMuteControllerFactory: @escaping (
            @escaping (Bool) -> Void
        ) -> InputMuteControlling
    ) -> AppModel {
        AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            inputMuteControllerFactory: inputMuteControllerFactory
        )
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private func makeSession(folder: URL) -> RecordingSession {
        RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: Date(),
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
    }
}

private final class LockedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class AppModelMuteFakeController: InputMuteControlling {
    private let applyMuteToAudioPaths: (Bool) -> Void
    private var onChange: ((Bool) -> Void)?

    private(set) var isMuted: Bool
    private(set) var installCount = 0
    private(set) var setMutedCalls: [Bool] = []

    init(
        initiallyMuted: Bool,
        applyMuteToAudioPaths: @escaping (Bool) -> Void
    ) {
        isMuted = initiallyMuted
        self.applyMuteToAudioPaths = applyMuteToAudioPaths
    }

    func install(onChange: @escaping (Bool) -> Void) throws {
        installCount += 1
        self.onChange = onChange
        applyMuteToAudioPaths(isMuted)
    }

    func setMuted(_ muted: Bool) throws {
        setMutedCalls.append(muted)
        applyMuteToAudioPaths(muted)
    }

    func uninstall() {
        onChange = nil
    }

    func simulateAccessoryGesture(muted: Bool) {
        applyMuteToAudioPaths(muted)
        deliverNotification(muted: muted)
    }

    func deliverNotification(muted: Bool) {
        isMuted = muted
        onChange?(muted)
    }
}

private final class AppModelMuteFakePublisher: VirtualMicPublishing {
    private(set) var state: VirtualMicPublisherState = .stopped
    private(set) var muteCalls: [Bool] = []

    func start() {
        state = .ready
    }

    func publishMicrophone(left: [Float], right: [Float]) {}

    func setMuted(_ muted: Bool) {
        muteCalls.append(muted)
    }

    func stop() {
        state = .stopped
    }
}
