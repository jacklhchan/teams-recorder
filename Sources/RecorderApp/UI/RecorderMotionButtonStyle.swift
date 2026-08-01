import SwiftUI

struct RecorderMotionButtonStyle: ButtonStyle {
    enum Prominence {
        case prominent
    }

    let prominence: Prominence
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let policy = RecorderMotionPolicy.make(reduceMotion: reduceMotion)
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(tint, in: Capsule())
            .recorderGlassSurface(.primaryControls)
            .scaleEffect(configuration.isPressed ? policy.pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(
                .easeOut(
                    duration: configuration.isPressed
                        ? policy.pressDuration
                        : policy.releaseDuration
                ),
                value: configuration.isPressed
            )
    }
}
