import XCTest
@testable import RecorderApp

final class RecorderToolbarPresentationTests: XCTestCase {
    func testRecordToolbarPreservesLifecycleAndRecordingGates() {
        let availableDashboard = RecordDashboardPresentation.make(
            isRecording: false,
            startedAt: nil,
            now: .now,
            isCaptureLifecycleWorking: false,
            isRunningTestRecording: false,
            localMicMuted: false,
            nativeInputMicMuted: false,
            teamsMicMuted: false
        )
        XCTAssertEqual(
            RecordToolbarPresentation.make(
                sourceControlsEnabled: true,
                isRecording: false,
                dashboard: availableDashboard
            ),
            .init(
                refreshDisabled: false,
                muteDisabled: false,
                testDisabled: false,
                chooseOutputFolderDisabled: false
            )
        )

        let blockedDashboard = RecordDashboardPresentation.make(
            isRecording: true,
            startedAt: .now,
            now: .now,
            isCaptureLifecycleWorking: true,
            isRunningTestRecording: true,
            localMicMuted: false,
            nativeInputMicMuted: false,
            teamsMicMuted: true
        )
        XCTAssertEqual(
            RecordToolbarPresentation.make(
                sourceControlsEnabled: false,
                isRecording: true,
                dashboard: blockedDashboard
            ),
            .init(
                refreshDisabled: true,
                muteDisabled: true,
                testDisabled: true,
                chooseOutputFolderDisabled: true
            )
        )
    }

    func testRecordingsToolbarDisablesUploadOnlyWhileTranscribing() {
        XCTAssertFalse(
            RecordingsToolbarPresentation.make(isTranscribing: false)
                .uploadDisabled
        )
        XCTAssertTrue(
            RecordingsToolbarPresentation.make(isTranscribing: true)
                .uploadDisabled
        )
    }
}
