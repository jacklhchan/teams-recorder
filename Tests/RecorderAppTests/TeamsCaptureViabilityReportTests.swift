import Foundation
import XCTest
@testable import RecorderApp

final class TeamsCaptureViabilityReportTests: XCTestCase {
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
