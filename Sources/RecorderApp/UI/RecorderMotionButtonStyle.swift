import SwiftUI

struct RecorderMotionButtonStyle: ButtonStyle {
    enum Prominence {
        case prominent
        case compact
    }

    let prominence: Prominence
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.recorderReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let policy = RecorderMotionPolicy.make(
            reduceMotion: reduceMotionOverride ?? reduceMotion
        )
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, prominence == .prominent ? 16 : 10)
            .padding(.vertical, prominence == .prominent ? 10 : 7)
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
            .background(
                RecorderPresentationDiagnosticMarker(
                    identifier: policy.pressedScale == 1
                        ? "recorder.motion.no-scale"
                        : "recorder.motion.scale"
                )
            )
    }
}
