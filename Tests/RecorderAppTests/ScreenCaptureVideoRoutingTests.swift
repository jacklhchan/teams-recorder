import CoreVideo
import ScreenCaptureKit
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

    func testTeamsScreenTargetMustMatchSelectedProcess() {
        XCTAssertTrue(SelectedTeamsScreenTargetPlan.accepts(nil, selected: teams))
        XCTAssertTrue(SelectedTeamsScreenTargetPlan.accepts(
            .init(processID: teams.processID, windowID: 9),
            selected: teams
        ))
        XCTAssertFalse(SelectedTeamsScreenTargetPlan.accepts(
            .init(processID: 84, windowID: 9),
            selected: teams
        ))
        XCTAssertFalse(SelectedTeamsScreenTargetPlan.accepts(nil, selected: nonTeams))
    }

    func testTeamsWindowFilterRequiresWindowProcessAndBundleIdentity() {
        let identity = TeamsWindowIdentity(processID: teams.processID, windowID: 9)

        XCTAssertTrue(TeamsWindowFilterMatchPlan.accepts(
            identity,
            windowID: identity.windowID,
            ownerProcessID: identity.processID,
            ownerBundleIdentifier: teams.bundleIdentifier
        ))
        XCTAssertFalse(TeamsWindowFilterMatchPlan.accepts(
            identity,
            windowID: identity.windowID,
            ownerProcessID: identity.processID,
            ownerBundleIdentifier: "com.example.not-teams"
        ))
        XCTAssertFalse(TeamsWindowFilterMatchPlan.accepts(
            identity,
            windowID: 10,
            ownerProcessID: identity.processID,
            ownerBundleIdentifier: teams.bundleIdentifier
        ))
        XCTAssertFalse(TeamsWindowFilterMatchPlan.accepts(
            identity,
            windowID: identity.windowID,
            ownerProcessID: 84,
            ownerBundleIdentifier: teams.bundleIdentifier
        ))
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

    func testNV12FallsBackToBGRAOnlyForExplicitStartCapturePixelFormatFailure() {
        let invalidPixelFormat = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kCVReturnInvalidPixelFormat)
        )

        XCTAssertEqual(
            ScreenCaptureStartupRetryPolicy.fallback(
                after: invalidPixelFormat,
                stage: .streamStart,
                attemptedPixelFormat: .nv12
            ),
            .bgra
        )
        XCTAssertNil(ScreenCaptureStartupRetryPolicy.fallback(
            after: invalidPixelFormat,
            stage: .outputRegistration,
            attemptedPixelFormat: .nv12
        ))
        XCTAssertNil(ScreenCaptureStartupRetryPolicy.fallback(
            after: NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.Code.failedToStart.rawValue
            ),
            stage: .streamStart,
            attemptedPixelFormat: .nv12
        ))
        XCTAssertNil(ScreenCaptureStartupRetryPolicy.fallback(
            after: invalidPixelFormat,
            stage: .streamStart,
            attemptedPixelFormat: .bgra
        ))
    }

    func testStartupRetryFindsExplicitPixelFormatFailureInUnderlyingError() {
        let invalidPixelFormat = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kCVReturnInvalidPixelFormat)
        )
        let wrapped = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedToStart.rawValue,
            userInfo: [NSUnderlyingErrorKey: invalidPixelFormat]
        )

        XCTAssertEqual(
            ScreenCaptureStartupRetryPolicy.fallback(
                after: wrapped,
                stage: .streamStart,
                attemptedPixelFormat: .nv12
            ),
            .bgra
        )
    }

    func testStartupRetryNeverMasksPermissionFailure() {
        let invalidPixelFormat = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kCVReturnInvalidPixelFormat)
        )
        let permissionFailure = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue,
            userInfo: [NSUnderlyingErrorKey: invalidPixelFormat]
        )

        XCTAssertNil(ScreenCaptureStartupRetryPolicy.fallback(
            after: permissionFailure,
            stage: .streamStart,
            attemptedPixelFormat: .nv12
        ))
    }

    func testStartupRetryRejectsGenericOuterWrapper() {
        let invalidPixelFormat = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kCVReturnInvalidPixelFormat)
        )
        let genericWrapper = NSError(
            domain: "com.example.capture",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: invalidPixelFormat]
        )

        XCTAssertNil(ScreenCaptureStartupRetryPolicy.fallback(
            after: genericWrapper,
            stage: .streamStart,
            attemptedPixelFormat: .nv12
        ))
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

    func testFirstFailedTransitionReopensStartupApplicationRevision() {
        var state = ScreenCaptureRoutingState(
            initialRevision: CaptureFilterCoordinator.startupRevision
        )

        state.beginTransition()
        XCTAssertNil(state.videoRevision)
        state.restoreAfterVideoBarrier()

        XCTAssertEqual(
            state.videoRevision,
            CaptureFilterCoordinator.startupRevision
        )
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
            CaptureStatusMapper.status(for: .screenTargetLost(.init(
                sessionGeneration: 1,
                revision: 1
            ))),
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
