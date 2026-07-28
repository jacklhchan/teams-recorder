import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelScreenCaptureTests: XCTestCase {
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for suiteName in defaultsSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    func testControlsAppearOnlyForSelectedTeamsApplication() async throws {
        let fixture = makeFixture(provider: .normal)
        XCTAssertFalse(fixture.model.showsTeamsScreenCaptureControls)

        fixture.source.applications = [nonTeamsApplication]
        fixture.model.captureSelection = .init(mode: .selectedApplication, selectedBundleIdentifier: nonTeamsApplication.bundleIdentifier)
        fixture.model.resolvedCaptureSelection = .application(nonTeamsApplication)
        XCTAssertFalse(fixture.model.showsTeamsScreenCaptureControls)

        fixture.source.applications = [teamsApplication]
        fixture.model.captureSelection = .init(mode: .selectedApplication, selectedBundleIdentifier: teamsApplication.bundleIdentifier)
        fixture.model.resolvedCaptureSelection = .application(teamsApplication)

        XCTAssertTrue(fixture.model.showsTeamsScreenCaptureControls)
        XCTAssertTrue(fixture.model.isTeamsScreenCaptureToggleDisabled)
    }

    func testEveryRecordingStartsWithScreenOff() async throws {
        let fixture = makeFixture(provider: .normal, windows: [teamsWindow(id: 1)])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.ready)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.off)
        XCTAssertEqual(fixture.source.videoTargets.last ?? nil, nil)
        XCTAssertEqual(fixture.source.startCount, 1)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.off)
        XCTAssertEqual(fixture.source.videoTargets.last ?? nil, nil)
        XCTAssertEqual(fixture.source.startCount, 2)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        fixture.model.runTestRecording()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.off)
        XCTAssertTrue(fixture.source.videoTargets.compactMap { $0 }.isEmpty)
        XCTAssertEqual(fixture.source.startCount, 3)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testResolverRefreshesEverySecondWhileRecordingOrRequested() async throws {
        let ticker = TeamsScreenTestTicker()
        let fixture = makeFixture(provider: .normal, teamsTicker: ticker, windows: [teamsWindow(id: 2)])
        await selectTeams(in: fixture)
        await waitUntil { fixture.source.teamsRefreshCount >= 1 }
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        let baseline = fixture.source.teamsRefreshCount
        await ticker.fire()
        await waitUntil { fixture.source.teamsRefreshCount == baseline + 1 }
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
        let stoppedAt = fixture.source.teamsRefreshCount
        await ticker.fire()
        await Task.yield()
        XCTAssertEqual(fixture.source.teamsRefreshCount, stoppedAt)
    }

    func testAmbiguityShowsWaitingAndDoesNotCaptureEitherWindow() async throws {
        let first = teamsWindow(id: 3)
        let second = TeamsWindowSnapshot(identity: .init(processID: teamsApplication.processID, windowID: 4), title: "Other call", frame: first.frame, isOnScreen: true, layer: 0)
        let fixture = makeFixture(provider: .normal, windows: [first, second])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.waiting)
        XCTAssertFalse(fixture.source.videoTargets.isEmpty)
        XCTAssertNil(fixture.source.videoTargets.last ?? nil)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testManualSelectionEnablesRequestedCapture() async throws {
        let fixture = makeFixture(provider: .normal, windows: [teamsWindow(id: 5)])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        let candidate = try XCTUnwrap(fixture.model.teamsScreenCaptureCandidates.first)
        await fixture.model.selectTeamsScreenCaptureWindow(candidate.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertEqual(fixture.model.teamsManualWindowIdentity, candidate.identity)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.awaitingFrames)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testManualSelectionFollowsRecreatedWindowOnNextRefresh() async throws {
        let title = "Shared content | Customer presentation"
        let original = teamsWindow(id: 6, title: title)
        let replacement = teamsWindow(id: 27, title: title)
        let fixture = makeFixture(provider: .normal, windows: [original])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.selectTeamsScreenCaptureWindow(original.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)

        fixture.source.windows = [replacement]
        await fixture.model.refreshTeamsScreenCaptureNow()

        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(
            fixture.source.videoTargets.compactMap { $0 }.last,
            replacement.identity
        )
        XCTAssertEqual(fixture.model.teamsManualWindowIdentity, replacement.identity)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testManualSelectionKeepsReplacementIdentityAcrossFilterFailures() async throws {
        let title = "Shared content | Customer presentation"
        let original = teamsWindow(id: 32, title: title)
        let replacement = teamsWindow(id: 33, title: title)
        let fixture = makeFixture(provider: .normal, windows: [original])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.selectTeamsScreenCaptureWindow(original.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)
        fixture.source.videoTargetErrors[2] = StorageTestError.unavailable
        fixture.source.videoTargetErrors[3] = StorageTestError.unavailable

        fixture.source.windows = [replacement]
        await fixture.model.refreshTeamsScreenCaptureNow()

        XCTAssertEqual(fixture.model.teamsManualWindowIdentity, replacement.identity)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.unavailable)

        await fixture.model.refreshTeamsScreenCaptureNow()

        XCTAssertEqual(fixture.source.videoTargets.compactMap { $0 }.last, replacement.identity)
        XCTAssertEqual(fixture.model.teamsManualWindowIdentity, replacement.identity)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.unavailable)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testUnresolvedManualSelectionCannotRevertToPriorResolvedIdentity() async throws {
        let original = teamsWindow(id: 34, title: "Shared content | Presentation A")
        let requested = teamsWindow(id: 35, title: "Shared content | Presentation B")
        let fixture = makeFixture(provider: .normal, windows: [original])
        await selectTeams(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.selectTeamsScreenCaptureWindow(original.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)
        XCTAssertEqual(fixture.model.teamsManualWindowIdentity, original.identity)

        fixture.source.windows = [requested]
        await fixture.model.refreshTeamsScreenCaptureNow()
        XCTAssertTrue(fixture.model.teamsScreenCaptureCandidates.contains {
            $0.identity == requested.identity
        })
        fixture.source.windows = []
        await fixture.model.selectTeamsScreenCaptureWindow(requested.identity)

        XCTAssertEqual(fixture.model.teamsManualWindowIdentity, requested.identity)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.reconnecting)

        fixture.source.windows = [original]
        await fixture.model.refreshTeamsScreenCaptureNow()

        XCTAssertEqual(fixture.model.teamsManualWindowIdentity, requested.identity)
        XCTAssertNil(fixture.source.videoTargets.last ?? nil)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testManualSelectionDoesNotRequireTeamsMeetingAPIState() async throws {
        let window = teamsWindow(id: 31, title: "Shared content | Customer presentation")
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        await fixture.model.selectTeamsScreenCaptureWindow(window.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertEqual(fixture.source.videoTargets.compactMap { $0 }.last, window.identity)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, "Waiting for Teams screen frames")
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testUnavailableSelectedWindowShowsFramesUnavailableInsteadOfMissingWindow() async throws {
        let window = teamsWindow(id: 28, title: "Shared content | Customer presentation")
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.selectTeamsScreenCaptureWindow(window.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)
        let revision = try XCTUnwrap(fixture.source.lastVideoRevision)

        fixture.source.emit(.screenFrameUnavailable(revision))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            fixture.model.teamsScreenStatusText,
            "Teams window found - frames unavailable"
        )
        XCTAssertTrue(fixture.engine.isSystemCaptureConnected)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testRequestedUnavailableScreenCaptureCanBeTurnedOff() async throws {
        let window = teamsWindow(id: 36, title: "Shared content | Customer presentation")
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.selectTeamsScreenCaptureWindow(window.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)
        XCTAssertTrue(fixture.model.isTeamsScreenCaptureRequested)

        let failingUpdate = fixture.source.videoTargets.count + 1
        fixture.source.videoTargetErrors[failingUpdate] = StorageTestError.unavailable
        await fixture.model.refreshTeamsScreenCaptureNow()

        XCTAssertEqual(
            fixture.model.teamsScreenStatusText,
            TeamsScreenStatusText.unavailable
        )
        XCTAssertFalse(fixture.model.isTeamsScreenCaptureToggleDisabled)

        await fixture.model.setTeamsScreenCaptureRequested(false)

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertNil(fixture.source.videoTargets.last ?? nil)
        XCTAssertEqual(
            fixture.model.teamsScreenStatusText,
            TeamsScreenStatusText.off
        )
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testTeamsApplicationDisconnectResetsRequestedScreenCaptureWithoutStoppingAudio() async throws {
        let window = teamsWindow(
            id: 40,
            title: "Shared content | Customer presentation"
        )
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.setTeamsScreenCaptureRequested(true)
        XCTAssertTrue(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(
            fixture.source.videoTargets.compactMap { $0 }.last,
            window.identity
        )

        fixture.source.emit(
            .applicationDisconnected(teamsApplication.bundleIdentifier)
        )
        await waitUntil {
            !fixture.model.isTeamsScreenCaptureRequested
                && (fixture.source.videoTargets.last ?? window.identity) == nil
        }

        XCTAssertFalse(fixture.model.showsTeamsScreenCaptureControls)
        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.stopCount, 0)
        XCTAssertEqual(
            fixture.model.teamsScreenStatusText,
            TeamsScreenStatusText.off
        )

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testRejectedOnAfterDisconnectCannotCancelPendingEngineOffCleanup() async throws {
        let cleanupScheduler = ControlledScreenDisconnectCleanupScheduler()
        let window = teamsWindow(
            id: 41,
            title: "Shared content | Customer presentation"
        )
        let fixture = makeFixture(
            provider: .normal,
            windows: [window],
            disconnectCleanupScheduler: cleanupScheduler.schedule
        )
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.setTeamsScreenCaptureRequested(true)
        XCTAssertTrue(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(
            fixture.source.videoTargets.compactMap { $0 }.last,
            window.identity
        )

        fixture.source.emit(
            .applicationDisconnected(teamsApplication.bundleIdentifier)
        )
        await waitUntil {
            !fixture.model.isTeamsScreenCaptureRequested
                && cleanupScheduler.pendingCount == 1
        }
        XCTAssertEqual(
            fixture.source.videoTargets.compactMap { $0 }.last,
            window.identity
        )

        await fixture.model.setTeamsScreenCaptureRequested(true)
        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        await cleanupScheduler.runNext()

        XCTAssertNil(fixture.source.videoTargets.last ?? nil)
        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.stopCount, 0)
        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testDisconnectCleanupDoesNotReenterCaptureSourceDuringStopFinalization() async throws {
        let cleanupScheduler = ControlledScreenDisconnectCleanupScheduler()
        let window = teamsWindow(
            id: 42,
            title: "Shared content | Customer presentation"
        )
        let fixture = makeFixture(
            provider: .normal,
            windows: [window],
            disconnectCleanupScheduler: cleanupScheduler.schedule
        )
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.setTeamsScreenCaptureRequested(true)

        fixture.source.emit(
            .applicationDisconnected(teamsApplication.bundleIdentifier)
        )
        await waitUntil {
            !fixture.model.isTeamsScreenCaptureRequested
                && cleanupScheduler.pendingCount == 1
        }
        let videoTargetCount = fixture.source.videoTargets.count
        fixture.source.videoTargetErrors[videoTargetCount + 1] =
            StorageTestError.unavailable
        fixture.source.pauseStop = true

        fixture.model.startOrStop()
        await waitUntil { fixture.source.stopCount == 1 }
        XCTAssertTrue(fixture.model.isFinalizingRecording)
        XCTAssertTrue(fixture.model.isCaptureLifecycleWorking)

        await cleanupScheduler.runNext()

        XCTAssertEqual(fixture.source.videoTargets.count, videoTargetCount)
        if case .failed(let message) =
            fixture.engine.meetingScreenCaptureState {
            XCTFail("Disconnect cleanup re-entered capture source: \(message)")
        }
        XCTAssertTrue(fixture.model.isFinalizingRecording)
        XCTAssertTrue(fixture.model.isCaptureLifecycleWorking)
        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.stopCount, 1)

        fixture.source.resumeStop()
        await waitUntil {
            !fixture.engine.isRecording
                && !fixture.model.isCaptureLifecycleWorking
        }
        XCTAssertEqual(fixture.source.stopCount, 1)
    }

    func testStaleOnCannotReenableCaptureAfterNewerOff() async throws {
        let window = teamsWindow(
            id: 37,
            title: "Shared content | Customer presentation"
        )
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        fixture.source.pauseNextTeamsRefresh = true

        let staleOn = Task {
            await fixture.model.setTeamsScreenCaptureRequested(true)
        }
        await fixture.source.waitForPausedTeamsRefresh()
        await fixture.model.setTeamsScreenCaptureRequested(false)
        fixture.source.resumeTeamsRefresh()
        await staleOn.value

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertNil(fixture.source.videoTargets.last ?? nil)
        XCTAssertTrue(fixture.source.videoTargets.compactMap { $0 }.isEmpty)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testNewerOffCancelsBlockedEngineOnWhileReconnectLifecycleIsBusy() async throws {
        let window = teamsWindow(
            id: 39,
            title: "Shared content | Customer presentation"
        )
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        fixture.source.pauseNextVideoTargetUpdate = true

        let staleOn = Task {
            await fixture.model.setTeamsScreenCaptureRequested(true)
        }
        await fixture.source.waitForPausedVideoTargetUpdate()

        fixture.source.emit(
            .applicationDisconnected(teamsApplication.bundleIdentifier)
        )
        await waitUntil { fixture.model.canReconnect }
        fixture.source.pauseReconnect = true
        fixture.model.reconnectSelectedApplication()
        await fixture.source.waitForReconnect()
        XCTAssertTrue(fixture.model.isCaptureLifecycleWorking)

        await fixture.model.setTeamsScreenCaptureRequested(false)
        fixture.source.resumeVideoTargetUpdate()
        await staleOn.value

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertNil(fixture.source.videoTargets.last ?? nil)
        XCTAssertTrue(fixture.engine.isRecording)

        fixture.source.resumeReconnect()
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testOnRejectsActionTimeUnavailableAndFailedStates() async throws {
        let fixture = makeFixture(
            provider: .normal,
            windows: [teamsWindow(id: 38)]
        )
        await selectTeams(in: fixture)

        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertTrue(fixture.source.videoTargets.isEmpty)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        fixture.source.emit(.screenCaptureFailed)
        await waitUntil {
            if case .failed = fixture.engine.meetingScreenCaptureState {
                return true
            }
            return false
        }
        let targetCount = fixture.source.videoTargets.count

        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(fixture.source.videoTargets.count, targetCount)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testLostSelectedWindowShowsReconnectingInsteadOfMissingWindow() async throws {
        let window = teamsWindow(id: 29, title: "Shared content | Customer presentation")
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.selectTeamsScreenCaptureWindow(window.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)
        let revision = try XCTUnwrap(fixture.source.lastVideoRevision)

        fixture.source.emit(.screenTargetLost(revision))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            fixture.model.teamsScreenStatusText,
            "Teams screen changed - reconnecting"
        )
        XCTAssertTrue(fixture.engine.isSystemCaptureConnected)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testLostManualWindowKeepsReconnectingStatusAcrossRefresh() async throws {
        let window = teamsWindow(id: 30, title: "Shared content | Customer presentation")
        let fixture = makeFixture(provider: .normal, windows: [window])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.selectTeamsScreenCaptureWindow(window.identity)
        await fixture.model.setTeamsScreenCaptureRequested(true)
        let revision = try XCTUnwrap(fixture.source.lastVideoRevision)

        fixture.source.emit(.screenTargetLost(revision))
        await Task.yield()
        await Task.yield()
        fixture.source.windows = []
        await fixture.model.refreshTeamsScreenCaptureNow()

        XCTAssertEqual(
            fixture.model.teamsScreenStatusText,
            "Teams screen changed - reconnecting"
        )
        XCTAssertTrue(fixture.engine.isSystemCaptureConnected)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testReplacementWindowUpdatesWithoutWriterRestart() async throws {
        let fixture = makeFixture(provider: .normal, windows: [teamsWindow(id: 6)])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.setTeamsScreenCaptureRequested(true)
        fixture.source.windows = [teamsWindow(id: 7)]
        await fixture.model.refreshTeamsScreenCaptureNow()

        XCTAssertEqual(fixture.source.startCount, 1)
        XCTAssertEqual(fixture.source.videoTargets.last ?? nil, teamsWindow(id: 7).identity)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testScreenRequestDoesNotInventMeetingState() async throws {
        let fixture = makeFixture(provider: .normal, windows: [teamsWindow(id: 10)])
        await selectTeams(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertTrue(fixture.model.isTeamsScreenCaptureRequested)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.waiting)
        XCTAssertFalse(fixture.source.videoTargets.isEmpty)
        XCTAssertTrue(fixture.source.videoTargets.compactMap { $0 }.isEmpty)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testSourceChangeBeforeRecordingClearsManualOverride() async throws {
        let fixture = makeFixture(provider: .normal, windows: [teamsWindow(id: 8)])
        await selectTeams(in: fixture)
        let candidate = try XCTUnwrap(fixture.model.teamsScreenCaptureCandidates.first)
        await fixture.model.selectTeamsScreenCaptureWindow(candidate.identity)
        fixture.model.selectCaptureMode(.allSystemAudio)

        XCTAssertNil(fixture.model.teamsManualWindowIdentity)
        XCTAssertFalse(fixture.model.showsTeamsScreenCaptureControls)
    }

    func testLowStorageDisablesToggleButKeepsAudioStartEnabled() async throws {
        let fixture = makeFixture(provider: StorageCapacityTestProvider(results: [.success(512 * mebibyte)]))
        await selectTeams(in: fixture)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertTrue(fixture.model.isTeamsScreenCaptureToggleDisabled)
        XCTAssertTrue(fixture.engine.isRecording)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testWrongProcessManualIdentityIsRejectedAndSourceChangeCannotRestoreCandidates() async throws {
        let ticker = TeamsScreenTestTicker()
        let fixture = makeFixture(provider: .normal, teamsTicker: ticker, windows: [teamsWindow(id: 9)])
        await selectTeams(in: fixture)
        await waitUntil { fixture.model.teamsScreenCaptureCandidates.count == 1 }
        let wrongProcess = TeamsWindowIdentity(processID: 99, windowID: 9)
        await fixture.model.selectTeamsScreenCaptureWindow(wrongProcess)
        XCTAssertNil(fixture.model.teamsManualWindowIdentity)

        fixture.model.selectCaptureMode(.allSystemAudio)
        await ticker.fire()
        await Task.yield()
        XCTAssertFalse(fixture.model.showsTeamsScreenCaptureControls)
        XCTAssertTrue(fixture.model.teamsScreenCaptureCandidates.isEmpty)
    }

    func testTeamsProcessChangeRequiresFreshMeetingEventBeforeCapture() async throws {
        let fixture = makeFixture(provider: .normal, windows: [teamsWindow(id: 11)])
        await selectTeams(in: fixture)
        await setMeetingActive(in: fixture)
        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.ready)

        let restartedTeams = CaptureApplication(
            processID: 84,
            bundleIdentifier: teamsApplication.bundleIdentifier,
            name: teamsApplication.name
        )
        fixture.source.applications = [restartedTeams]
        fixture.source.windows = [teamsWindow(id: 12, processID: restartedTeams.processID)]
        fixture.model.availableCaptureApplications = [restartedTeams]
        fixture.model.selectCaptureApplication(bundleIdentifier: restartedTeams.bundleIdentifier)
        await waitUntil {
            fixture.model.resolvedCaptureSelection == .application(restartedTeams) &&
                !fixture.model.isCaptureLifecycleWorking
        }

        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.waiting)
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertEqual(fixture.model.teamsScreenStatusText, TeamsScreenStatusText.waiting)
        XCTAssertTrue(fixture.source.videoTargets.compactMap { $0 }.isEmpty)

        let refreshBaseline = fixture.source.teamsRefreshCount
        fixture.teamsClient.emit(.meetingState(.init(
            isInMeeting: true,
            isMuted: false,
            canToggleMute: true,
            canPair: false
        )))
        await waitUntil {
            fixture.source.teamsRefreshCount > refreshBaseline &&
                fixture.model.teamsScreenStatusText == TeamsScreenStatusText.awaitingFrames
        }

        XCTAssertEqual(
            fixture.source.videoTargets.compactMap { $0 }.last?.processID,
            restartedTeams.processID
        )
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testAutomaticSelectionScopesWindowsToSelectedTeamsProcess() async throws {
        let selectedWindow = teamsWindow(id: 13)
        let otherProcessWindow = TeamsWindowSnapshot(
            identity: .init(processID: 84, windowID: 14),
            title: "Old Teams process",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isOnScreen: true,
            layer: 0
        )
        let fixture = makeFixture(
            provider: .normal,
            windows: [otherProcessWindow, selectedWindow]
        )
        await selectTeams(in: fixture)
        let refreshBaseline = fixture.source.teamsRefreshCount
        fixture.teamsClient.emit(.meetingState(.init(
            isInMeeting: true,
            isMuted: false,
            canToggleMute: true,
            canPair: false
        )))
        await waitUntil {
            fixture.source.teamsRefreshCount > refreshBaseline &&
                fixture.model.teamsScreenStatusText == TeamsScreenStatusText.ready
        }

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        await fixture.model.setTeamsScreenCaptureRequested(true)

        XCTAssertEqual(
            fixture.model.teamsScreenCaptureCandidates.map(\.identity),
            [selectedWindow.identity]
        )
        XCTAssertEqual(
            fixture.source.videoTargets.compactMap { $0 }.last,
            selectedWindow.identity
        )
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testPreflightQueriesSelectedOutputFolderBeforeStarting() async throws {
        let provider = StorageCapacityTestProvider(results: [.success(6 * gibibyte)])
        let fixture = makeFixture(provider: provider)
        let selectedFolder = temporaryFolder().appendingPathComponent("External", isDirectory: true)
        fixture.model.setOutputFolder(selectedFolder)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertEqual(provider.queriedURLs, [selectedFolder])
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testPreflightBelowOneGiBStartsAudioButDisablesScreenCapture() async throws {
        let provider = StorageCapacityTestProvider(results: [.success(512 * mebibyte)])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertFalse(fixture.model.isScreenCaptureAllowedByStorage)
        XCTAssertEqual(
            fixture.model.screenCaptureStorageRestrictionReason,
            "Screen capture disabled: less than 1 GB available. Audio recording can continue."
        )
        XCTAssertEqual(fixture.engine.meetingScreenCaptureState, .off)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testPreflightBelowAudioSafetyThresholdRefusesNewRecording() async throws {
        let provider = StorageCapacityTestProvider(results: [.success((256 * mebibyte) - 1)])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil {
            fixture.model.statusMessage == "Recording cannot start: less than 256 MB available."
        }

        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.startCount, 0)
        XCTAssertEqual(
            fixture.model.statusMessage,
            "Recording cannot start: less than 256 MB available."
        )
    }

    func testTestRecordingAlsoPreflightsAndRefusesBelowAudioSafetyThreshold() async throws {
        let provider = StorageCapacityTestProvider(results: [.success((256 * mebibyte) - 1)])
        let fixture = makeFixture(provider: provider)

        fixture.model.runTestRecording()
        await waitUntil {
            fixture.model.statusMessage == "Recording cannot start: less than 256 MB available."
        }

        XCTAssertFalse(fixture.model.isRunningTestRecording)
        XCTAssertEqual(fixture.source.startCount, 0)
    }

    func testProviderErrorWarnsButAllowsRecording() async throws {
        let provider = StorageCapacityTestProvider(results: [.failure(StorageTestError.unavailable)])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertTrue(fixture.model.isScreenCaptureAllowedByStorage)
        XCTAssertEqual(
            fixture.model.storageWarningMessage,
            "Storage check unavailable: unavailable. Recording can continue."
        )

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testRuntimeAudioOnlyDisablesScreenButKeepsAudioRecording() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .success(512 * mebibyte)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await waitUntil { !fixture.model.isScreenCaptureAllowedByStorage }

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.engine.meetingScreenCaptureState, .off)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testRuntimeBelowAudioSafetyThresholdUsesNormalStopLifecycle() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .success((256 * mebibyte) - 1)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await waitUntil { !fixture.engine.isRecording }

        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertTrue(fixture.model.statusMessage.hasPrefix("Recording saved:"))
    }

    func testRuntimeProviderErrorWarnsAndKeepsRecording() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .failure(StorageTestError.unavailable)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await waitUntil {
            fixture.model.storageWarningMessage == "Storage check unavailable: unavailable. Recording can continue."
        }

        XCTAssertTrue(fixture.engine.isRecording)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testChangingOutputFolderDuringPreflightCannotStartOnUncheckedVolume() async throws {
        let provider = StorageCapacityTestProvider(results: [
            .blocked(.success(6 * gibibyte))
        ])
        let fixture = makeFixture(provider: provider)
        let originalFolder = temporaryFolder().appendingPathComponent("Original", isDirectory: true)
        let replacementFolder = temporaryFolder().appendingPathComponent("Replacement", isDirectory: true)
        fixture.model.setOutputFolder(originalFolder)

        fixture.model.startOrStop()
        await provider.waitForBlockedRequest()
        fixture.model.setOutputFolder(replacementFolder)
        provider.resumeBlockedRequest()
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.startCount, 0)
        XCTAssertEqual(provider.queriedURLs, [originalFolder])
        XCTAssertEqual(
            fixture.model.statusMessage,
            "Output folder changed. Start recording again."
        )
    }

    func testLateOldStorageResultCannotStopNewRecordingOrReplaceItsStatus() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .blocked(.success((256 * mebibyte) - 1)),
            .success(6 * gibibyte)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await provider.waitForBlockedRequest()

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { fixture.model.statusMessage == "Recording" }
        XCTAssertEqual(fixture.model.statusMessage, "Recording")

        provider.resumeBlockedRequest()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.model.statusMessage, "Recording")

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testNewRecordingResetsStorageScreenAllowanceAfterPriorAudioOnlyRecording() async throws {
        let provider = StorageCapacityTestProvider(results: [
            .success(512 * mebibyte),
            .success(6 * gibibyte)
        ])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        XCTAssertFalse(fixture.model.isScreenCaptureAllowedByStorage)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertTrue(fixture.model.isScreenCaptureAllowedByStorage)
        XCTAssertNil(fixture.model.screenCaptureStorageRestrictionReason)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    private func makeFixture(
        provider: StorageCapacityTestProvider,
        ticker: StorageTestTicker = StorageTestTicker(),
        teamsTicker: TeamsScreenTestTicker = TeamsScreenTestTicker(),
        windows: [TeamsWindowSnapshot] = [],
        disconnectCleanupScheduler: @escaping (
            @escaping @MainActor @Sendable () async -> Void
        ) -> Void = { operation in
            Task { @MainActor in await operation() }
        }
    ) -> StorageFixture {
        let source = StorageTestCaptureSource()
        source.windows = windows
        source.applications = [teamsApplication]
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in StorageTestWriter() },
            mixerBlockFrames: 4
        )
        let suiteName = "AppModelScreenCaptureTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let teamsClient = ScreenTestTeamsClient()
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
            teamsMuteSyncClient: teamsClient,
            permissionRequestHandler: { _, _ in },
            volumeCapacityProvider: provider,
            storagePolicy: RecordingStoragePolicy(),
            storageMonitorTick: { await ticker.waitForTick() },
            teamsScreenRefreshTick: { await teamsTicker.waitForTick() },
            teamsScreenDisconnectCleanupScheduler:
                disconnectCleanupScheduler
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        model.installTeamsMuteSync()
        return StorageFixture(
            model: model,
            engine: engine,
            source: source,
            teamsClient: teamsClient,
            defaults: defaults
        )
    }

    private var teamsApplication: CaptureApplication {
        CaptureApplication(processID: 42, bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams")
    }

    private var nonTeamsApplication: CaptureApplication {
        CaptureApplication(processID: 43, bundleIdentifier: "com.example.other", name: "Other")
    }

    private func teamsWindow(
        id: CGWindowID,
        processID: pid_t = 42,
        title: String? = nil
    ) -> TeamsWindowSnapshot {
        TeamsWindowSnapshot(
            identity: .init(processID: processID, windowID: id),
            title: title ?? "Teams call \(id)",
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            isOnScreen: true,
            layer: 0
        )
    }

    private func selectTeams(in fixture: StorageFixture) async {
        fixture.source.applications = [teamsApplication]
        fixture.model.availableCaptureApplications = [teamsApplication]
        fixture.model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: teamsApplication.bundleIdentifier
        )
        fixture.model.resolvedCaptureSelection = .application(teamsApplication)
        await fixture.model.refreshTeamsScreenCaptureNow()
    }

    private func setMeetingActive(in fixture: StorageFixture) async {
        let refreshBaseline = fixture.source.teamsRefreshCount
        fixture.teamsClient.emit(.meetingState(.init(
            isInMeeting: true,
            isMuted: false,
            canToggleMute: true,
            canPair: false
        )))
        await waitUntil {
            guard fixture.source.teamsRefreshCount > refreshBaseline else { return false }
            switch fixture.engine.meetingScreenCaptureState {
            case .ready:
                return fixture.source.windows.count == 1
            case .waiting(let descriptors):
                return descriptors.count == fixture.source.windows.count
            default:
                return false
            }
        }
    }

    private func temporaryFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        if condition() { return }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    private let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    private let mebibyte: Int64 = 1_024 * 1_024
}

private final class ControlledScreenDisconnectCleanupScheduler:
    @unchecked Sendable
{
    typealias Operation = @MainActor @Sendable () async -> Void

    private let lock = NSLock()
    private var operations: [Operation] = []

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return operations.count
    }

    func schedule(_ operation: @escaping Operation) {
        lock.lock()
        operations.append(operation)
        lock.unlock()
    }

    @MainActor
    func runNext() async {
        await takeNext()?()
    }

    private func takeNext() -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        return operations.isEmpty ? nil : operations.removeFirst()
    }
}

private struct StorageFixture {
    let model: AppModel
    let engine: RecordingEngine
    let source: StorageTestCaptureSource
    let teamsClient: ScreenTestTeamsClient
    let defaults: UserDefaults
}

private enum StorageTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "unavailable" }
}

private final class StorageCapacityTestProvider: VolumeCapacityProviding, @unchecked Sendable {
    enum Result {
        case success(Int64)
        case failure(Error)
        case blocked(Swift.Result<Int64, Error>)
    }

    private let lock = NSLock()
    private var results: [Result]
    private var blockedSemaphore: DispatchSemaphore?
    private let blockedRequestSemaphore = DispatchSemaphore(value: 0)
    private(set) var queriedURLs: [URL] = []

    init(results: [Result]) {
        self.results = results
    }

    static var normal: StorageCapacityTestProvider {
        StorageCapacityTestProvider(results: Array(repeating: .success(6 * 1_024 * 1_024 * 1_024), count: 20))
    }

    func availableBytes(onVolumeContaining url: URL) throws -> Int64 {
        lock.lock()
        queriedURLs.append(url)
        let result = results.removeFirst()
        if case .blocked = result {
            let semaphore = DispatchSemaphore(value: 0)
            blockedSemaphore = semaphore
            lock.unlock()
            blockedRequestSemaphore.signal()
            semaphore.wait()
        } else {
            lock.unlock()
        }

        switch result {
        case .success(let bytes): return bytes
        case .failure(let error): throw error
        case .blocked(let result): return try result.get()
        }
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

private actor StorageTestTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
            return
        }
        await withCheckedContinuation { continuations.append($0) }
    }

    func fire() {
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }
    }
}

private actor TeamsScreenTestTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
            return
        }
        await withCheckedContinuation { continuations.append($0) }
    }

    func fire() {
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }
    }
}

