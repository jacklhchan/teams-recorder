import AppKit
import SwiftUI

/// Presentation-only card shell. The parent owns the sole expansion identity.
struct RecordingSessionCardView<Content: View>: View {
    let session: RecordingSession
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordingSessionCardHeader(
                title: session.displayName,
                identifier: "recorder.row.card.\(session.id.lastPathComponent)",
                isExpanded: $isExpanded
            )
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .background(
                RecorderDestinationAccessibilityMarker(
                    // Keep the marker distinct from the actionable button. The
                    // render harness must invoke the real accessibility press
                    // action, rather than accidentally targeting this
                    // zero-sized marker.
                    identifier: "recorder.row.card.\(session.id.lastPathComponent).marker",
                    label: isExpanded ? "Expanded" : "Collapsed"
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

/// A native button gives the card header a stable AppKit accessibility press
/// action while keeping expansion ownership in the SwiftUI parent binding.
private struct RecordingSessionCardHeader: NSViewRepresentable {
    let title: String
    let identifier: String
    @Binding var isExpanded: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isExpanded: $isExpanded) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.toggle))
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.imagePosition = .imageTrailing
        return button
    }

    func updateNSView(_ button: NSButton, context _: Context) {
        button.title = title
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )
    }

    final class Coordinator: NSObject {
        private var isExpanded: Binding<Bool>

        init(isExpanded: Binding<Bool>) { self.isExpanded = isExpanded }

        @objc func toggle() { isExpanded.wrappedValue.toggle() }
    }
}
