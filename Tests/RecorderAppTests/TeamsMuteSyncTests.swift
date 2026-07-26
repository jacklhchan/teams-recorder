import XCTest
@testable import RecorderApp

final class TeamsThirdPartyAPIProtocolTests: XCTestCase {
    func testEndpointUsesCurrentTeamsProtocolAndEncodesIdentity() throws {
        let endpoint = try XCTUnwrap(
            TeamsThirdPartyAPI.endpoint(
                token: nil,
                identity: TeamsThirdPartyAPIIdentity(
                    manufacturer: "Local Recorder",
                    device: "Mac & AirPods",
                    app: "Meeting Recorder",
                    appVersion: "1.2.3"
                )
            )
        )
        let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        XCTAssertEqual(components.scheme, "ws")
        XCTAssertEqual(components.host, "127.0.0.1")
        XCTAssertEqual(components.port, 8124)
        XCTAssertEqual(query["protocol-version"], "2.0.0.0")
        XCTAssertEqual(query["manufacturer"], "Local Recorder")
        XCTAssertEqual(query["device"], "Mac & AirPods")
        XCTAssertEqual(query["app"], "Meeting Recorder")
        XCTAssertEqual(query["app-version"], "1.2.3")
        XCTAssertNil(query["token"])
    }

    func testEndpointIncludesExistingPairingToken() throws {
        let endpoint = try XCTUnwrap(
            TeamsThirdPartyAPI.endpoint(
                token: "paired-token",
                identity: .recorder(appVersion: "1.0")
            )
        )
        let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        let token = components.queryItems?.first { $0.name == "token" }?.value

        XCTAssertEqual(token, "paired-token")
    }

