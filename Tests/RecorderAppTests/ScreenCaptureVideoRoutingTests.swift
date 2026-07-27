import CoreVideo
import XCTest
@testable import RecorderApp

final class ScreenCaptureVideoRoutingTests: XCTestCase {
    func testTeamsStreamRegistersAudioMicrophoneAndScreenOutputs() {
        let plan = ScreenCaptureRoutingPlan(isSelectedApplication: true)

        XCTAssertEqual(plan.outputs, [.audio, .microphone, .screen])
    }

    func testNonTeamsStreamDoesNotDeliverRealScreenFrames() {
        let plan = ScreenCaptureRoutingPlan(isSelectedApplication: false)

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

    func testNV12IsPreferredAndBGRAIsTheOnlyFallback() {
        var attempts = ScreenCaptureStartupAttemptSequence()

        XCTAssertEqual(attempts.next(), .nv12)
        XCTAssertEqual(attempts.next(), .bgra)
        XCTAssertNil(attempts.next())
    }

    func testVideoUsesAQueueSeparateFromAudioDelivery() {
        let plan = ScreenCaptureRoutingPlan(isSelectedApplication: true)

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
        let plan = ScreenCaptureRoutingPlan(isSelectedApplication: true)

        XCTAssertEqual(plan.outputsToRemoveOnStop, [.audio, .microphone, .screen])
        XCTAssertTrue(plan.drainsVideoBeforeRemovingOutputs)
    }

    private let teams = CaptureApplication(
        processID: 7,
        bundleIdentifier: "com.microsoft.teams2",
        name: "Teams"
    )
}
