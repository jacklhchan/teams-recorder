import CoreVideo
import XCTest
@testable import RecorderApp

final class ScreenCaptureVideoRoutingTests: XCTestCase {
    func testTeamsStreamRegistersAudioMicrophoneAndScreenOutputs() {
        let plan = ScreenCaptureRoutingPlan(application: teams)

        XCTAssertEqual(plan.outputs, [.audio, .microphone, .screen])
    }

    func testNonTeamsStreamDoesNotDeliverRealScreenFrames() {
        let plan = ScreenCaptureRoutingPlan(application: nonTeams)

        XCTAssertEqual(plan.outputs, [.audio, .microphone])
        XCTAssertFalse(plan.acceptsScreenFrames)
    }
    func testProductionScreenConfigurationIsFixedStorageProfile() {
        let source = ScreenCaptureSource()

        XCTAssertEqual(source.screenVideoFormat.width, 1_600)
        XCTAssertEqual(source.screenVideoFormat.height, 900)
        XCTAssertEqual(
            source.screenVideoFormat.pixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testActiveStartupFallbackFormatOverridesPreferredFormatOnlyForActiveSession() {
        var state = ScreenCaptureRoutingState()
        XCTAssertEqual(state.activePixelFormat, .nv12)

        state.adoptStartupFormat(.bgra)

        XCTAssertEqual(state.activePixelFormat, .bgra)
    }

    func testNV12IsPreferredAndBGRAIsTheOnlyFallback() {
        var attempts = ScreenCaptureStartupAttemptSequence()

        XCTAssertEqual(attempts.next(), .nv12)
        XCTAssertEqual(attempts.next(), .bgra)
        XCTAssertNil(attempts.next())
    }

    func testVideoUsesAQueueSeparateFromAudioDelivery() {
        let plan = ScreenCaptureRoutingPlan(application: teams)

        XCTAssertNotEqual(plan.audioQueueLabel, plan.videoQueueLabel)
    }

    func testFilterRevisionChangesOnlyAfterVideoQueueBarrier() {
        var gate = ScreenCaptureRevisionGate()
        let revision = CaptureFilterRevision(sessionGeneration: 1, revision: 1)

        gate.begin(revision)
        XCTAssertNil(gate.commitIfBarrierFinished())
        gate.finishVideoBarrier()
        XCTAssertEqual(gate.commitIfBarrierFinished(), revision)
    }

    func testTransitionBlocksNewFilterFramesUntilBarrierCommit() {
        var state = ScreenCaptureRoutingState()
        let old = CaptureFilterRevision(sessionGeneration: 1, revision: 1)
        let new = CaptureFilterRevision(sessionGeneration: 1, revision: 2)
        state.publish(old)
        state.beginTransition()

        XCTAssertNil(state.videoRevision)
        state.publishAfterVideoBarrier(new)
        XCTAssertEqual(state.videoRevision, new)
    }

    func testFailedTransitionReopensOnlyPriorCommittedRevisionAfterRestoreBarrier() {
        var state = ScreenCaptureRoutingState()
        let old = CaptureFilterRevision(sessionGeneration: 1, revision: 1)
        state.publish(old)
        state.beginTransition()

        XCTAssertNil(state.videoRevision)
        state.restoreAfterVideoBarrier()
        XCTAssertEqual(state.videoRevision, old)
    }

    func testFilterAndFrameCadenceCommitAsOneRevision() {
        var coordinator = CaptureFilterCoordinator()
        let enabled = CaptureStreamIntent(
            filter: .teamsWindow(.init(processID: 7, windowID: 9)),
            cadence: .enabled
        )

        let update = coordinator.request(enabled)
        XCTAssertEqual(update?.intent.cadence, .enabled)
        XCTAssertNil(coordinator.complete(update!, result: .success(())))
    }

    func testOverlappingDisableReconnectEnableEndsAtNewestFilterAndTenFPS() {
        var coordinator = CaptureFilterCoordinator()
        let application = CaptureStreamIntent(
            filter: .application(teams),
            cadence: .idle
        )
        let first = coordinator.request(application)!
        let enabled = CaptureStreamIntent(
            filter: .teamsWindow(.init(processID: 7, windowID: 9)),
            cadence: .enabled
        )
        XCTAssertNil(coordinator.request(application))
        XCTAssertNil(coordinator.request(enabled))

        let next = coordinator.complete(first, result: .success(()))
        XCTAssertEqual(next?.intent, enabled)
        XCTAssertEqual(next?.intent.cadence.framesPerSecond, 10)
    }

    func testVideoFailureDoesNotUseAudioDisconnectEvent() {
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .screenCaptureFailed),
            .warning("Screen frame capture unavailable")
        )
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .screenTargetLost),
            .warning("Teams screen target was closed")
        )
    }

    func testStopDrainsAndRemovesAllThreeOutputs() {
        let plan = ScreenCaptureRoutingPlan(application: teams)

        XCTAssertEqual(plan.outputsToRemoveOnStop, [.audio, .microphone, .screen])
        XCTAssertTrue(plan.drainsVideoBeforeRemovingOutputs)
    }

    private let teams = CaptureApplication(
        processID: 7,
        bundleIdentifier: "com.microsoft.teams2",
        name: "Teams"
    )
    private let nonTeams = CaptureApplication(
        processID: 8,
        bundleIdentifier: "com.example.player",
        name: "Player"
    )
}
