import XCTest
@testable import RecorderApp

final class ContentViewSourceDecompositionTests: XCTestCase {
    func testContentViewContainsNoMovedViewDeclarations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/RecorderApp/ContentView.swift"),
            encoding: .utf8
        )

        for temporaryAdapter in [
            "baselineRecordDestination",
            "baselineRecordingsDestination",
            "baselineSettingsDestination"
        ] {
            XCTAssertFalse(source.contains(temporaryAdapter))
        }

        for movedType in [
            "PermissionStatusView", "CaptureControlsView", "HeaderView",
            "MeterSectionView", "ControlsView", "HealthSummaryView",
            "LiveAudioHealthView", "SessionListView", "TranscriptEditorView",
            "RecordingMetadataEditorView", "FooterView"
        ] {
            XCTAssertFalse(source.contains("struct \(movedType)"))
        }
    }
}
