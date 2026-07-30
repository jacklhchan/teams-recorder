import XCTest
@testable import RecorderApp

@MainActor
final class RecordDashboardPresentationTests: XCTestCase {
    func testCompact860PolicyExposesAllOperationalProbes() {
        let presentation = RecordDashboardPresentation.make(
            isRecording: false,
            startedAt: nil,
            now: .now,
            isCaptureLifecycleWorking: false,
            isRunningTestRecording: false,
            localMicMuted: false,
            nativeInputMicMuted: false,
            teamsMicMuted: false
        )

        XCTAssertEqual(presentation.elapsedText, "00:00:00")
        XCTAssertEqual(
            presentation.operationalProbeIDs,
            [
                "record-state",
                "elapsed-time",
                RecorderActionID.startStop,
                RecorderActionID.muteMic,
                "system-meter",
                "microphone-meter",
                "capture-health"
            ]
        )
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
                nativeInputMicMuted: false,
                teamsMicMuted: false
            ).startStopDisabled
        )
        XCTAssertTrue(
            RecordDashboardPresentation.make(
                isRecording: false,
                startedAt: nil,
                now: .now,
                isCaptureLifecycleWorking: false,
                isRunningTestRecording: false,
                localMicMuted: false,
                nativeInputMicMuted: false,
                teamsMicMuted: true
            ).muteDisabled
        )
    }

    func testCompactMeterPresentationPreservesWaveformSamples() {
        let samples: [Float] = [0.1, 0.45, 0.9]
        let presentation = RecordDashboardMeterPresentation.make(
            level: .init(rms: -12, peak: -3, samples: samples)
        )

        XCTAssertEqual(presentation.waveformSamples, samples)
    }
}
