import XCTest
@testable import RecorderApp

final class AudioHealthAdvisorTests: XCTestCase {
    func testHealthAdvisorWarnsWhenBothInputsAreSilent() {
        let health = AudioHealthAdvisor.assessment(
            systemLevel: .init(rms: -90, peak: -90),
            micLevel: .init(rms: -90, peak: -90),
            isMicMuted: false,
            isMonitoring: true,
            isRecording: true
        )

        XCTAssertEqual(health.system.status, .warning)
        XCTAssertEqual(health.mic.status, .warning)
    }

    func testHealthAdvisorReportsMutedMicSeparatelyFromMissingSignal() {
        let health = AudioHealthAdvisor.assessment(
            systemLevel: .init(rms: -30, peak: -8),
            micLevel: .init(rms: -120, peak: -120),
            isMicMuted: true,
            isMonitoring: true,
            isRecording: false
        )

        XCTAssertEqual(health.system.status, .ok)
        XCTAssertEqual(health.mic.title, "Mic muted")
        XCTAssertEqual(health.mic.status, .neutral)
    }
}
