import SwiftUI

private struct RecorderColorSchemeContrastOverrideKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}

extension EnvironmentValues {
    var recorderColorSchemeContrastOverride: ColorSchemeContrast? {
        get { self[RecorderColorSchemeContrastOverrideKey.self] }
        set { self[RecorderColorSchemeContrastOverrideKey.self] = newValue }
    }
}

struct RecorderSidebar: View {
    @Binding var selection: RecorderDestination
    let outputFolder: URL
    let storageWarning: String?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.recorderColorSchemeContrastOverride)
    private var contrastOverride

    private var contrast: ColorSchemeContrast {
        contrastOverride ?? colorSchemeContrast
    }

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.sidebar.brand"
                    )
                )
            List(RecorderDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
                    .accessibilityIdentifier(
                        "recorder.navigation.\(destination.rawValue)"
                    )
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: "recorder.navigation.\(destination.rawValue)"
                        )
                    )
            }
            .listStyle(.sidebar)
            storageCard
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.sidebar.storage"
                    )
                )
        }
        .background(sidebarGradient)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: RecorderVisualStyle
                    .contrastAppearance(for: contrast)
                    .accessibilityIdentifier
            )
        )
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.workspace.sidebar"
            )
        )
        .accessibilityIdentifier("recorder.workspace.sidebar")
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Local Meeting Recorder", systemImage: "waveform.circle.fill")
                .font(.headline.weight(.semibold))
            if let version {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Recording location", systemImage: "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(outputFolder.lastPathComponent)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(storageWarning ?? "Ready to save recordings here")
                .font(.caption)
                .foregroundStyle(storageWarning == nil ? .secondary : RecorderVisualStyle.warning)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .recorderGlassSurface(.navigation)
        .overlay {
            RoundedRectangle(cornerRadius: RecorderGlassRole.navigation.cornerRadius, style: .continuous)
                .stroke(.separator.opacity(RecorderVisualStyle.hairlineOpacity(for: contrast)))
        }
        .padding(12)
    }

    private var sidebarGradient: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.08),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
