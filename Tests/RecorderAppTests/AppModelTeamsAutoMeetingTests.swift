import Combine
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelTeamsAutoMeetingTests: XCTestCase {
    func testAutoModeDefaultsOffAndPersistsChanges() {
        withDefaults { defaults in
            let model = makeModel(defaults: defaults)

            XCTAssertFalse(model.teamsAutoMeetingEnabled)

            model.setTeamsAutoMeetingEnabled(true)
            XCTAssertTrue(defaults.bool(forKey: "teamsAutoMeetingEnabled"))

            model.setTeamsAutoMeetingEnabled(false)
            XCTAssertFalse(defaults.bool(forKey: "teamsAutoMeetingEnabled"))
        }
    }

    func testAutoModeKeepsTeamsClientRunningWhenMuteSyncIsDisabled() {
        withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)

            model.setTeamsAutoMeetingEnabled(true)

            XCTAssertTrue(model.teamsAutoMeetingEnabled)
            XCTAssertEqual(client.startCount, 1)
            XCTAssertEqual(client.stopCount, 0)
            XCTAssertEqual(model.teamsMuteSyncStatus, .disabled)
        }
    }

    func testTeamsClientStopsOnlyWhenBothFeaturesAreDisabled() {
        withDefaults { defaults in
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.installTeamsIntegrationIfNeeded()
            model.setTeamsAutoMeetingEnabled(true)

            model.setTeamsMuteSyncEnabled(false)
            XCTAssertEqual(client.stopCount, 0)

            model.setTeamsAutoMeetingEnabled(false)
            XCTAssertEqual(client.stopCount, 1)
        }
    }

    func testAuthorizedMeetingEventReachesCoordinatorWhileMuteSyncIsDisabled() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.setTeamsAutoMeetingEnabled(true)

            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.inMeeting(muted: false)))
            await settle()

            XCTAssertEqual(
                model.teamsAutoMeetingState,
                .startCountdown(secondsRemaining: 5)
            )
            XCTAssertEqual(
                model.teamsConnectionStatus,
                .inMeeting(muted: false)
            )
            XCTAssertEqual(model.teamsMuteSyncStatus, .disabled)
        }
    }

    func testUnpairedMeetingEventDoesNotStartCountdown() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.setTeamsAutoMeetingEnabled(true)

            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.waitingForPairingApproval))
            await settle()

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testOnlyImmediatelyFollowingAuthorizingStatusCanRouteMeetingState() async {
        await withDefaults { defaults in
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.installTeamsIntegrationIfNeeded()

            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.connecting))
            client.emit(.status(.inMeeting(muted: false)))
            await settle()
            model.setTeamsAutoMeetingEnabled(true)

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testReadyAuthorizesImmediatelyPrecedingMeetingEnd() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.setTeamsAutoMeetingEnabled(true)
            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.inMeeting(muted: false)))
            await settle()
            XCTAssertEqual(
                model.teamsAutoMeetingState,
                .startCountdown(secondsRemaining: 5)
            )

            client.emit(.meetingState(Self.meetingState(isInMeeting: false)))
            client.emit(.status(.ready))
            await settle()

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testReadyRejectsImmediatelyPrecedingMeetingStart() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.setTeamsAutoMeetingEnabled(true)

            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.ready))
            await settle()

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testInMeetingRejectsImmediatelyPrecedingMeetingEnd() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.setTeamsAutoMeetingEnabled(true)

            client.emit(.meetingState(Self.meetingState(isInMeeting: false)))
            client.emit(.status(.inMeeting(muted: false)))
            await settle()

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testMismatchInvalidatesEarlierAuthorizedStateForRuntimeEnable() async {
        await withDefaults { defaults in
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.installTeamsIntegrationIfNeeded()
            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.inMeeting(muted: false)))
            client.emit(.meetingState(Self.meetingState(isInMeeting: false)))
            client.emit(.status(.inMeeting(muted: false)))
            await settle()

            model.setTeamsAutoMeetingEnabled(true)

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testPersistedAutoModeWaitsForFreshAuthorizedStateOnLaunch() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            defaults.set(true, forKey: "teamsAutoMeetingEnabled")
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)

            model.installTeamsIntegrationIfNeeded()
            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            await settle()

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testRuntimeEnableReplaysOnlyCurrentlyAuthorizedMeeting() async {
        await withDefaults { defaults in
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.installTeamsIntegrationIfNeeded()
            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.inMeeting(muted: false)))
            await settle()
            var observedStates: [TeamsAutoMeetingState] = []
            let observation = model.$teamsAutoMeetingState
                .dropFirst()
                .sink { observedStates.append($0) }

            model.setTeamsAutoMeetingEnabled(true)

            XCTAssertEqual(
                model.teamsAutoMeetingState,
                .startCountdown(secondsRemaining: 5)
            )
            XCTAssertEqual(
                observedStates.filter {
                    $0 == .startCountdown(secondsRemaining: 5)
                }.count,
                1
            )
            withExtendedLifetime(observation) {}
        }
    }

    func testRuntimeEnableDoesNotReplayAfterConnectionLosesAuthorization() async {
        await withDefaults { defaults in
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.installTeamsIntegrationIfNeeded()
            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.inMeeting(muted: false)))
            client.emit(.status(.connecting))
            await settle()

            model.setTeamsAutoMeetingEnabled(true)

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
        }
    }

    func testStaleReplacedCallbackCannotChangeCoordinatorOrConnectionState() async {
        await withDefaults { defaults in
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(defaults: defaults, client: client)
            model.installTeamsIntegrationIfNeeded()
            model.setTeamsAutoMeetingEnabled(true)
            model.setTeamsMuteSyncEnabled(false)
            XCTAssertGreaterThanOrEqual(client.startCount, 2)

            client.emitStale(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emitStale(.status(.inMeeting(muted: true)))
            await settle()

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
            XCTAssertEqual(model.teamsConnectionStatus, .disabled)
        }
    }

    func testDisablingAutoModeDoesNotClearMuteOwnership() async {
        await withDefaults { defaults in
            let publisher = AutoMeetingFakePublisher()
            let recorder = RecordingEngine(virtualMicPublisher: publisher)
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(
                defaults: defaults,
                client: client,
                recorder: recorder
            )
            model.installTeamsIntegrationIfNeeded()
            model.setTeamsAutoMeetingEnabled(true)
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
            client.emit(.status(.inMeeting(muted: true)))
            await settle()
            XCTAssertTrue(recorder.micMuted)

            model.setTeamsAutoMeetingEnabled(false)

            XCTAssertTrue(recorder.micMuted)
            XCTAssertTrue(model.teamsMicMuted)
            XCTAssertEqual(client.stopCount, 0)
        }
    }

    private func makeModel(
        defaults: UserDefaults,
        client: AutoMeetingFakeTeamsClient = AutoMeetingFakeTeamsClient(),
        recorder: RecordingEngine? = nil
    ) -> AppModel {
        AppModel(
            defaults: defaults,
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client,
            teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator()
        )
    }

    private func withDefaults(
        _ body: (UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "AppModelTeamsAutoMeetingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func withDefaults(
        _ body: (UserDefaults) async throws -> Void
    ) async rethrows {
        let suiteName = "AppModelTeamsAutoMeetingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }

    private static func meetingState(isInMeeting: Bool) -> TeamsMeetingState {
        TeamsMeetingState(
            isInMeeting: isInMeeting,
            isMuted: false,
            canToggleMute: true,
            canPair: false
        )
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }
}

private final class AutoMeetingFakeTeamsClient: TeamsMuteSyncing {
    private var callback: ((TeamsMuteSyncEvent) -> Void)?
    private var staleCallbacks: [(TeamsMuteSyncEvent) -> Void] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void) {
        if let callback {
            staleCallbacks.append(callback)
        }
        callback = onEvent
        startCount += 1
    }

    func stop() {
        callback = nil
        stopCount += 1
    }

    func reconnect() {}

    func requestPairing() {}

    func emit(_ event: TeamsMuteSyncEvent) {
        callback?(event)
    }

    func emitStale(_ event: TeamsMuteSyncEvent) {
        staleCallbacks.first?(event)
    }
}

private final class AutoMeetingFakePublisher: VirtualMicPublishing {
    private(set) var state: VirtualMicPublisherState = .stopped

    func start() {
        state = .ready
    }

    func publishMicrophone(left: [Float], right: [Float]) {}

    func setMuted(_ muted: Bool) {}

    func stop() {
        state = .stopped
    }
}
