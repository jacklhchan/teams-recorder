import XCTest
@testable import RecorderApp
@testable import RecorderControl

@MainActor
final class AppModelControlAdapterTests: XCTestCase {
    func testSetAutoOnIsIdempotent() async {
        let model = makeModel()
        let adapter = AppModelControlAdapter(model: model)

        let first = await adapter.handle(.init(
            requestID: "auto-1", command: .setAuto, argument: "on"
        ))
        let second = await adapter.handle(.init(
            requestID: "auto-2", command: .setAuto, argument: "on"
        ))

        XCTAssertTrue(first.ok)
        XCTAssertTrue(second.ok)
        XCTAssertTrue(model.teamsAutoMeetingEnabled)
    }

    func testStopWhenNothingIsActiveIsSuccessfulNoOp() async {
        let model = makeModel()
        let response = await AppModelControlAdapter(model: model).handle(.init(
            requestID: "stop-1", command: .stop
        ))

        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
    }

    func testStopDuringActiveAutomaticRecordingSuppressesCurrentMeeting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppModelControlAdapterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticker = ControlAdapterManualTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            startCountdownSeconds: 1,
            tick: { await ticker.waitForTick() }
        )
        let source = ControlAdapterCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in ControlAdapterWriter() }
        )
        let microphone = AudioDevice(
            id: 2,
            uid: "control-auto-stop-mic",
            name: "Control Auto Stop Microphone",
            manufacturer: "Tests",
            channelCount: 1
        )
        let model = makeModel(
            microphone: microphone,
            outputFolder: folder,
            recorder: engine,
            teamsAutoMeetingCoordinator: coordinator
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        let adapter = AppModelControlAdapter(model: model)

        _ = await adapter.handle(.init(
            requestID: "auto-on", command: .setAuto, argument: "on"
        ))
        coordinator.handleMeetingState(isInMeeting: true)
        await ticker.fireAndWaitForAcknowledgement()
        await waitUntil {
            engine.isRecording
                && model.recordingOwnership == .teamsAutomatic
                && !model.isCaptureLifecycleWorking
        }

        let response = await adapter.handle(.init(requestID: "auto-stop", command: .stop))
        await waitUntil { !engine.isRecording && !model.isCaptureLifecycleWorking }

        XCTAssertTrue(response.ok)
        XCTAssertEqual(model.teamsAutoMeetingState, .suppressedUntilMeetingEnd)
    }

    func testStartWhileAlreadyRecordingDoesNotStartCaptureTwice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppModelControlAdapterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = ControlAdapterCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in ControlAdapterWriter() }
        )
        let microphone = AudioDevice(
            id: 1,
            uid: "control-start-mic",
            name: "Control Start Microphone",
            manufacturer: "Tests",
            channelCount: 1
        )
        let model = makeModel(
            microphone: microphone,
            outputFolder: folder,
            recorder: engine
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        let adapter = AppModelControlAdapter(model: model)

        let first = await adapter.handle(.init(requestID: "start-1", command: .start))
        XCTAssertTrue(first.ok)
        await waitUntil { engine.isRecording }
        let second = await adapter.handle(.init(requestID: "start-2", command: .start))
        XCTAssertTrue(second.ok)

        XCTAssertEqual(source.startCount, 1)
        _ = await adapter.handle(.init(requestID: "stop-1", command: .stop))
        await waitUntil { !engine.isRecording && !model.isCaptureLifecycleWorking }
    }

    func testRepeatedMicCommandsKeepRequestedState() async {
        let model = makeModel()
        let adapter = AppModelControlAdapter(model: model)

        _ = await adapter.handle(.init(
            requestID: "mute-1", command: .setMic, argument: "mute"
        ))
        let mutedAgain = await adapter.handle(.init(
            requestID: "mute-2", command: .setMic, argument: "mute"
        ))
        _ = await adapter.handle(.init(
            requestID: "unmute-1", command: .setMic, argument: "unmute"
        ))
        let unmutedAgain = await adapter.handle(.init(
            requestID: "unmute-2", command: .setMic, argument: "unmute"
        ))

        XCTAssertTrue(mutedAgain.ok)
        XCTAssertTrue(unmutedAgain.ok)
        XCTAssertFalse(model.localMicMuted)
    }

    func testUnsupportedProtocolReturnsStableErrorWithoutMutation() async {
        let model = makeModel()
        let response = await AppModelControlAdapter(model: model).handle(.init(
            protocolVersion: 99,
            requestID: "old-client",
            command: .setAuto,
            argument: "on"
        ))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unsupported_protocol")
        XCTAssertFalse(model.teamsAutoMeetingEnabled)
    }

    func testStatusStartAndStopRejectNonNilArguments() async {
        let model = makeModel()
        let adapter = AppModelControlAdapter(model: model)

        for command in [RecorderControlCommand.status, .start, .stop] {
            let response = await adapter.handle(.init(
                requestID: "bad-\(command)", command: command, argument: "unexpected"
            ))

            XCTAssertFalse(response.ok, "\(command) should reject an argument")
            XCTAssertEqual(response.error?.code, "invalid_argument")
        }
    }

    func testStatusProjectsControlSafeAppState() async throws {
        let microphone = AudioDevice(
            id: 7,
            uid: "control-mic",
            name: "Control Microphone",
            manufacturer: "Tests",
            channelCount: 1
        )
        let output = URL(fileURLWithPath: "/tmp/recorder-control-output", isDirectory: true)
        let model = makeModel(microphone: microphone, outputFolder: output)
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        model.setRecorderMicMuted(true)

        let response = await AppModelControlAdapter(model: model).handle(.init(
            requestID: "status-1", command: .status
        ))
        let status = try XCTUnwrap(response.status)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(status.selectedMicrophoneName, "Control Microphone")
        XCTAssertEqual(status.selectedMicrophoneUID, "control-mic")
        XCTAssertEqual(status.systemAudioPermission, "granted")
        XCTAssertEqual(status.microphonePermission, "granted")
        XCTAssertFalse(status.autoModeEnabled)
        XCTAssertNil(status.recordingOwnership)
        XCTAssertNil(status.activeRecordingFolder)
        XCTAssertTrue(status.localMicMuted)
        XCTAssertFalse(status.nativeInputMicMuted)
        XCTAssertTrue(status.effectiveMicMuted)
        XCTAssertEqual(status.teamsMicState, "unknown")
        XCTAssertEqual(status.outputFolder, output.path)
    }

    private func makeModel(
        microphone: AudioDevice? = nil,
        outputFolder: URL = URL(fileURLWithPath: "/tmp", isDirectory: true),
        recorder: RecordingEngine? = nil,
        teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator? = nil
    ) -> AppModel {
        let suiteName = "AppModelControlAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            defaults: defaults,
            recorder: recorder,
            inputDevices: { microphone.map { [$0] } ?? [] },
            defaultInputDeviceID: { microphone?.id },
            performStartupWork: false,
            initialOutputFolder: outputFolder,
            volumeCapacityProvider: ControlAdapterStorageProvider(),
            teamsAutoMeetingCoordinator: teamsAutoMeetingCoordinator
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private final class ControlAdapterCaptureSource: CaptureSourceProtocol, @unchecked Sendable {
    let screenVideoFormat = ScreenVideoFormat(width: 1, height: 1, pixelFormat: 0)
    private(set) var startCount = 0

    func refreshContent() async throws -> [CaptureApplication] { [] }
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}
    func updateVideoTarget(_: TeamsWindowIdentity?) async throws -> CaptureFilterRevision {
        .init(sessionGeneration: 0, revision: 0)
    }
    func start(
        selection _: ResolvedCaptureSelection,
        microphoneUID _: String?,
        onAudio _: @escaping (AudioFrameBlock) -> Void,
        onVideo _: @escaping (ScreenVideoFrame) -> Void,
        onEvent _: @escaping (CaptureEvent) -> Void
    ) async throws {
        startCount += 1
    }
    func stop() async {}
}

private final class ControlAdapterWriter: MixedAudioWriting {
    func write(_: MixedAudioBlock) throws {}
    func close() throws {}
}

private struct ControlAdapterStorageProvider: VolumeCapacityProviding {
    func availableBytes(onVolumeContaining _: URL) throws -> Int64 {
        Int64(10) * 1_024 * 1_024 * 1_024
    }
}

private actor ControlAdapterManualTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitForTick() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func fireAndWaitForAcknowledgement() async {
        while continuations.isEmpty {
            await Task.yield()
        }
        continuations.removeFirst().resume()
    }
}
