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
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect()
        } else {
            fallback(content)
        }
#else
        fallback(content)
#endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: RecorderVisualStyle.chromeCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RecorderVisualStyle.chromeCornerRadius)
                    .stroke(.separator.opacity(0.45))
            )
    }
}

extension View {
    func recorderGlass() -> some View {
        modifier(RecorderGlass())
    }
}