    func testPairCommandUsesAbsoluteRequestIdentifierAndEmptyParameters() throws {
        let data = TeamsThirdPartyAPI.command(action: .pair, requestID: 7)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["action"] as? String, "pair")
        XCTAssertEqual(object["requestId"] as? Int, 7)
        XCTAssertNotNil(object["parameters"] as? [String: Any])
    }

    func testDecodesAbsoluteMeetingMuteState() throws {
        let event = try TeamsThirdPartyAPI.decode(
            """
            {
              "meetingUpdate": {
                "meetingState": {
                  "isMuted": true,
                  "isInMeeting": true
                },
                "meetingPermissions": {
                  "canToggleMute": true,
                  "canPair": false
                }
              }
            }
            """
        )

        XCTAssertEqual(
            event,
            .meetingUpdate(
                TeamsThirdPartyAPIMeetingUpdate(
                    state: TeamsMeetingState(
                        isInMeeting: true,
                        isMuted: true,
                        canToggleMute: true,
                        canPair: false
                    ),
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
    }

    func testPermissionsOnlyUpdatePreservesMissingMeetingStateAndPairingSignal() throws {
        let event = try TeamsThirdPartyAPI.decode(
            """
            {
              "meetingUpdate": {
                "meetingPermissions": {
                  "canPair": true
                }
              }
            }
            """
        )

        XCTAssertEqual(
            event,
            .meetingUpdate(
                TeamsThirdPartyAPIMeetingUpdate(
                    state: nil,
                    canToggleMute: false,
                    canPair: true
                )
            )
        )
    }

    func testPartialMeetingStateDoesNotInventAnUnmutedState() throws {
        let event = try TeamsThirdPartyAPI.decode(
            """
            {
              "meetingUpdate": {
                "meetingState": {
                  "isInMeeting": true
                },
                "meetingPermissions": {
                  "canToggleMute": true,
                  "canPair": false
                }
              }
            }
            """
        )

        XCTAssertEqual(
            event,
            .meetingUpdate(
                TeamsThirdPartyAPIMeetingUpdate(
                    state: nil,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
    }

    func testDecodesTokenRefreshWithoutLoggingOrExposingItAsStatusText() throws {
        let event = try TeamsThirdPartyAPI.decode(
            #"{"tokenRefresh":"new-local-token"}"#
        )

        XCTAssertEqual(event, .tokenRefresh("new-local-token"))
    }

    func testDecodesServerError() throws {
        let event = try TeamsThirdPartyAPI.decode(
            #"{"errorMsg":"API is disabled."}"#
        )

        XCTAssertEqual(
            event,
            .error(requestID: nil, message: "API is disabled.")
        )
    }
}

final class MicrophoneMuteCoordinatorTests: XCTestCase {
    func testRepeatedTeamsMuteStateIsIdempotent() {
        var coordinator = MicrophoneMuteCoordinator()
        let active = TeamsMeetingState(
            isInMeeting: true,
            isMuted: false,
            canToggleMute: true,
            canPair: false
        )
        let muted = TeamsMeetingState(
            isInMeeting: true,
            isMuted: true,
            canToggleMute: true,
            canPair: false
        )

        XCTAssertNil(coordinator.applyTeamsState(active))
        XCTAssertEqual(coordinator.applyTeamsState(muted), true)
        XCTAssertNil(coordinator.applyTeamsState(muted))
        XCTAssertNil(coordinator.applyTeamsState(muted))
        XCTAssertTrue(coordinator.effectiveMuted)
    }

    func testTeamsUnmuteRestoresRecorderWhenThereIsNoLocalMute() {
        var coordinator = MicrophoneMuteCoordinator()
        let muted = TeamsMeetingState(
            isInMeeting: true,
            isMuted: true,
            canToggleMute: true,
            canPair: false
        )
        let active = TeamsMeetingState(
            isInMeeting: true,
            isMuted: false,
            canToggleMute: true,
            canPair: false
        )

        XCTAssertEqual(coordinator.applyTeamsState(muted), true)
        XCTAssertEqual(coordinator.applyTeamsState(active), false)
        XCTAssertFalse(coordinator.effectiveMuted)
    }

    func testLocalMuteRemainsEffectiveWhenTeamsUnmutes() {
        var coordinator = MicrophoneMuteCoordinator()
        XCTAssertEqual(coordinator.setLocalMuted(true), true)

        XCTAssertNil(
            coordinator.applyTeamsState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        XCTAssertNil(
            coordinator.applyTeamsState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: false,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        XCTAssertTrue(coordinator.effectiveMuted)
    }

    func testLeavingMeetingClearsOnlyTeamsMute() {
        var coordinator = MicrophoneMuteCoordinator()
        _ = coordinator.applyTeamsState(
            TeamsMeetingState(
                isInMeeting: true,
                isMuted: true,
                canToggleMute: true,
                canPair: false
            )
        )

        XCTAssertEqual(
            coordinator.applyTeamsState(
                TeamsMeetingState(
                    isInMeeting: false,
                    isMuted: false,
                    canToggleMute: false,
                    canPair: false
                )
            ),
            false
        )
        XCTAssertFalse(coordinator.effectiveMuted)
    }

    func testGateSinkCanReenterStateWithoutDeadlock() {
        let finished = expectation(description: "mute transition finished")
        var gate: MicrophoneMuteGate!
        gate = MicrophoneMuteGate { muted in
            if muted {
                gate.setNativeInputMuted(true)
            }
            finished.fulfill()
        }

        DispatchQueue.global().async {
            gate.setLocalMuted(true)
        }

        wait(for: [finished], timeout: 1)
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertTrue(gate.snapshot.nativeInputMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)
    }

    func testGateDrainsOppositeReentrantTransitionAfterOuterSinkReturns() {
        var audioMuted = false
        var sinkCalls: [Bool] = []
        var didReenter = false
        var gate: MicrophoneMuteGate!
        gate = MicrophoneMuteGate { muted in
            sinkCalls.append(muted)
            if muted, !didReenter {
                didReenter = true
                gate.setLocalMuted(false)
            }
            audioMuted = muted
        }

        let snapshot = gate.setLocalMuted(true)

        XCTAssertEqual(sinkCalls, [true, false])
        XCTAssertFalse(audioMuted)
        XCTAssertFalse(snapshot.effectiveMuted)
        XCTAssertFalse(gate.snapshot.effectiveMuted)
    }
}

@MainActor
final class AppModelTeamsMuteSyncTests: XCTestCase {
    func testTeamsMuteUpdateGatesRecordingAndVirtualMicOnce() async {
        let publisher = TeamsMuteSyncFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        let client = TeamsMuteSyncFakeClient()
        let model = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model.installTeamsMuteSync()

        client.emit(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        client.emit(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        await settle()

        XCTAssertTrue(recorder.micMuted)
        XCTAssertEqual(publisher.muteCalls, [true])
        XCTAssertEqual(model.statusMessage, "Teams / AirPods: recorder mic muted")
    }

    func testTeamsUnmuteRestoresRecordingAndVirtualMic() async {
        let publisher = TeamsMuteSyncFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        let client = TeamsMuteSyncFakeClient()
        let model = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model.installTeamsMuteSync()

        client.emit(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        client.emit(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: false,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        await settle()

        XCTAssertFalse(recorder.micMuted)
        XCTAssertEqual(publisher.muteCalls, [true, false])
        XCTAssertEqual(model.statusMessage, "Teams / AirPods: recorder mic active")
    }

    func testTeamsStatusIsVisibleWithoutReplacingMainStatus() async {
        let client = TeamsMuteSyncFakeClient()
        let model = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model.statusMessage = "Recording"
        model.installTeamsMuteSync()

        client.emit(.status(.waitingForTeamsAPI))
        await settle()

        XCTAssertEqual(model.teamsMuteSyncStatus, .waitingForTeamsAPI)
        XCTAssertEqual(model.statusMessage, "Recording")
    }

    func testTeamsTransportLossDuringMeetingFailsClosed() async {
        let publisher = TeamsMuteSyncFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        let client = TeamsMuteSyncFakeClient()
        let model = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model.installTeamsMuteSync()

        client.emit(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: false,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        client.emit(.status(.waitingForTeamsAPI))

        XCTAssertEqual(publisher.muteCalls, [true])
        await settle()
        XCTAssertTrue(recorder.micMuted)
        XCTAssertEqual(
            model.statusMessage,
            "Teams sync lost: recorder mic muted"
        )
    }

    func testNativeUnmuteCannotBypassAnActiveTeamsMute() async {
        let publisher = TeamsMuteSyncFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        let client = TeamsMuteSyncFakeClient()
        var controller: TeamsMuteSyncFakeInputController!
        let model = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            inputMuteControllerFactory: { applyMute in
                controller = TeamsMuteSyncFakeInputController(
                    applyMuteToAudioPaths: applyMute
                )
                return controller
            },
            teamsMuteSyncClient: client
        )
        model.installInputMuteHandling()
        model.installTeamsMuteSync()
        client.emit(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        controller.simulateRealtimeMuteHandler(muted: false)

        XCTAssertEqual(publisher.muteCalls, [false, true])
        await settle()
        XCTAssertTrue(recorder.micMuted)
    }

    func testLocalToggleCannotCreateStickyMuteWhileTeamsOwnsMute() async {
        let publisher = TeamsMuteSyncFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        let client = TeamsMuteSyncFakeClient()
        let model = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model.installTeamsMuteSync()
        client.emit(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        await settle()

        model.toggleRecorderMicMute(source: "Hotkey")

        XCTAssertFalse(model.localMicMuted)
        XCTAssertTrue(model.teamsMicMuted)
        XCTAssertTrue(recorder.micMuted)
        XCTAssertEqual(publisher.muteCalls, [true])
        XCTAssertEqual(
            model.statusMessage,
            "Hotkey: recorder mic is muted by Teams"
        )
    }

    func testStaleTeamsCallbackCannotRemuteAfterSyncIsDisabled() async {
        let publisher = TeamsMuteSyncFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        let client = TeamsMuteSyncFakeClient()
        let suiteName = "AppModelTeamsMuteSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = AppModel(
            defaults: defaults,
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model.installTeamsMuteSync()
        model.setTeamsMuteSyncEnabled(false)

        client.emitStale(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        await settle()

        XCTAssertFalse(recorder.micMuted)
        XCTAssertEqual(model.teamsMuteSyncStatus, .disabled)
        XCTAssertTrue(publisher.muteCalls.isEmpty)
    }

    func testAppModelTeardownStopsTeamsSyncClient() {
        let client = TeamsMuteSyncFakeClient()
        var model: AppModel? = AppModel(
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model?.installTeamsMuteSync()

        model = nil

        XCTAssertEqual(client.stopCount, 1)
    }

    func testAppModelTeardownInvalidatesStaleTeamsRelayCallback() async {
        let publisher = TeamsMuteSyncFakePublisher()
        let recorder = RecordingEngine(virtualMicPublisher: publisher)
        let client = TeamsMuteSyncFakeClient()
        var model: AppModel? = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client
        )
        model?.installTeamsMuteSync()

        model = nil
        client.emitStale(
            .meetingState(
                TeamsMeetingState(
                    isInMeeting: true,
                    isMuted: true,
                    canToggleMute: true,
                    canPair: false
                )
            )
        )
        await settle()

        XCTAssertFalse(recorder.micMuted)
        XCTAssertTrue(publisher.muteCalls.isEmpty)
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }
}

private final class TeamsMuteSyncFakeClient: TeamsMuteSyncing {
    private var onEvent: ((TeamsMuteSyncEvent) -> Void)?
    private var staleOnEvent: ((TeamsMuteSyncEvent) -> Void)?
    private(set) var stopCount = 0

    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void) {
        self.onEvent = onEvent
        staleOnEvent = onEvent
    }

    func stop() {
        stopCount += 1
        onEvent = nil
    }

    func reconnect() {}

    func requestPairing() {}

    func emit(_ event: TeamsMuteSyncEvent) {
        onEvent?(event)
    }

    func emitStale(_ event: TeamsMuteSyncEvent) {
        staleOnEvent?(event)
    }
}

private final class TeamsMuteSyncFakeInputController: InputMuteControlling {
    private let applyMuteToAudioPaths: (Bool) -> Void
    private(set) var isMuted = false

    init(applyMuteToAudioPaths: @escaping (Bool) -> Void) {
        self.applyMuteToAudioPaths = applyMuteToAudioPaths
    }

    func install(onChange: @escaping (Bool) -> Void) throws {
        applyMuteToAudioPaths(isMuted)
    }

    func setMuted(_ muted: Bool) throws {}

    func uninstall() {}

    func simulateRealtimeMuteHandler(muted: Bool) {
        applyMuteToAudioPaths(muted)
    }
}

private final class TeamsMuteSyncFakePublisher: VirtualMicPublishing {
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
