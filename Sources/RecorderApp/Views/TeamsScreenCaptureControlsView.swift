import SwiftUI

struct TeamsScreenCaptureControlsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GridRow {
            Label("Teams Screen", systemImage: "rectangle.inset.filled")
                .font(.headline)
            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in
                        await model.setTeamsScreenCaptureRequested(!model.isTeamsScreenCaptureRequested)
                    }
                } label: {
                    Image(systemName: model.isTeamsScreenCaptureRequested
                        ? "rectangle.inset.filled.badge.record.fill"
                        : "rectangle.inset.filled.badge.record")
                }
                .buttonStyle(.bordered)
                .frame(width: 30, height: 28)
                .help("Capture selected Teams window")
                .accessibilityLabel("Capture Teams window")
                .accessibilityIdentifier("teams-screen-capture-toggle")
                .disabled(model.isTeamsScreenCaptureToggleDisabled)

                Label(model.teamsScreenStatusText, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                    .help(model.teamsScreenStatusText)
                    .accessibilityLabel("Teams screen capture status")
                    .accessibilityValue(model.teamsScreenStatusText)
                    .accessibilityIdentifier("teams-screen-capture-status")
            }
            Menu {
                Button("Automatic selection") {
                    Task { @MainActor in await model.selectTeamsScreenCaptureWindow(nil) }
                }
                if model.teamsManualWindowIdentity == nil {
                    Divider()
                }
                ForEach(model.teamsScreenCaptureCandidates) { candidate in
                    Button(candidateLabel(candidate)) {
                        Task { @MainActor in await model.selectTeamsScreenCaptureWindow(candidate.identity) }
                    }
                }
            } label: {
                Text(selectedWindowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 330, alignment: .leading)
            .help("Choose Teams window")
            .accessibilityLabel("Choose Teams window")
            .accessibilityIdentifier("teams-screen-window-menu")
        }
    }

    private var selectedWindowTitle: String {
        guard let identity = model.teamsManualWindowIdentity,
              let candidate = model.teamsScreenCaptureCandidates.first(where: { $0.identity == identity }) else {
            return "Automatic selection"
        }
        return candidateLabel(candidate)
    }

    private var statusIcon: String {
        switch model.teamsScreenStatusText {
        case TeamsScreenStatusText.ready: "checkmark.circle.fill"
        case TeamsScreenStatusText.capturing: "record.circle.fill"
        case TeamsScreenStatusText.awaitingFrames: "hourglass.circle"
        case TeamsScreenStatusText.framesUnavailable: "video.slash.fill"
        case TeamsScreenStatusText.reconnecting: "arrow.triangle.2.circlepath"
        case TeamsScreenStatusText.waiting: "hourglass.circle"
        case TeamsScreenStatusText.unavailable: "exclamationmark.triangle.fill"
        default: "rectangle.slash"
        }
    }

    private var statusColor: Color {
        switch model.teamsScreenStatusText {
        case TeamsScreenStatusText.ready: .green
        case TeamsScreenStatusText.capturing: .red
        case TeamsScreenStatusText.awaitingFrames: .orange
        case TeamsScreenStatusText.framesUnavailable, TeamsScreenStatusText.reconnecting: .orange
        case TeamsScreenStatusText.waiting: .orange
        case TeamsScreenStatusText.unavailable: .orange
        default: .secondary
        }
    }

    private func candidateLabel(_ candidate: TeamsWindowDescriptor) -> String {
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.isEmpty ? "Untitled Teams window" : title
        return "\(normalizedTitle) - \(Int(candidate.frame.width))x\(Int(candidate.frame.height)) - Window ID \(candidate.identity.windowID)"
    }
}
