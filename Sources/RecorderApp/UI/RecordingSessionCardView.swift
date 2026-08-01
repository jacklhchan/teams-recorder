import SwiftUI

/// Presentation-only card shell. The parent owns the sole expansion identity.
struct RecordingSessionCardView<Content: View>: View {
    let session: RecordingSession
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Text(session.displayName).font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recorder.row.card.\(session.id.lastPathComponent)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.row.card.\(session.id.lastPathComponent).marker"
                )
            )
            if isExpanded {
                content()
                    .accessibilityIdentifier("recorder.row.expanded.\(session.id.lastPathComponent)")
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: "recorder.row.expanded.\(session.id.lastPathComponent)"
                        )
                    )
            }
        }
        .padding(14)
        .background(RecorderVisualStyle.recordingsCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.16)))
    }
}
