import Foundation

enum RecorderObservedPhase: Equatable, Sendable {
    case idle
    case working
    case ready
    case failure
}

struct RecorderObservedSnapshot: Equatable, Sendable {
    let featureRevision: UInt64
    /// The immutable canonical identity produced by the meeting-intelligence
    /// feature.  The motion layer observes it but never rebuilds or owns it.
    let identity: MeetingIntelligenceSessionPresentationIdentity
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
              previous.identity == current.identity,
              current.featureRevision > previous.featureRevision else {
            return .none
        }

        let completed = previous.phase != .ready && current.phase == .ready
        let titleChanged = previous.phase == .ready
            && current.phase == .ready
            && !current.titleIsProtected
            && previous.displayedTitle != current.displayedTitle
        return .init(completed: completed, generatedTitleChanged: titleChanged)
    }
}

/// Adapts the immutable Meeting Intelligence feature projection for the
/// presentation-only motion layer.  It deliberately carries no feature model
/// or mutable UI state: the enclosing library view captures one feature
/// snapshot for its body and supplies the matching canonical session here.
enum MeetingIntelligenceObservedSnapshotAdapter {
    static func make(
        featureRevision: UInt64,
        sessionPresentation: MeetingIntelligenceSessionPresentation,
        canonicalSession: RecordingSession,
        titleIsProtected: Bool
    ) -> RecorderObservedSnapshot? {
        guard MeetingIntelligenceSessionPresentationIdentity(
            session: canonicalSession
        ) == sessionPresentation.identity else { return nil }
        return .init(
            featureRevision: featureRevision,
            identity: sessionPresentation.identity,
            phase: observedPhase(for: sessionPresentation.presentation.phase),
            displayedTitle: displayedTitle(
                presentation: sessionPresentation.presentation,
                canonicalSession: canonicalSession
            ),
            titleIsProtected: titleIsProtected
        )
    }

    private static func observedPhase(
        for phase: MeetingIntelligencePresentation.Phase
    ) -> RecorderObservedPhase {
        switch phase {
        case .notGenerated:
            .idle
        case .checkingAvailability, .generating:
            .working
        case .ready, .stale:
            .ready
        case .failed, .cancelled, .interrupted:
            .failure
        }
    }

    private static func displayedTitle(
        presentation: MeetingIntelligencePresentation,
        canonicalSession: RecordingSession
    ) -> String {
        guard let suggestedTitle = presentation.suggestedTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
              !suggestedTitle.isEmpty
        else {
            return canonicalSession.displayName
        }
        return suggestedTitle
    }
}
