import Foundation

struct RecorderMotionPolicy: Equatable, Sendable {
    let pressedScale: Double
    let pressDuration: TimeInterval
    let releaseDuration: TimeInterval
    let statusDuration: TimeInterval
    let revealDuration: TimeInterval
    let revealOffset: Double
    let drawsCompletionStroke: Bool
    let travelsIndeterminateSegment: Bool

    static func make(reduceMotion: Bool) -> Self {
        reduceMotion
            ? .init(pressedScale: 1, pressDuration: 0, releaseDuration: 0, statusDuration: 0.16, revealDuration: 0.16, revealOffset: 0, drawsCompletionStroke: false, travelsIndeterminateSegment: false)
            : .init(pressedScale: 0.975, pressDuration: 0.08, releaseDuration: 0.18, statusDuration: 0.18, revealDuration: 0.26, revealOffset: 6, drawsCompletionStroke: true, travelsIndeterminateSegment: true)
    }
}
