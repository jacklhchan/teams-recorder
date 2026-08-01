import SwiftUI
import XCTest
@testable import RecorderApp

final class RecorderVisualStyleTests: XCTestCase {
    func testSidebarGradientUsesApprovedFixedBrandStops() {
        let stops = RecorderVisualStyle.sidebarGradientStops

        XCTAssertEqual(stops.count, 3)
        XCTAssertEqual(stops[0].hexToken, "#132452")
        XCTAssertEqual(stops[1].hexToken, "#244F9E")
        XCTAssertEqual(stops[2].hexToken, "#112B63")
        XCTAssertEqual(stops[0].red, 0x13)
        XCTAssertEqual(stops[0].green, 0x24)
        XCTAssertEqual(stops[0].blue, 0x52)
        XCTAssertEqual(stops[1].red, 0x24)
        XCTAssertEqual(stops[1].green, 0x4F)
        XCTAssertEqual(stops[1].blue, 0x9E)
        XCTAssertEqual(stops[2].red, 0x11)
        XCTAssertEqual(stops[2].green, 0x2B)
        XCTAssertEqual(stops[2].blue, 0x63)
    }

    func testSidebarTextTokensRemainReadableAcrossEveryGradientStop() {
        for background in RecorderVisualStyle.sidebarGradientStops {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(
                    RecorderVisualStyle.sidebarPrimaryText,
                    background
                ),
                4.5,
                "Primary sidebar text must remain readable over \(background.hexToken)"
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(
                    RecorderVisualStyle.sidebarSecondaryText,
                    background
                ),
                4.5,
                "Secondary sidebar text must remain readable over \(background.hexToken)"
            )
        }
    }

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

private func contrastRatio(
    _ first: RecorderSRGBColor,
    _ second: RecorderSRGBColor
) -> Double {
    let light = max(relativeLuminance(first), relativeLuminance(second))
    let dark = min(relativeLuminance(first), relativeLuminance(second))
    return (light + 0.05) / (dark + 0.05)
}

private func relativeLuminance(_ color: RecorderSRGBColor) -> Double {
    func linear(_ component: Int) -> Double {
        let value = Double(component) / 255
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * linear(color.red)
        + 0.7152 * linear(color.green)
        + 0.0722 * linear(color.blue)
}
