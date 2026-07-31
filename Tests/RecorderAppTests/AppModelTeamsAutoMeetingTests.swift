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

    func testAutomaticRecordingPersistsTeamsAutomaticSourceMetadata() async throws {
        let outputFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputFolder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputFolder) }
        let fixture = makeRecordingFixture(
            initialOutputFolder: outputFolder
        )

        await startAutomaticRecording(fixture)
        fixture.model.startOrStop()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }

        let sessionFolder = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: outputFolder,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(
            RecordingSessionMetadataStore.load(in: sessionFolder).source,
            .teamsAutomatic
        )
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
            .blocked(Int64(6) * 1_024 * 1_024 * 1_024)
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
                && fixture.writer.closeCount == 1
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
            fixture.source.hasPausedTeamsRefresh
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
            fixture.source.hasPausedTeamsRefresh
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
            .value(Int64(6) * 1_024 * 1_024 * 1_024),
            .value((Int64(256) * 1_024 * 1_024) - 1)
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

    func testPausedStopCanResumeBeforeContinuationInstallation() async {
        let source = AutoMeetingRecordingCaptureSource()
        let barrier = AutoMeetingPauseInstallationBarrier()
        source.pauseStop = true
        source.stopPauseInstallationBarrier = barrier

        let stopped = Task { await source.stop() }
        await barrier.waitForArrival()
        XCTAssertTrue(source.hasPausedStop)

        source.resumeStop()
        await barrier.release()
        await stopped.value

        XCTAssertEqual(source.stopCount, 1)
    }

    func testPausedStartCanResumeBeforeContinuationInstallation() async throws {
        let source = AutoMeetingRecordingCaptureSource()
        let barrier = AutoMeetingPauseInstallationBarrier()
        source.pauseStart = true
        source.startPauseInstallationBarrier = barrier

        let started = Task {
            try await source.start(
                selection: .allSystemAudio,
                microphoneUID: nil,
                onAudio: { _ in },
                onVideo: { _ in },
                onEvent: { _ in }
            )
        }
        await barrier.waitForArrival()
        XCTAssertTrue(source.hasPausedStart)

        source.resumeStart()
        await barrier.release()
        try await started.value

        XCTAssertEqual(source.startCount, 1)
    }

    func testPausedRefreshCanResumeBeforeContinuationInstallation() async throws {
        let source = AutoMeetingRecordingCaptureSource()
        let barrier = AutoMeetingPauseInstallationBarrier()
        source.pauseRefresh = true
        source.refreshPauseInstallationBarrier = barrier

        let refresh = Task { try await source.refreshContent() }
        await barrier.waitForArrival()
        XCTAssertTrue(source.hasPausedRefresh)

        source.resumeRefresh()
        await barrier.release()
        _ = try await refresh.value
    }

    func testPausedTeamsRefreshCanResumeBeforeContinuationInstallation() async throws {
        let source = AutoMeetingRecordingCaptureSource()
        let barrier = AutoMeetingPauseInstallationBarrier()
        source.pauseTeamsRefresh = true
        source.teamsRefreshPauseInstallationBarrier = barrier

        let refresh = Task { try await source.refreshTeamsWindows() }
        await barrier.waitForArrival()
        XCTAssertTrue(source.hasPausedTeamsRefresh)

        source.resumeTeamsRefresh()
        await barrier.release()
        _ = try await refresh.value

        XCTAssertEqual(source.teamsRefreshCount, 1)
    }

    func testPauseGateResumesConcurrentWaitersAfterFalseBeforeInstallation() async {
        let gate = AutoMeetingPauseGate()
        let barrier = AutoMeetingPauseInstallationBarrier()
        gate.setPauseRequested(true)
        gate.setInstallationBarrier(barrier)

        let first = Task { await gate.waitIfRequested() }
        let second = Task { await gate.waitIfRequested() }
        await barrier.waitForArrivals(2)

        gate.setPauseRequested(false)
        await barrier.release()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
    }

    func testPauseGateResumesAllInstalledConcurrentWaiters() async {
        let gate = AutoMeetingPauseGate()
        gate.setPauseRequested(true)

        let first = Task { await gate.waitIfRequested() }
        let second = Task { await gate.waitIfRequested() }
        await waitUntil { gate.waitingCount == 2 }

        gate.setPauseRequested(false)

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
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
            fixture.source.hasPausedTeamsRefresh
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
        initialOutputFolder: URL? = nil,
        storageProvider: AutoMeetingStorageProvider = .normal,
        storageMonitorTick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(3_600))
        },
        testRecordingDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(3_600))
        }
    ) -> AutoMeetingRecordingFixture {
        let fixtureOutputFolder: URL
        if let initialOutputFolder {
            fixtureOutputFolder = initialOutputFolder
        } else {
            fixtureOutputFolder = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AppModelTeamsAutoMeetingTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try! FileManager.default.createDirectory(
                at: fixtureOutputFolder,
                withIntermediateDirectories: true
            )
            addTeardownBlock {
                try? FileManager.default.removeItem(at: fixtureOutputFolder)
            }
        }
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
            initialOutputFolder: fixtureOutputFolder,
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

private actor AutoMeetingPauseInstallationBarrier {
    private var arrivalCount = 0
    private var released = false
    private var arrivalContinuations:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitForArrival() async {
        await waitForArrivals(1)
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivalCount < count else { return }
        await withCheckedContinuation {
            arrivalContinuations.append((count: count, continuation: $0))
        }
    }

    func arriveAndWaitForRelease() async {
        arrivalCount += 1
        let arrivals = arrivalContinuations.filter { $0.count <= arrivalCount }
        arrivalContinuations.removeAll { $0.count <= arrivalCount }
        arrivals.forEach { $0.continuation.resume() }

        guard !released else { return }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func release() {
        released = true
        let releases = releaseContinuations
        releaseContinuations.removeAll()
        releases.forEach { $0.resume() }
    }
}

private final class AutoMeetingPauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pauseRequested = false
    private var paused = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var installationBarrier: AutoMeetingPauseInstallationBarrier?

    var isPauseRequested: Bool {
        lock.withLock { pauseRequested }
    }

    var hasPaused: Bool {
        lock.withLock { paused }
    }

    var currentInstallationBarrier: AutoMeetingPauseInstallationBarrier? {
        lock.withLock { installationBarrier }
    }

    var waitingCount: Int {
        lock.withLock { continuations.count }
    }

    func setPauseRequested(_ requested: Bool) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            pauseRequested = requested
            if requested {
                paused = false
                return []
            }
            let continuations = self.continuations
            self.continuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func setInstallationBarrier(_ barrier: AutoMeetingPauseInstallationBarrier?) {
        lock.withLock { installationBarrier = barrier }
    }

    func waitIfRequested() async -> Bool {
        let pause = lock.withLock { () -> (Bool, AutoMeetingPauseInstallationBarrier?) in
            guard pauseRequested else { return (false, nil) }
            paused = true
            return (true, installationBarrier)
        }
        guard pause.0 else { return false }

        if let barrier = pause.1 {
            await barrier.arriveAndWaitForRelease()
        }

        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = lock.withLock {
                guard pauseRequested else { return true }
                self.continuations.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
        return true
    }
}

private final class AutoMeetingRecordingCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(
        width: 1_600,
        height: 900,
        pixelFormat: 0
    )
    var startError: Error?
    var pauseStart: Bool {
        get { startPauseGate.isPauseRequested }
        set { startPauseGate.setPauseRequested(newValue) }
    }
    var pauseRefresh: Bool {
        get { refreshPauseGate.isPauseRequested }
        set { refreshPauseGate.setPauseRequested(newValue) }
    }
    var pauseTeamsRefresh: Bool {
        get { teamsRefreshPauseGate.isPauseRequested }
        set { teamsRefreshPauseGate.setPauseRequested(newValue) }
    }
    var resumeTeamsRefreshOnCancellation: Bool {
        get { teamsRefreshConfigurationLock.withLock { resumeTeamsRefreshOnCancellationStorage } }
        set { teamsRefreshConfigurationLock.withLock { resumeTeamsRefreshOnCancellationStorage = newValue } }
    }
    var pauseStop: Bool {
        get { stopPauseGate.isPauseRequested }
        set { stopPauseGate.setPauseRequested(newValue) }
    }
    var startCount: Int { startLock.withLock { startCountStorage } }
    var hasPausedStart: Bool { startPauseGate.hasPaused }
    var hasPausedRefresh: Bool { refreshPauseGate.hasPaused }
    var hasPausedTeamsRefresh: Bool { teamsRefreshPauseGate.hasPaused }
    var stopCount: Int { stopLock.withLock { stopCountStorage } }
    var hasPausedStop: Bool { stopPauseGate.hasPaused }
    var teamsRefreshCount: Int { teamsRefreshCountLock.withLock { teamsRefreshCountStorage } }
    var startPauseInstallationBarrier: AutoMeetingPauseInstallationBarrier? {
        get { startPauseGate.currentInstallationBarrier }
        set { startPauseGate.setInstallationBarrier(newValue) }
    }
    var refreshPauseInstallationBarrier: AutoMeetingPauseInstallationBarrier? {
        get { refreshPauseGate.currentInstallationBarrier }
        set { refreshPauseGate.setInstallationBarrier(newValue) }
    }
    var teamsRefreshPauseInstallationBarrier: AutoMeetingPauseInstallationBarrier? {
        get { teamsRefreshPauseGate.currentInstallationBarrier }
        set { teamsRefreshPauseGate.setInstallationBarrier(newValue) }
    }
    var stopPauseInstallationBarrier: AutoMeetingPauseInstallationBarrier? {
        get { stopPauseGate.currentInstallationBarrier }
        set { stopPauseGate.setInstallationBarrier(newValue) }
    }
    private var onEvent: ((CaptureEvent) -> Void)?
    private let startPauseGate = AutoMeetingPauseGate()
    private let refreshPauseGate = AutoMeetingPauseGate()
    private let teamsRefreshPauseGate = AutoMeetingPauseGate()
    private let stopPauseGate = AutoMeetingPauseGate()
    private let startLock = NSLock()
    private var startCountStorage = 0
    private let teamsRefreshCountLock = NSLock()
    private var teamsRefreshCountStorage = 0
    private let teamsRefreshConfigurationLock = NSLock()
    private var resumeTeamsRefreshOnCancellationStorage = false
    private let stopLock = NSLock()
    private var stopCountStorage = 0

    func refreshContent() async throws -> [CaptureApplication] {
        _ = await refreshPauseGate.waitIfRequested()
        return []
    }

    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] {
        teamsRefreshCountLock.withLock { teamsRefreshCountStorage += 1 }
        if teamsRefreshPauseGate.isPauseRequested {
            await withTaskCancellationHandler {
                _ = await teamsRefreshPauseGate.waitIfRequested()
            } onCancel: {
                guard self.resumeTeamsRefreshOnCancellation else { return }
                self.resumeTeamsRefresh()
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
        startLock.withLock { startCountStorage += 1 }
        _ = await startPauseGate.waitIfRequested()
        if let startError { throw startError }
    }

    func stop() async {
        stopLock.withLock { stopCountStorage += 1 }
        _ = await stopPauseGate.waitIfRequested()
    }

    func resumeStart() {
        pauseStart = false
    }

    func resumeRefresh() {
        pauseRefresh = false
    }

    func resumeTeamsRefresh() {
        pauseTeamsRefresh = false
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
                repeating: .value(Int64(6) * 1_024 * 1_024 * 1_024),
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
