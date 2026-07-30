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
            RecordDashboardPresentation.operationalProbeIDs,
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

    func testOperationalProbeIDsAreStaticProductionPolicy() throws {
        let presentation = try source(named: "RecordDashboardPresentation.swift")
        let dashboard = try source(named: "RecordDashboardView.swift")
        let renderTests = try source(named: "RecorderWorkspaceRenderTests.swift", in: "Tests/RecorderAppTests")

        XCTAssertTrue(presentation.contains("static let operationalProbeIDs"))
        XCTAssertTrue(dashboard.contains("let presentation = RecordDashboardPresentation.make("))
        XCTAssertTrue(dashboard.contains("RecordDashboardHeader(model: model, presentation: presentation)"))
        XCTAssertTrue(dashboard.contains("RecordDashboardControls(model: model, presentation: presentation)"))
        XCTAssertFalse(dashboard.contains(".disabled(!model.recorder.isRecording && model.isCaptureLifecycleWorking)"))
        XCTAssertFalse(dashboard.contains(".disabled(model.recorder.isRecording || model.isRunningTestRecording || model.isCaptureLifecycleWorking)"))
        XCTAssertFalse(dashboard.contains(".disabled((model.teamsMicMuted || model.nativeInputMicMuted) && !model.localMicMuted)"))
        XCTAssertTrue(renderTests.contains("RecordDashboardPresentation.operationalProbeIDs"))
        XCTAssertFalse(renderTests.contains("private var operationalProbeIDs"))
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

    private func source(named name: String, in directory: String = "Sources/RecorderApp/UI") throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(directory).appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
