import SwiftUI

enum RecorderGlassRole: Equatable {
    case navigation
    case primaryControls

    var cornerRadius: CGFloat { self == .navigation ? 16 : 18 }
    var isInteractive: Bool { self == .primaryControls }
}

private struct RecorderGlassSurface: ViewModifier {
    let role: RecorderGlassRole

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.recorderReduceTransparencyOverride)
    private var reduceTransparencyOverride

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: role.cornerRadius,
            style: .continuous
        )
        if reduceTransparencyOverride ?? reduceTransparency {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator.opacity(0.45)))
                .background(RecorderPresentationDiagnosticMarker(identifier: "recorder.glass.material-separator"))
        } else {
            content
                .glassEffect(.regular.interactive(role.isInteractive), in: shape)
                .background(RecorderPresentationDiagnosticMarker(identifier: "recorder.glass.native"))
        }
    }
}

struct RecorderPresentationDiagnosticMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> NSView {
        let view = RecorderPassiveMarkerView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

struct RecorderPanelRenderLocationMarker: NSViewRepresentable {
    let productionIdentifier: String

    func makeNSView(context: Context) -> RecorderPassiveMarkerView {
        let view = RecorderPassiveMarkerView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecorderPassiveMarkerView, context _: Context) {
        view.setAccessibilityIdentifier("\(productionIdentifier).marker")
        view.setAccessibilityElement(false)
    }
}

final class RecorderPassiveMarkerView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

extension View {
    func recorderGlassSurface(_ role: RecorderGlassRole) -> some View {
        modifier(RecorderGlassSurface(role: role))
    }
}
