import Foundation
import XCTest
@testable import RecorderApp

final class TeamsCaptureViabilityReportTests: XCTestCase {
    func testLiveReportFromEnvironmentPassesWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "TEAMS_CAPTURE_VIABILITY_REPORT"
        ] else {
            throw XCTSkip("Set TEAMS_CAPTURE_VIABILITY_REPORT to evaluate live evidence.")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let report = try JSONDecoder().decode(
            TeamsCaptureViabilityReport.self,
            from: data
        )
        let failures = TeamsCaptureViabilityEvaluator.failures(in: report)

        XCTAssertTrue(
            failures.isEmpty,
            "Live report evaluator failures:\n\(failures.joined(separator: "\n"))"
        )
    }

    func testReportPassesOnlyWhenOneStreamPreservesAllThreeMediaOutputs() {
        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: passingReport).isEmpty)
    }

    func testReportFailsWhenWindowFilterLosesTeamsAudio() {
        var report = passingReport
        report.windowFilterDwells[0] = dwell(nonSilentSystemBufferCount: 0)

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("system audio")
        })
    }

    func testReportFailsWhenOnlyApplicationFilterHasMicrophoneAudio() {
        var report = passingReport
        report.windowFilterDwells[0] = dwell(nonSilentMicrophoneBufferCount: 0)

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("microphone audio")
        })
    }

    func testReportFailsWhenAnyWindowDwellLacksItsOwnCompleteFrame() {
        var report = passingReport
        report.windowFilterDwells[0] = dwell(completeScreenFrameCount: 9, capturedFramePNG: nil)

        let failures = TeamsCaptureViabilityEvaluator.failures(in: report)
        XCTAssertTrue(failures.contains { $0.contains("complete frames") })
        XCTAssertTrue(failures.contains { $0.contains("PNG") })
    }

    func testReportFailsWhenFilterUpdateRecreatesTheStream() {
        var report = passingReport
        report.streamIdentities.insert("stream-recreated")

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("exactly one stream identity")
        })
    }

    func testReportFailsWhenApplicationBaselineUsesAnotherStreamIdentity() {
        var report = passingReport
        report.applicationBaseline = dwell(
            filterRevision: 0,
            windowID: nil,
            streamIdentity: "baseline-recreated"
        )

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("application baseline stream identity")
        })
    }

    func testReportFailsWhenAnyWindowDwellUsesAnotherStreamIdentity() {
        var report = passingReport
        report.windowFilterDwells[0] = dwell(streamIdentity: "window-recreated")

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("window dwell stream identity")
        })
    }

    func testReportFailsWhenThereAreTooFewFilterTransitions() {
        var report = passingReport
        report.filterTransitionCount = 3

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("at least four")
        })
    }

    func testReportFailsWhenAudioPTSHasAnUnexplainedGap() {
        var report = passingReport
        report.windowFilterDwells[0] = dwell(maximumMicrophonePTSGap: 0.251)

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("microphone PTS gap")
        })
    }

    func testCycleCounterRequiresFourCompleteApplicationWindowApplicationRoundTrips() {
        var counter = TeamsCaptureViabilityCycleCounter()

        for windowID: UInt32 in [10, 20, 30, 40] {
            XCTAssertTrue(counter.shouldUpdateFilter(to: .window(windowID)))
            counter.recordSuccessfulSelection(.window(windowID))
            XCTAssertTrue(counter.shouldUpdateFilter(to: .application))
            counter.recordSuccessfulSelection(.application)
        }

        XCTAssertEqual(counter.completedRoundTrips, 4)
    }

    func testCycleCounterIgnoresRepeatedSelectionsAndWindowReplacement() {
        var counter = TeamsCaptureViabilityCycleCounter()

        XCTAssertFalse(counter.shouldUpdateFilter(to: .application))
        counter.recordSuccessfulSelection(.window(10))
        XCTAssertFalse(counter.shouldUpdateFilter(to: .window(10)))
        XCTAssertTrue(counter.shouldUpdateFilter(to: .window(11)))
        counter.recordSuccessfulSelection(.window(11))
        XCTAssertEqual(counter.completedRoundTrips, 0)
        counter.recordSuccessfulSelection(.application)
        XCTAssertEqual(counter.completedRoundTrips, 1)
        XCTAssertFalse(counter.shouldUpdateFilter(to: .application))
    }

    func testCrossRevisionGapUsesPriorBufferEndAndFailsNewWindowDwell() {
        var tracker = TeamsCaptureViabilityPTSTracker(source: .system)
        _ = tracker.observe(
            startPTS: 10,
            duration: 0.020,
            filterRevision: 0
        )

        let observation = tracker.observe(
            startPTS: 10.400,
            duration: 0.020,
            filterRevision: 1
        )

        XCTAssertEqual(observation.filterRevision, 1)
        XCTAssertEqual(observation.unexplainedGap, 0.380, accuracy: 0.000_001)
        var report = passingReport
        report.windowFilterDwells[0] = dwell(
            maximumSystemPTSGap: observation.unexplainedGap
        )
        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("system PTS gap")
        })
    }

    func testInvalidPTSRecordsDiagnosticWithoutClearingPriorEnd() {
        var tracker = TeamsCaptureViabilityPTSTracker(source: .microphone)
        _ = tracker.observe(startPTS: 5, duration: 0.100, filterRevision: 0)

        let invalid = tracker.observe(
            startPTS: nil,
            duration: 0.100,
            filterRevision: 1
        )
        let recovered = tracker.observe(
            startPTS: 5.500,
            duration: 0.100,
            filterRevision: 1
        )

        XCTAssertTrue(invalid.diagnostic?.contains("Invalid microphone PTS") == true)
        XCTAssertEqual(recovered.unexplainedGap, 0.400, accuracy: 0.000_001)
    }

    func testReportFailsWhenAudioTimingCouldNotBeMeasured() {
        var report = passingReport
        report.notes = [
            "Audio timing diagnostic: Invalid microphone PTS at filter revision 1."
        ]

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("audio timing diagnostic")
        })
    }

    func testReportFailsWhenGateFailureEvidenceExists() {
        var report = passingReport
        report.notes = [
            "Gate failure: updateContentFilter target=window(42) revision=2 error=denied"
        ]

        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("gate failure")
        })
    }

    func testFilterUpdateFailureEvidenceIncludesTargetRevisionAndError() {
        XCTAssertEqual(
            TeamsCaptureViabilityGateFailure.filterUpdate(
                target: .window(42),
                attemptedRevision: 2,
                errorDescription: "denied"
            ),
            "Gate failure: updateContentFilter target=window(42) revision=2 error=denied"
        )
    }

    func testEvidenceFinalizationWaitsForFilterUpdateAndSchedulesOnce() {
        var coordinator = TeamsCaptureViabilityEvidenceFinalizationCoordinator()

        XCTAssertTrue(coordinator.beginFilterUpdate())
        XCTAssertFalse(coordinator.requestFinalization())
        XCTAssertTrue(coordinator.finishFilterUpdate())
        XCTAssertFalse(coordinator.requestFinalization())
    }

    func testEvidenceFinalizationWaitsForStopRequestOutcome() {
        var coordinator = TeamsCaptureViabilityEvidenceFinalizationCoordinator()

        XCTAssertTrue(coordinator.beginStopRequest())
        XCTAssertFalse(coordinator.requestFinalization())
        XCTAssertTrue(coordinator.finishStopRequest())
        XCTAssertFalse(coordinator.finishStopRequest())
    }

    func testStopFailureRequiresGateEvidenceDetachmentAndFinalization() {
        let plan = TeamsCaptureViabilityStopFailurePlan.make(
            errorDescription: "transport lost"
        )

        XCTAssertEqual(
            plan.gateFailureNote,
            "Gate failure: stopCapture error=transport lost"
        )
        XCTAssertTrue(plan.shouldDetachOutputs)
        XCTAssertTrue(plan.shouldRetireActiveStream)
        XCTAssertTrue(plan.shouldFinalizeEvidence)

        var report = passingReport
        report.notes = [plan.gateFailureNote]
        XCTAssertFalse(TeamsCaptureViabilityEvaluator.failures(in: report).isEmpty)
    }

    func testAudioDurationPrefersFrameCountAndSampleRateThenValidDuration() throws {
        XCTAssertEqual(
            try XCTUnwrap(
                TeamsCaptureViabilityAudioTiming.duration(
                    sampleCount: 480,
                    sampleRate: 48_000,
                    validBufferDuration: 99
                )
            ),
            0.010,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                TeamsCaptureViabilityAudioTiming.duration(
                    sampleCount: 0,
                    sampleRate: nil,
                    validBufferDuration: 0.020
                )
            ),
            0.020,
            accuracy: 0.000_001
        )
        XCTAssertNil(
            TeamsCaptureViabilityAudioTiming.duration(
                sampleCount: 0,
                sampleRate: nil,
                validBufferDuration: .nan
            )
        )
    }

    func testOwnedPCMMeasurementComputesFiniteRMSAcrossChannels() {
        let pcm = OwnedPCMBuffer(
            sampleRate: 48_000,
            channels: [[1, -1], [0.5, -0.5]]
        )

        XCTAssertEqual(
            TeamsCaptureViabilityAudioMeasurement.rms(in: pcm),
            0.790_569_415,
            accuracy: 0.000_001
        )
    }

    func testStartupAttemptsNV12ThenBGRAExactlyOnce() {
        var attempts = TeamsCaptureViabilityStartupAttemptSequence()

        XCTAssertEqual(attempts.next(), .nv12)
        XCTAssertEqual(attempts.next(), .bgra)
        XCTAssertNil(attempts.next())
    }

    func testLifecycleDoesNotCaptureUntilStartupSucceeds() {
        var lifecycle = TeamsCaptureViabilityLifecycleCoordinator()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertFalse(lifecycle.isCapturing)
        lifecycle.startSucceeded()
        XCTAssertTrue(lifecycle.isCapturing)
    }

    func testLifecycleAllowsEvidenceFinalizationExactlyOnce() {
        var lifecycle = TeamsCaptureViabilityLifecycleCoordinator()
        XCTAssertTrue(lifecycle.beginStart())
        lifecycle.startSucceeded()

        XCTAssertTrue(lifecycle.requestFinalization())
        XCTAssertFalse(lifecycle.isCapturing)
        XCTAssertFalse(lifecycle.requestFinalization())
        lifecycle.finishFinalization()
        XCTAssertFalse(lifecycle.requestFinalization())
    }

    func testStoppedStartupCandidateCannotBeAdoptedAndNextGenerationCanStart() throws {
        var lifecycle = TeamsCaptureViabilityLifecycleCoordinator()
        XCTAssertTrue(lifecycle.beginStart())
        let nv12Generation = try XCTUnwrap(lifecycle.registerStartupCandidate())

        XCTAssertEqual(
            lifecycle.recordDelegateStop(
                generation: nv12Generation,
                errorDescription: "NV12 callback stopped"
            ),
            .startupCandidate
        )
        XCTAssertFalse(
            lifecycle.adoptStartupCandidate(generation: nv12Generation)
        )
        XCTAssertEqual(
            lifecycle.startupCandidateFailure(generation: nv12Generation),
            "NV12 callback stopped"
        )

        lifecycle.clearStartupCandidate(generation: nv12Generation)
        let bgraGeneration = try XCTUnwrap(lifecycle.registerStartupCandidate())
        XCTAssertNotEqual(bgraGeneration, nv12Generation)
        XCTAssertTrue(
            lifecycle.adoptStartupCandidate(generation: bgraGeneration)
        )
        XCTAssertTrue(
            lifecycle.shouldPublishCapturing(generation: bgraGeneration)
        )
        XCTAssertFalse(
            lifecycle.shouldPublishCapturing(generation: nv12Generation)
        )
    }

    func testQueuedStartupSuccessCannotPublishAfterSameGenerationDelegateStop() throws {
        var lifecycle = TeamsCaptureViabilityLifecycleCoordinator()
        XCTAssertTrue(lifecycle.beginStart())
        let generation = try XCTUnwrap(lifecycle.registerStartupCandidate())
        XCTAssertTrue(lifecycle.adoptStartupCandidate(generation: generation))

        XCTAssertEqual(
            lifecycle.recordDelegateStop(
                generation: generation,
                errorDescription: "stream stopped"
            ),
            .active(shouldFinalize: true)
        )
        XCTAssertFalse(lifecycle.shouldPublishCapturing(generation: generation))
        XCTAssertFalse(lifecycle.isCapturing)
        XCTAssertEqual(
            lifecycle.recordDelegateStop(
                generation: generation,
                errorDescription: "stream stopped again"
            ),
            .active(shouldFinalize: false)
        )
    }

    func testLifecycleReturnsToIdleAfterAllStartupAttemptsFail() {
        var lifecycle = TeamsCaptureViabilityLifecycleCoordinator()
        XCTAssertTrue(lifecycle.beginStart())

        lifecycle.startFailed()

        XCTAssertFalse(lifecycle.isCapturing)
        XCTAssertTrue(lifecycle.beginStart())
    }

    func testLifecycleIgnoresDelegateStopFromFailedStartupAttempt() {
        var lifecycle = TeamsCaptureViabilityLifecycleCoordinator()
        XCTAssertTrue(lifecycle.beginStart())

        XCTAssertFalse(
            lifecycle.requestDelegateFinalization(isActiveStream: false)
        )
        lifecycle.startSucceeded()
        XCTAssertTrue(lifecycle.isCapturing)
        XCTAssertFalse(
            lifecycle.requestDelegateFinalization(isActiveStream: false)
        )
        XCTAssertTrue(lifecycle.isCapturing)
        XCTAssertTrue(
            lifecycle.requestDelegateFinalization(isActiveStream: true)
        )
        XCTAssertFalse(lifecycle.isCapturing)
    }

    func testTransitionBoundaryAudioGapPersistsGateFailureEvidence() {
        let note = TeamsCaptureViabilityGateFailure.audioGap(
            source: .microphone,
            filterRevision: 0,
            unexplainedGap: 0.380
        )

        XCTAssertEqual(
            note,
            "Gate failure: unexplained audio gap source=microphone revision=0 gap=0.380000s"
        )
        var report = passingReport
        report.notes = [note]
        XCTAssertTrue(TeamsCaptureViabilityEvaluator.failures(in: report).contains {
            $0.contains("gate failure")
        })
    }

    func testCallbackAndEvidenceQueuesAreAllDistinct() {
        let labels = TeamsCaptureViabilityQueuePlan.allLabels

        XCTAssertEqual(labels.count, 4)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    private var passingReport: TeamsCaptureViabilityReport {
        let baseline = dwell(filterRevision: 0, windowID: nil)
        let windowDwell = dwell(filterRevision: 1, windowID: 42)
        return TeamsCaptureViabilityReport(
            streamIdentities: ["stream-1"],
            filterTransitionCount: 4,
            applicationBaseline: baseline,
            windowFilterDwells: [windowDwell],
            observedWindowIDs: [42],
            notes: []
        )
    }

    private func dwell(
        filterRevision: UInt64 = 1,
        windowID: UInt32? = 42,
        duration: TimeInterval = 5,
        streamIdentity: String = "stream-1",
        completeScreenFrameCount: Int = 10,
        nonSilentSystemBufferCount: Int = 1,
        nonSilentMicrophoneBufferCount: Int = 1,
        maximumSystemPTSGap: TimeInterval = 0.25,
        maximumMicrophonePTSGap: TimeInterval = 0.25,
        capturedFramePNG: String? = "/tmp/window-42.png"
    ) -> TeamsCaptureViabilityDwell {
        TeamsCaptureViabilityDwell(
            filterRevision: filterRevision,
            windowID: windowID,
            duration: duration,
            streamIdentity: streamIdentity,
            completeScreenFrameCount: completeScreenFrameCount,
            nonSilentSystemBufferCount: nonSilentSystemBufferCount,
            nonSilentMicrophoneBufferCount: nonSilentMicrophoneBufferCount,
            maximumSystemPTSGap: maximumSystemPTSGap,
            maximumMicrophonePTSGap: maximumMicrophonePTSGap,
            capturedFramePNG: capturedFramePNG
        )
    }
}
