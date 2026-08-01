import SwiftUI

struct RecorderSRGBColor: Equatable, Sendable {
    let red: Int
    let green: Int
    let blue: Int

    var hexToken: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var color: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }
}

enum RecorderSurfaceAppearance: String, Equatable, Sendable {
    case recordingsDark = "recordings.dark"
    case recordingsStatusDark = "recordings.status.dark"
    case providerDark = "provider.dark"
    case transcriptLight = "transcript.light"
    case transcriptDark = "transcript.dark"
    case standardContrast = "contrast.standard"
    case increasedContrast = "contrast.increased"

    var accessibilityIdentifier: String {
        "recorder.surface.\(rawValue)"
    }
}

enum RecorderVisualStyle {
    // This is deliberately opaque: the branded navigation surface remains
    // legible when Reduce Transparency substitutes system materials in cards.
    static let sidebarGradientStops: [RecorderSRGBColor] = [
        .init(red: 0x13, green: 0x24, blue: 0x52),
        .init(red: 0x24, green: 0x4F, blue: 0x9E),
        .init(red: 0x11, green: 0x2B, blue: 0x63)
    ]
    static let sidebarWarningText = RecorderSRGBColor(
        red: 0xFF,
        green: 0xD2,
        blue: 0xB0
    )
    static let systemAudio = Color.cyan
    static let microphone = Color.green
    static let recording = Color.red
    // Retain the existing neutral surface used by Record and any untouched
    // compatibility presentation during this stacked UI refactor.
    static let cardSurface = Color.secondary.opacity(0.08)
    static let accentCyan = Color(red: 0.098, green: 0.765, blue: 0.863)
    static let actionBlue = Color(red: 0.086, green: 0.471, blue: 0.933)
    static let success = Color(red: 0.145, green: 0.718, blue: 0.451)
    static let warning = Color(red: 0.941, green: 0.416, blue: 0.106)
    static let destructive = Color(red: 0.984, green: 0.376, blue: 0.353)
    static let recordingsCanvas = Color(red: 0.039, green: 0.078, blue: 0.173)
    static let recordingsCard = Color(red: 0.071, green: 0.114, blue: 0.235)
    static let recordingsStatusSurface = Color(red: 0.055, green: 0.098, blue: 0.200)
    static let providerCanvas = Color(red: 0.051, green: 0.086, blue: 0.125)
    static let transcriptLightCanvas = Color(red: 0.984, green: 0.984, blue: 0.992)
    static let transcriptLightCard = Color.white
    static let transcriptLightEditor = Color.white
    static let transcriptLightText = Color(red: 0.063, green: 0.082, blue: 0.153)
    static let transcriptLightSecondary = Color(red: 0.337, green: 0.373, blue: 0.471)
    static let transcriptLightHairline = Color(red: 0.875, green: 0.890, blue: 0.918)
    static let transcriptDarkCanvas = Color(red: 0.071, green: 0.094, blue: 0.141)
    static let transcriptDarkCard = Color(red: 0.094, green: 0.122, blue: 0.173)
    static let transcriptDarkEditor = Color(red: 0.078, green: 0.106, blue: 0.153)
    static let transcriptDarkText = Color(red: 0.949, green: 0.961, blue: 0.984)
    static let transcriptDarkSecondary = Color(red: 0.678, green: 0.714, blue: 0.780)
    static let transcriptDarkHairline = Color(red: 0.204, green: 0.239, blue: 0.306)

    static func transcriptAppearance(
        for colorScheme: ColorScheme
    ) -> RecorderSurfaceAppearance {
        colorScheme == .dark ? .transcriptDark : .transcriptLight
    }

    static func contrastAppearance(
        for contrast: ColorSchemeContrast
    ) -> RecorderSurfaceAppearance {
        contrast == .increased ? .increasedContrast : .standardContrast
    }

    static func hairlineOpacity(
        for contrast: ColorSchemeContrast
    ) -> Double {
        contrast == .increased ? 0.72 : 0.42
    }
}
