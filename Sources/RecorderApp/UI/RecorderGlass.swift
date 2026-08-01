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

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: role.cornerRadius,
            style: .continuous
        )
        if reduceTransparency {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator.opacity(0.45)))
        } else {
            content.glassEffect(.regular.interactive(role.isInteractive), in: shape)
        }
    }
}

extension View {
    func recorderGlassSurface(_ role: RecorderGlassRole) -> some View {
        modifier(RecorderGlassSurface(role: role))
    }
}
