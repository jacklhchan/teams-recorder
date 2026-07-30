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

    func testRetainedVisualStyleTokensEachHaveAProductionCaller() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let visualStyle = try String(
            contentsOf: root.appendingPathComponent("Sources/RecorderApp/UI/RecorderVisualStyle.swift"),
            encoding: .utf8
        )
        let files = try FileManager.default.subpathsOfDirectory(
            atPath: root.appendingPathComponent("Sources/RecorderApp").path
        )
        let productionSource = try files.filter { $0.hasSuffix(".swift") }
            .map { path in
                try String(
                    contentsOf: root.appendingPathComponent("Sources/RecorderApp").appendingPathComponent(path),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")

        for token in ["systemAudio", "microphone", "recording", "cardSurface", "chromeCornerRadius"] {
            guard visualStyle.contains("static let \(token)") else { continue }
            XCTAssertGreaterThan(
                productionSource.components(separatedBy: "RecorderVisualStyle.\(token)").count - 1,
                0,
                "\(token) must have a production caller"
            )
        }
    }
}
