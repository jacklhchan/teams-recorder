import SwiftUI

struct RecorderStatusTransition<Value: Equatable, Content: View>: View {
    let value: Value
    let content: (Value) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: Value
    @State private var outgoing: Value?
    @State private var isOutgoingVisible = false

    init(value: Value, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.content = content
        _current = State(initialValue: value)
        _outgoing = State(initialValue: nil)
    }

    var body: some View {
        let policy = RecorderMotionPolicy.make(reduceMotion: reduceMotion)
        ZStack {
            if let outgoing {
                content(outgoing)
                    .opacity(isOutgoingVisible ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            content(current)
        }
        .onChange(of: value) { _, replacement in
            replaceCurrent(with: replacement, policy: policy)
        }
    }

    private func replaceCurrent(with replacement: Value, policy: RecorderMotionPolicy) {
        guard replacement != current else { return }
        let replaced = current
        outgoing = replaced
        isOutgoingVisible = true
        current = replacement
        DispatchQueue.main.async {
            guard outgoing == replaced else { return }
            withAnimation(
                .easeOut(duration: policy.statusDuration),
                completionCriteria: .logicallyComplete
            ) {
                isOutgoingVisible = false
            } completion: {
                guard outgoing == replaced else { return }
                outgoing = nil
            }
        }
    }
}
