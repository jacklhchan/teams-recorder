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

    func testEnablingMuteSyncDuringAutoOnlyMutedMeetingFailsClosedAndRefreshesState() async {
        await withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let publisher = AutoMeetingFakePublisher()
            let recorder = RecordingEngine(virtualMicPublisher: publisher)
            let client = AutoMeetingFakeTeamsClient()
            let model = makeModel(
                defaults: defaults,
                client: client,
                recorder: recorder
            )
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
            XCTAssertFalse(recorder.micMuted)
            XCTAssertTrue(publisher.muteCalls.isEmpty)

            model.setTeamsMuteSyncEnabled(true)

            XCTAssertEqual(client.reconnectCount, 1)
            XCTAssertTrue(recorder.micMuted)
            XCTAssertEqual(publisher.muteCalls, [true])
            XCTAssertEqual(model.teamsMuteSyncStatus, .connecting)
            XCTAssertEqual(model.teamsConnectionStatus, .connecting)

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
            XCTAssertEqual(publisher.muteCalls, [true, false])
            client.emit(.status(.inMeeting(muted: false)))
            await settle()

            XCTAssertFalse(recorder.micMuted)
            XCTAssertEqual(
                model.teamsMuteSyncStatus,
                .inMeeting(muted: false)
            )
        }
    }

    func testOrderedIngressRejectsPairWhenSchedulerRunsSecondWorkFirst() {
        withDefaults { defaults in
            defaults.set(false, forKey: "teamsMuteSyncEnabled")
            let scheduler = ControlledTeamsMainActorScheduler()
            let client = AutoMeetingFakeTeamsClient()
            let model = AppModel(
                defaults: defaults,
                inputDevices: { [] },
                defaultInputDeviceID: { nil },
                performStartupWork: false,
                teamsMuteSyncClient: client,
                teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator(),
                teamsIntegrationScheduler: scheduler.schedule
            )
            model.setTeamsAutoMeetingEnabled(true)

            client.emit(.meetingState(Self.meetingState(isInMeeting: true)))
            client.emit(.status(.connecting))
            client.emit(.status(.inMeeting(muted: false)))
            scheduler.runSecondBeforeFirstThenRemaining()

            XCTAssertEqual(model.teamsAutoMeetingState, .waitingForMeeting)
            XCTAssertEqual(
                model.teamsConnectionStatus,
                .inMeeting(muted: false)
            )
        }
    }

    func testCountdownStartsAutomaticRecordingWithoutRequestingPermission() async {
        let fixture = makeRecordingFixture()

        await startAutomaticRecording(fixture)

        XCTAssertEqual(fixture.permissionRequestCount.value, 0)
        XCTAssertEqual(fixture.model.recordingOwnership, .teamsAutomatic)
        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(fixture.source.startCount, 1)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testManualStartDuringCountdownOwnsRecordingAndMeetingEndDoesNotStopIt() async {
        let fixture = makeRecordingFixture()
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await waitUntil {
            fixture.model.teamsAutoMeetingState
                == .startCountdown(secondsRemaining: 5)
        }

        fixture.model.startOrStop()
        await waitUntil {
            fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }
        emitMeeting(false, in: fixture)

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.model.recordingOwnership, .manual)
        XCTAssertEqual(fixture.source.startCount, 1)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testRuntimeEnableDuringManualMeetingSuppressesWithoutBusyFailure() async {
        let fixture = makeRecordingFixture()
        fixture.model.installTeamsIntegrationIfNeeded()
        fixture.model.startOrStop()
        await waitUntil {
            fixture.engine.isRecording
                && fixture.model.recordingOwnership == .manual
                && !fixture.model.isCaptureLifecycleWorking
        }
        emitMeeting(true, in: fixture)

        fixture.model.setTeamsAutoMeetingEnabled(true)

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.model.recordingOwnership, .manual)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testAuthorizedMeetingStartDuringManualRecordingSuppressesAutomation() async {
        let fixture = makeRecordingFixture()
        fixture.model.setTeamsAutoMeetingEnabled(true)
        fixture.model.startOrStop()
        await waitUntil {
            fixture.engine.isRecording
                && fixture.model.recordingOwnership == .manual
                && !fixture.model.isCaptureLifecycleWorking
        }

        emitMeeting(true, in: fixture)

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.model.recordingOwnership, .manual)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testTestRecordingUsesManualOwnershipAndSuppressesCountdown() async {
        let delay = AutoMeetingManualTicker()
        let fixture = makeRecordingFixture(testRecordingDelay: {
            await delay.waitForTick()
        })
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await waitUntil {
            fixture.model.teamsAutoMeetingState
                == .startCountdown(secondsRemaining: 5)
        }

        fixture.model.runTestRecording()
        await waitUntil {
            fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertEqual(fixture.model.recordingOwnership, .manual)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        await delay.fireAndWaitForAcknowledgement()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testTenFalseTicksStopAndFinalizeAutomaticRecordingExactlyOnce() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)

        emitMeeting(false, in: fixture)
        await fire(fixture.ticker, count: 9)
        XCTAssertTrue(fixture.engine.isRecording)

        await fire(fixture.ticker)
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testTrueAtNinthFalseTickCancelsAutomaticStop() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)

        emitMeeting(false, in: fixture)
        await fire(fixture.ticker, count: 9)
        emitMeeting(true, in: fixture)

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.model.recordingOwnership, .teamsAutomatic)
        XCTAssertEqual(fixture.source.stopCount, 0)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testManualStopSuppressesAutomaticRestartForCurrentMeeting() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)

        fixture.model.startOrStop()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }
        emitMeeting(true, in: fixture)

        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testManualStopDuringStopDebounceSuppressesRejoinUntilLaterFalse() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)
        emitMeeting(false, in: fixture)
        await fire(fixture.ticker, count: 3)

        fixture.model.startOrStop()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }
        emitMeeting(true, in: fixture)

        guard fixture.model.teamsAutoMeetingState
                == .suppressedUntilMeetingEnd else {
            return XCTFail("Manual stop did not suppress the rejoined meeting")
        }
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker)
        emitMeeting(true, in: fixture)

        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)

        emitMeeting(false, in: fixture)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .waitingForMeeting
        )
        emitMeeting(true, in: fixture)
        emitMeeting(true, in: fixture)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .startCountdown(secondsRemaining: 5)
        )
        await fire(fixture.ticker)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .startCountdown(secondsRemaining: 4)
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.stopCount, 1)
    }

    func testDisablingAutoTransfersActiveRecordingToManualWithoutStopping() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)

        fixture.model.setTeamsAutoMeetingEnabled(false)

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.model.recordingOwnership, .manual)
        XCTAssertEqual(fixture.source.stopCount, 0)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testReadinessBlockedDoesNotRequestPermissionOrRetryUntilFalse() async {
        let fixture = makeRecordingFixture()
        fixture.model.systemAudioPermission = .denied
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        emitMeeting(true, in: fixture)

        XCTAssertEqual(fixture.permissionRequestCount.value, 0)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .startBlocked(
                "Screen & System Audio Recording permission is required."
            )
        )
        XCTAssertEqual(fixture.source.startCount, 0)
    }

    func testAutomaticStartFailureDoesNotRetryUntilFalse() async {
        let fixture = makeRecordingFixture()
        fixture.source.startError = AutoMeetingRecordingError.startFailed
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        emitMeeting(true, in: fixture)

        guard case .startFailed = fixture.model.teamsAutoMeetingState else {
            return XCTFail("Expected automatic start failure")
        }
        XCTAssertEqual(fixture.permissionRequestCount.value, 0)
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertFalse(fixture.engine.isRecording)
    }

    func testWaitUntilAllowsDelayedMainActorCompletion() async {
        var didFinish = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            didFinish = true
        }

        await waitUntil { didFinish }
    }

    func testLifecycleBusyMovesAutomaticStartToFailedWithoutRetry() async {
        let fixture = makeRecordingFixture()
        fixture.source.pauseRefresh = true
        fixture.model.refreshCaptureApplications()
        await waitUntil { fixture.source.hasPausedRefresh }
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)

        guard case .startFailed = fixture.model.teamsAutoMeetingState else {
            return XCTFail("Expected busy lifecycle to fail automatic start")
        }
        emitMeeting(true, in: fixture)
        XCTAssertEqual(fixture.source.startCount, 0)

        fixture.source.resumeRefresh()
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
    }

    func testFalseDuringBlockedStoragePreflightCannotLeaveLateRecording() async {
        let provider = AutoMeetingStorageProvider(results: [
            .blocked(6 * 1_024 * 1_024 * 1_024)
        ])
        let fixture = makeRecordingFixture(storageProvider: provider)
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)
        await provider.waitForBlockedRequest()

        emitMeeting(false, in: fixture)
        provider.resumeBlockedRequest()
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.startCount, 0)
        XCTAssertEqual(fixture.writer.closeCount, 0)
    }

    func testFalseDuringSourceStartFinalizesLateRecordingExactlyOnce() async {
        let fixture = makeRecordingFixture()
        fixture.source.pauseStart = true
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)
        await waitUntil { fixture.source.hasPausedStart }

        emitMeeting(false, in: fixture)
        fixture.source.resumeStart()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testManualStartTakesOverPausedAutomaticSourceStart() async {
        let fixture = makeRecordingFixture()
        fixture.source.pauseStart = true
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)
        await waitUntil { fixture.source.hasPausedStart }
        XCTAssertFalse(fixture.engine.isRecording)

        fixture.model.startOrStop()
        fixture.source.resumeStart()
        await waitUntil {
            fixture.engine.isRecording
                && fixture.model.recordingOwnership == .manual
                && !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.stopCount, 0)
        XCTAssertEqual(fixture.writer.closeCount, 0)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testManualStopDuringAutomaticPostStartOwnershipGapKeepsSingleFinalizationOwner() async {
        let fixture = makeRecordingFixture()
        let teamsApplication = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await settle()
        fixture.model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: teamsApplication.bundleIdentifier
        )
        fixture.model.availableCaptureApplications = [teamsApplication]
        fixture.model.resolvedCaptureSelection = .application(teamsApplication)
        fixture.source.pauseTeamsRefresh = true
        fixture.source.resumeTeamsRefreshOnCancellation = true
        await fire(fixture.ticker, count: 5)
        await waitUntil {
            fixture.source.teamsRefreshCount >= 1
                && fixture.engine.isRecording
        }
        XCTAssertNil(fixture.model.recordingOwnership)

        fixture.source.pauseStop = true
        fixture.model.startOrStop()
        await waitUntil { fixture.source.hasPausedStop }
        await settle()

        XCTAssertTrue(fixture.model.isFinalizingRecording)
        XCTAssertTrue(fixture.model.isCaptureLifecycleWorking)
        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 0)
        XCTAssertNotEqual(fixture.model.statusMessage, "No active recording.")
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )

        fixture.source.resumeStop()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        emitMeeting(true, in: fixture)
        await settle()

        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
        XCTAssertNotEqual(fixture.model.statusMessage, "No active recording.")
    }

    func testDisableDuringSourceStartFinalizesLateRecordingWithoutStoppingTransferredWork() async {
        let fixture = makeRecordingFixture()
        fixture.source.pauseStart = true
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)
        await waitUntil { fixture.source.hasPausedStart }

        fixture.model.setTeamsAutoMeetingEnabled(false)
        fixture.source.resumeStart()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertEqual(fixture.model.teamsAutoMeetingState, .disabled)
        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testTerminalStopDuringPostStartRefreshFailsAttemptAndClearsLifecycle() async {
        let fixture = makeRecordingFixture()
        let teamsApplication = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await settle()
        fixture.model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: teamsApplication.bundleIdentifier
        )
        fixture.model.availableCaptureApplications = [teamsApplication]
        fixture.model.resolvedCaptureSelection = .application(teamsApplication)
        fixture.source.pauseTeamsRefresh = true
        await fire(fixture.ticker, count: 5)
        await waitUntil {
            fixture.source.teamsRefreshCount >= 1
                && fixture.engine.isRecording
        }
        XCTAssertNil(fixture.model.recordingOwnership)

        fixture.source.emit(.streamFailed)
        await waitUntil { !fixture.engine.isRecording }
        fixture.source.resumeTeamsRefresh()
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        guard case .startFailed = fixture.model.teamsAutoMeetingState else {
            return XCTFail("Expected terminal post-start stop to fail attempt")
        }
        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testStorageForcedStopClearsOwnershipAndSuppressesRestart() async {
        let storageTicker = AutoMeetingManualTicker()
        let provider = AutoMeetingStorageProvider(results: [
            .value(6 * 1_024 * 1_024 * 1_024),
            .value((256 * 1_024 * 1_024) - 1)
        ])
        let fixture = makeRecordingFixture(
            storageProvider: provider,
            storageMonitorTick: { await storageTicker.waitForTick() }
        )
        await startAutomaticRecording(fixture)

        await storageTicker.fireAndWaitForAcknowledgement()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }
        emitMeeting(true, in: fixture)

        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testTerminalEngineStopClearsOwnershipAndSuppressesRestart() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)

        fixture.source.emit(.streamFailed)
        await waitUntil { !fixture.engine.isRecording }
        await waitUntil { fixture.model.recordingOwnership == nil }
        emitMeeting(true, in: fixture)

        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .suppressedUntilMeetingEnd
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testPausedStopSignalsBeforeItCanBeResumed() async {
        let source = AutoMeetingRecordingCaptureSource()
        source.pauseStop = true

        let stopped = Task { await source.stop() }
        await waitUntil { source.hasPausedStop }

        source.resumeStop()
        await stopped.value

        XCTAssertEqual(source.stopCount, 1)
    }

    func testPausedStartSignalsBeforeItCanBeResumed() async throws {
        let source = AutoMeetingRecordingCaptureSource()
        source.pauseStart = true

        let started = Task {
            try await source.start(
                selection: .allSystemAudio,
                microphoneUID: nil,
                onAudio: { _ in },
                onVideo: { _ in },
                onEvent: { _ in }
            )
        }
        await waitUntil { source.hasPausedStart }

        source.resumeStart()
        try await started.value

        XCTAssertEqual(source.startCount, 1)
    }

    func testPausedRefreshSignalsBeforeItCanBeResumed() async throws {
        let source = AutoMeetingRecordingCaptureSource()
        source.pauseRefresh = true

        let refresh = Task { try await source.refreshContent() }
        await waitUntil { source.hasPausedRefresh }

        source.resumeRefresh()
        _ = try await refresh.value
    }

    func testTerminalStopWinningAutoStopRaceCompletesMeetingEndOnce() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)
        emitMeeting(false, in: fixture)
        await fire(fixture.ticker, count: 9)
        fixture.source.pauseStop = true

        fixture.source.emit(.streamFailed)
        await waitUntil { fixture.source.hasPausedStop }
        await fire(fixture.ticker)
        fixture.source.resumeStop()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .waitingForMeeting
        )
        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testTrueAfterCommittedAutomaticStopStartsOneNewCountdown() async {
        let fixture = makeRecordingFixture()
        await startAutomaticRecording(fixture)
        emitMeeting(false, in: fixture)
        await fire(fixture.ticker, count: 9)
        fixture.source.pauseStop = true

        await fire(fixture.ticker)
        await waitUntil { fixture.source.hasPausedStop }
        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertNil(fixture.model.recordingOwnership)

        emitMeeting(true, in: fixture)
        fixture.source.resumeStop()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertNil(fixture.model.recordingOwnership)
        guard fixture.model.teamsAutoMeetingState
                == .startCountdown(secondsRemaining: 5) else {
            return XCTFail(
                "Committed stop did not reconcile the latest true meeting"
            )
        }
        emitMeeting(true, in: fixture)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .startCountdown(secondsRemaining: 5)
        )
        await fire(fixture.ticker)
        XCTAssertEqual(
            fixture.model.teamsAutoMeetingState,
            .startCountdown(secondsRemaining: 4)
        )
        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    func testTerminalStopDuringTestRecordingPostStartRefreshClearsStateAndDelay() async {
        let delay = AutoMeetingManualTicker()
        let fixture = makeRecordingFixture(testRecordingDelay: {
            await delay.waitForTick()
        })
        let teamsApplication = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        fixture.model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: teamsApplication.bundleIdentifier
        )
        fixture.model.availableCaptureApplications = [teamsApplication]
        fixture.model.resolvedCaptureSelection = .application(teamsApplication)
        fixture.source.pauseTeamsRefresh = true

        fixture.model.runTestRecording()
        await waitUntil {
            fixture.source.teamsRefreshCount >= 1
                && fixture.engine.isRecording
        }
        XCTAssertTrue(fixture.model.isRunningTestRecording)
        XCTAssertNil(fixture.model.recordingOwnership)

        fixture.source.emit(.streamFailed)
        await waitUntil { !fixture.engine.isRecording }
        await delay.fire()
        fixture.source.resumeTeamsRefresh()
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await settle()
        let acknowledgedDelayTicks = await delay.acknowledgedTickCount()

        XCTAssertFalse(fixture.model.isRunningTestRecording)
        XCTAssertNil(fixture.model.recordingOwnership)
        XCTAssertEqual(acknowledgedDelayTicks, 0)
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertEqual(fixture.writer.closeCount, 1)
    }

    private func makeRecordingFixture(
        storageProvider: AutoMeetingStorageProvider = .normal,
        storageMonitorTick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(3_600))
        },
        testRecordingDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(3_600))
        }
    ) -> AutoMeetingRecordingFixture {
        let source = AutoMeetingRecordingCaptureSource()
        let writer = AutoMeetingRecordingWriter()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in writer },
            mixerBlockFrames: 4
        )
        let ticker = AutoMeetingManualTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            tick: { await ticker.waitForTick() }
        )
        let client = AutoMeetingFakeTeamsClient()
        let permissionRequestCount = AutoMeetingIntBox()
        let suiteName = "AppModelTeamsAutoMeetingLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let microphone = AudioDevice(
            id: 1,
            uid: "test-microphone",
            name: "Test Microphone",
            manufacturer: "Tests",
            channelCount: 1
        )
        let model = AppModel(
            defaults: defaults,
            recorder: engine,
            inputDevices: { [microphone] },
            defaultInputDeviceID: { microphone.id },
            performStartupWork: false,
            teamsMuteSyncClient: client,
            permissionRequestHandler: { _, _ in
                permissionRequestCount.value += 1
            },
            volumeCapacityProvider: storageProvider,
            storagePolicy: RecordingStoragePolicy(),
            storageMonitorTick: storageMonitorTick,
            testRecordingDelay: testRecordingDelay,
            teamsAutoMeetingCoordinator: coordinator,
            teamsIntegrationScheduler: { operation in
                MainActor.assumeIsolated {
                    operation()
                }
            }
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        return AutoMeetingRecordingFixture(
            model: model,
            engine: engine,
            source: source,
            writer: writer,
            teams: client,
            ticker: ticker,
            permissionRequestCount: permissionRequestCount,
            defaults: defaults
        )
    }

    private func startAutomaticRecording(
        _ fixture: AutoMeetingRecordingFixture
    ) async {
        fixture.model.setTeamsAutoMeetingEnabled(true)
        emitMeeting(true, in: fixture)
        await fire(fixture.ticker, count: 5)
        await waitUntil {
            fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }
    }

    private func emitMeeting(
        _ isInMeeting: Bool,
        in fixture: AutoMeetingRecordingFixture
    ) {
        fixture.teams.emit(
            .meetingState(Self.meetingState(isInMeeting: isInMeeting))
        )
        fixture.teams.emit(
            .status(isInMeeting ? .inMeeting(muted: false) : .ready)
        )
    }

    private func fire(
        _ ticker: AutoMeetingManualTicker,
        count: Int = 1
    ) async {
        for _ in 0..<count {
            await ticker.fireAndWaitForAcknowledgement()
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if condition() { return }
        XCTFail("Condition was not reached", file: file, line: line)
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
    private(set) var reconnectCount = 0

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

    func reconnect() {
        reconnectCount += 1
    }

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

private final class ControlledTeamsMainActorScheduler: @unchecked Sendable {
    typealias Operation = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var operations: [Operation] = []

    func schedule(_ operation: @escaping Operation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }

    @MainActor
    func runSecondBeforeFirstThenRemaining() {
        lock.lock()
        let scheduled = operations
        operations.removeAll()
        lock.unlock()

        guard scheduled.count >= 2 else {
            scheduled.forEach { $0() }
            return
        }

        scheduled[1]()
        scheduled[0]()
        scheduled.dropFirst(2).forEach { $0() }
    }
}

private struct AutoMeetingRecordingFixture {
    let model: AppModel
    let engine: RecordingEngine
    let source: AutoMeetingRecordingCaptureSource
    let writer: AutoMeetingRecordingWriter
    let teams: AutoMeetingFakeTeamsClient
    let ticker: AutoMeetingManualTicker
    let permissionRequestCount: AutoMeetingIntBox
    let defaults: UserDefaults
}

private final class AutoMeetingIntBox {
    var value = 0
}

private enum AutoMeetingRecordingError: LocalizedError {
    case startFailed

    var errorDescription: String? { "automatic source start failed" }
}

private final class AutoMeetingRecordingCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(
        width: 1_600,
        height: 900,
        pixelFormat: 0
    )
    private(set) var teamsRefreshCount = 0
    var startError: Error?
    var pauseStart: Bool {
        get { startLock.withLock { startPauseRequested } }
        set {
            let continuation = startLock.withLock { () -> CheckedContinuation<Void, Never>? in
                startPauseRequested = newValue
                if newValue {
                    hasPausedStartStorage = false
                    return nil
                }
                let continuation = startContinuation
                startContinuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }
    var pauseRefresh: Bool {
        get { refreshLock.withLock { refreshPauseRequested } }
        set {
            let continuation = refreshLock.withLock { () -> CheckedContinuation<Void, Never>? in
                refreshPauseRequested = newValue
                if newValue {
                    hasPausedRefreshStorage = false
                    return nil
                }
                let continuation = refreshContinuation
                refreshContinuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }
    var pauseTeamsRefresh = false
    var resumeTeamsRefreshOnCancellation = false
    var pauseStop: Bool {
        get { stopLock.withLock { stopPauseRequested } }
        set {
            let continuation = stopLock.withLock { () -> CheckedContinuation<Void, Never>? in
                stopPauseRequested = newValue
                if newValue {
                    hasPausedStopStorage = false
                    return nil
                }
                let continuation = stopContinuation
                stopContinuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }
    var startCount: Int { startLock.withLock { startCountStorage } }
    var hasPausedStart: Bool { startLock.withLock { hasPausedStartStorage } }
    var hasPausedRefresh: Bool { refreshLock.withLock { hasPausedRefreshStorage } }
    var stopCount: Int { stopLock.withLock { stopCountStorage } }
    var hasPausedStop: Bool { stopLock.withLock { hasPausedStopStorage } }
    private var onEvent: ((CaptureEvent) -> Void)?
    private let startLock = NSLock()
    private var startCountStorage = 0
    private var startPauseRequested = false
    private var hasPausedStartStorage = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private let refreshLock = NSLock()
    private var refreshPauseRequested = false
    private var hasPausedRefreshStorage = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var teamsRefreshContinuation: CheckedContinuation<Void, Never>?
    private let stopLock = NSLock()
    private var stopCountStorage = 0
    private var stopPauseRequested = false
    private var hasPausedStopStorage = false
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func refreshContent() async throws -> [CaptureApplication] {
        let shouldPause = refreshLock.withLock {
            guard refreshPauseRequested else { return false }
            hasPausedRefreshStorage = true
            return true
        }
        guard shouldPause else { return [] }

        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = refreshLock.withLock {
                guard refreshPauseRequested else { return true }
                refreshContinuation = continuation
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
        return []
    }

    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] {
        teamsRefreshCount += 1
        if pauseTeamsRefresh {
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    teamsRefreshContinuation = $0
                }
            } onCancel: {
                guard self.resumeTeamsRefreshOnCancellation else { return }
                Task { @MainActor in
                    self.resumeTeamsRefresh()
                }
            }
        }
        return []
    }

    func reconnect(selection _: ResolvedCaptureSelection) async throws {}

    func updateVideoTarget(
        _ target: TeamsWindowIdentity?
    ) async throws -> CaptureFilterRevision {
        .init(sessionGeneration: 0, revision: 0)
    }

    func start(
        selection _: ResolvedCaptureSelection,
        microphoneUID _: String?,
        onAudio _: @escaping (AudioFrameBlock) -> Void,
        onVideo _: @escaping (ScreenVideoFrame) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws {
        self.onEvent = onEvent
        let shouldPause = startLock.withLock {
            startCountStorage += 1
            guard startPauseRequested else { return false }
            hasPausedStartStorage = true
            return true
        }
        if shouldPause {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = startLock.withLock {
                    guard startPauseRequested else { return true }
                    startContinuation = continuation
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        }
        if let startError { throw startError }
    }

    func stop() async {
        let shouldPause = stopLock.withLock {
            stopCountStorage += 1
            guard stopPauseRequested else { return false }
            hasPausedStopStorage = true
            return true
        }
        guard shouldPause else { return }

        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = stopLock.withLock {
                guard stopPauseRequested else { return true }
                stopContinuation = continuation
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func resumeStart() {
        pauseStart = false
    }

    func resumeRefresh() {
        pauseRefresh = false
    }

    func resumeTeamsRefresh() {
        pauseTeamsRefresh = false
        teamsRefreshContinuation?.resume()
        teamsRefreshContinuation = nil
    }

    func resumeStop() {
        pauseStop = false
    }

    func emit(_ event: CaptureEvent) {
        onEvent?(event)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class AutoMeetingRecordingWriter: MixedAudioWriting {
    private(set) var closeCount = 0

    func write(_: MixedAudioBlock) throws {}

    func close() throws {
        closeCount += 1
    }
}

private final class AutoMeetingStorageProvider:
    VolumeCapacityProviding,
    @unchecked Sendable
{
    enum Result {
        case value(Int64)
        case blocked(Int64)
    }

    private let lock = NSLock()
    private var results: [Result]
    private var blockedSemaphore: DispatchSemaphore?
    private let blockedRequestSemaphore = DispatchSemaphore(value: 0)

    init(results: [Result]) {
        self.results = results
    }

    static var normal: AutoMeetingStorageProvider {
        AutoMeetingStorageProvider(
            results: Array(
                repeating: .value(6 * 1_024 * 1_024 * 1_024),
                count: 20
            )
        )
    }

    func availableBytes(onVolumeContaining _: URL) throws -> Int64 {
        lock.lock()
        let result = results.removeFirst()
        guard case .blocked(let value) = result else {
            lock.unlock()
            if case .value(let value) = result { return value }
            fatalError("Unreachable storage result")
        }
        let semaphore = DispatchSemaphore(value: 0)
        blockedSemaphore = semaphore
        lock.unlock()
        blockedRequestSemaphore.signal()
        semaphore.wait()
        return value
    }

    func waitForBlockedRequest() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.blockedRequestSemaphore.wait()
                continuation.resume()
            }
        }
    }

    func resumeBlockedRequest() {
        lock.lock()
        let semaphore = blockedSemaphore
        blockedSemaphore = nil
        lock.unlock()
        semaphore?.signal()
    }
}

private actor AutoMeetingManualTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0
    private var deliveredTicks = 0
    private var acknowledgedTicks = 0
    private var acknowledgementContinuations:
        [(tick: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
        } else {
            await withCheckedContinuation { continuations.append($0) }
        }
        acknowledgedTicks += 1
        let ready = acknowledgementContinuations.filter {
            $0.tick <= acknowledgedTicks
        }
        acknowledgementContinuations.removeAll {
            $0.tick <= acknowledgedTicks
        }
        ready.forEach { $0.continuation.resume() }
    }

    func fireAndWaitForAcknowledgement() async {
        deliveredTicks += 1
        let tick = deliveredTicks
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }
        if acknowledgedTicks < tick {
            await withCheckedContinuation {
                acknowledgementContinuations.append(
                    (tick: tick, continuation: $0)
                )
            }
        }
    }

    func fire() {
        deliveredTicks += 1
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }
    }

    func acknowledgedTickCount() -> Int {
        acknowledgedTicks
    }
}
