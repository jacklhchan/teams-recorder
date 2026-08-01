import SwiftUI

struct RecorderIndeterminateProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTravelling = false

    var body: some View {
        let policy = RecorderMotionPolicy.make(reduceMotion: reduceMotion)
        ZStack {
            ProgressView()
            if policy.travelsIndeterminateSegment {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.tint)
                        .frame(width: 28, height: 3)
                        .offset(x: isTravelling ? proxy.size.width - 28 : 0)
                        .accessibilityHidden(true)
                        .animation(
                            .linear(duration: 0.9).repeatForever(autoreverses: false),
                            value: isTravelling
                        )
                }
                .frame(height: 4)
                .clipShape(Capsule())
            }
        }
        .onAppear {
            guard policy.travelsIndeterminateSegment else { return }
            isTravelling = true
        }
        .onDisappear {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isTravelling = false
            }
        }
    }
}
