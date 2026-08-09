import XCTest
@testable import RecorderApp

final class TeamsMuteAccessibilityClassifierTests: XCTestCase {
    func testEnglishMuteActionMeansTeamsIsCurrentlyUnmuted() {
        XCTAssertEqual(
            classify(title: "Mute"),
            .unmuted
        )
    }

    func testEnglishUnmuteActionMeansTeamsIsCurrentlyMuted() {
        XCTAssertEqual(
            classify(title: "Unmute"),
            .muted
        )
    }

    func testCurrentEnglishMicActionsAreTrimmedAndCaseInsensitive() {
        XCTAssertEqual(
            classify(title: "  uNmUtE MiC\n"),
            .muted
        )
        XCTAssertEqual(
            classify(title: "\tMUTE MIC  "),
            .unmuted
        )
    }

    func testSupportedChineseMuteAndUnmuteActions() {
        for title in ["靜音", "静音"] {
            XCTAssertEqual(classify(title: title), .unmuted)
        }
        for title in ["取消靜音", "取消静音"] {
            XCTAssertEqual(classify(title: title), .muted)
        }
    }

    func testHiddenAndDisabledControlsAreIgnored() {
        XCTAssertEqual(
            TeamsMuteAccessibilityClassifier.classify([
                descriptor(title: "Unmute", visible: false),
                descriptor(title: "Mute", enabled: false)
            ]),
            .unknown(.controlNotFound)
        )
    }

    func testTwoEquallyValidControlsAreAmbiguous() {
        XCTAssertEqual(
            TeamsMuteAccessibilityClassifier.classify([
                descriptor(title: "Mute"),
                descriptor(title: "Mute")
            ]),
            .unknown(.ambiguousControls)
        )
    }

    func testUnsupportedSemanticEvidenceDoesNotGuess() {
        for title in [
            "Microphone settings",
            "Mute mic settings",
            "Please Unmute mic"
        ] {
            XCTAssertEqual(
                classify(title: title),
                .unknown(.controlNotFound)
            )
        }
    }

    private func classify(title: String) -> TeamsMicMuteState {
        TeamsMuteAccessibilityClassifier.classify([descriptor(title: title)])
    }

    private func descriptor(
        title: String? = nil,
        enabled: Bool = true,
        visible: Bool = true
    ) -> TeamsMuteControlDescriptor {
        TeamsMuteControlDescriptor(
            role: "AXButton",
            identifier: nil,
            title: title,
            description: nil,
            help: nil,
            value: nil,
            enabled: enabled,
            visible: visible
        )
    }
}
