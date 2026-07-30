import SwiftUI

enum RecorderGlassStyle: Equatable {
    case material
    case glass

    static func resolve(majorVersion: Int) -> Self {
        majorVersion >= 26 ? .glass : .material
    }
}

struct RecorderGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect()
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.separator.opacity(0.45))
                )
        }
    }
}

extension View {
    func recorderGlass() -> some View {
        modifier(RecorderGlass())
    }
}