private final class StorageTestCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: 0)
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var teamsRefreshCount = 0
    var windows: [TeamsWindowSnapshot] = []
    var applications: [CaptureApplication] = []
    var videoTargetErrors: [Int: Error] = [:]
    var pauseNextTeamsRefresh = false
    var pauseNextVideoTargetUpdate = false
    var pauseReconnect = false
    var pauseStop = false
    private(set) var videoTargets: [TeamsWindowIdentity?] = []
    private var onEvent: ((CaptureEvent) -> Void)?
    private var teamsRefreshContinuation: CheckedContinuation<Void, Never>?
    private var teamsRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var videoTargetContinuation: CheckedContinuation<Void, Never>?
    private var videoTargetWaiters: [CheckedContinuation<Void, Never>] = []
    private var reconnectContinuation: CheckedContinuation<Void, Never>?
    private var reconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?

    var lastVideoRevision: CaptureFilterRevision? {
        guard !videoTargets.isEmpty else { return nil }
        return .init(sessionGeneration: 0, revision: UInt64(videoTargets.count))
    }

    func refreshContent() async throws -> [CaptureApplication] { applications }
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] {
        teamsRefreshCount += 1
        if pauseNextTeamsRefresh {
            teamsRefreshWaiters.forEach { $0.resume() }
            teamsRefreshWaiters.removeAll()
            await withCheckedContinuation { teamsRefreshContinuation = $0 }
        }
        return windows
    }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {
        if pauseReconnect {
            reconnectWaiters.forEach { $0.resume() }
            reconnectWaiters.removeAll()
            await withCheckedContinuation { reconnectContinuation = $0 }
        }
    }
    func updateVideoTarget(_ target: TeamsWindowIdentity?) async throws -> CaptureFilterRevision {
        videoTargets.append(target)
        if pauseNextVideoTargetUpdate {
            pauseNextVideoTargetUpdate = false
            videoTargetWaiters.forEach { $0.resume() }
            videoTargetWaiters.removeAll()
            await withCheckedContinuation { videoTargetContinuation = $0 }
        }
        if let error = videoTargetErrors[videoTargets.count] {
            throw error
        }
        return .init(sessionGeneration: 0, revision: UInt64(videoTargets.count))
    }
    func start(
        selection _: ResolvedCaptureSelection,
        microphoneUID _: String?,
        onAudio _: @escaping (AudioFrameBlock) -> Void,
        onVideo _: @escaping (ScreenVideoFrame) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws {
        startCount += 1
        self.onEvent = onEvent
    }
    func stop() async {
        stopCount += 1
        if pauseStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
    }

    func waitForPausedTeamsRefresh() async {
        if teamsRefreshContinuation != nil { return }
        await withCheckedContinuation { teamsRefreshWaiters.append($0) }
    }

    func resumeTeamsRefresh() {
        pauseNextTeamsRefresh = false
        teamsRefreshContinuation?.resume()
        teamsRefreshContinuation = nil
    }

    func waitForPausedVideoTargetUpdate() async {
        if videoTargetContinuation != nil { return }
        await withCheckedContinuation { videoTargetWaiters.append($0) }
    }

    func resumeVideoTargetUpdate() {
        videoTargetContinuation?.resume()
        videoTargetContinuation = nil
    }

    func waitForReconnect() async {
        if reconnectContinuation != nil { return }
        await withCheckedContinuation { reconnectWaiters.append($0) }
    }

    func resumeReconnect() {
        pauseReconnect = false
        reconnectContinuation?.resume()
        reconnectContinuation = nil
    }

    func resumeStop() {
        pauseStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func emit(_ event: CaptureEvent) {
        onEvent?(event)
    }
}

private final class ScreenTestTeamsClient: TeamsMuteSyncing {
    private var onEvent: ((TeamsMuteSyncEvent) -> Void)?

    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void) {
        self.onEvent = onEvent
    }

    func stop() {
        onEvent = nil
    }

    func reconnect() {}
    func requestPairing() {}

    func emit(_ event: TeamsMuteSyncEvent) {
        onEvent?(event)
    }
}

private final class StorageTestWriter: MixedAudioWriting {
    func write(_: MixedAudioBlock) throws {}
    func close() throws {}
}
