import SwiftUI
import XCTest
@testable import RecorderApp

final class RecorderVisualStyleTests: XCTestCase {
    func testTranscriptAppearanceIsDistinctAcrossSystemSchemes() {
        XCTAssertEqual(
            RecorderVisualStyle.transcriptAppearance(for: .light),
            .transcriptLight
        )
        XCTAssertEqual(
            RecorderVisualStyle.transcriptAppearance(for: .dark),
            .transcriptDark
        )
        XCTAssertNotEqual(
            RecorderSurfaceAppearance.transcriptLight.accessibilityIdentifier,
            RecorderSurfaceAppearance.transcriptDark.accessibilityIdentifier
        )
    }

    func testFixedDarkSurfacesHaveStableIdentifiers() {
        XCTAssertEqual(
            RecorderSurfaceAppearance.recordingsDark.accessibilityIdentifier,
            "recorder.surface.recordings.dark"
        )
        XCTAssertEqual(
            RecorderSurfaceAppearance.providerDark.accessibilityIdentifier,
            "recorder.surface.provider.dark"
        )
    }

    func testContrastAppearanceAndHairlineStrengthAreSemantic() {
        XCTAssertEqual(
            RecorderVisualStyle.contrastAppearance(for: .standard),
            .standardContrast
        )
        XCTAssertEqual(
            RecorderVisualStyle.contrastAppearance(for: .increased),
            .increasedContrast
        )
        XCTAssertGreaterThan(
            RecorderVisualStyle.hairlineOpacity(for: .increased),
            RecorderVisualStyle.hairlineOpacity(for: .standard)
        )
    }
}
