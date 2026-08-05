import XCTest
@testable import RecorderApp

@MainActor
final class RecordDashboardPresentationTests: XCTestCase {
    func testElapsedTimeUsesHoursMinutesSeconds() {
        let now = Date(timeIntervalSince1970: 4_000)
        let presentation = RecordDashboardPresentation.make(
            isRecording: true,
            startedAt: now.addingTimeInterval(-3_661),
            now: now,
            isCaptureLifecycleWorking: false,
            isRunningTestRecording: false,
            localMicMuted: false,
            nativeInputMicMuted: false
        )

        XCTAssertEqual(presentation.elapsedText, "01:01:01")
    }

    func testCurrentDisabledPoliciesRemainExact() {
        XCTAssertTrue(
            RecordDashboardPresentation.make(
                isRecording: false,
                startedAt: nil,
                now: .now,
                isCaptureLifecycleWorking: true,
                isRunningTestRecording: false,
                localMicMuted: false,
                nativeInputMicMuted: false
            ).startStopDisabled
        )
        XCTAssertFalse(
            RecordDashboardPresentation.make(
                isRecording: false,
                startedAt: nil,
                now: .now,
                isCaptureLifecycleWorking: false,
                isRunningTestRecording: false,
                localMicMuted: false,
                nativeInputMicMuted: true
            ).muteDisabled
        )
    }

}
