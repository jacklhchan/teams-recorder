import Foundation

enum RecorderObservedPhase: Equatable, Sendable {
    case idle
    case working
    case ready
    case failure
}

struct RecorderObservedSnapshot: Equatable, Sendable {
    let featureRevision: UInt64
    let sessionID: String
    let phase: RecorderObservedPhase
    let displayedTitle: String
    let titleIsProtected: Bool
}

struct RecorderObservedFeedback: Equatable, Sendable {
    let completed: Bool
    let generatedTitleChanged: Bool

    static let none = Self(completed: false, generatedTitleChanged: false)
}

enum RecorderObservedTransition {
    static func feedback(previous: RecorderObservedSnapshot?, current: RecorderObservedSnapshot) -> RecorderObservedFeedback {
        guard let previous,
              previous.sessionID == current.sessionID,
              current.featureRevision > previous.featureRevision else {
            return .none
        }

        let completed = previous.phase != .ready && current.phase == .ready
        let titleChanged = current.phase == .ready
            && !current.titleIsProtected
            && previous.displayedTitle != current.displayedTitle
        return .init(completed: completed, generatedTitleChanged: titleChanged)
    }
}
