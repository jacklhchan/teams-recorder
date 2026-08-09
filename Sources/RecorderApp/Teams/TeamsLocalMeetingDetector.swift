enum TeamsLocalMeetingDetectionState: Equatable, Sendable {
    case waiting
    case confirming(secondsRemaining: Int)
    case detected(TeamsWindowConfidence)
    case ending(secondsRemaining: Int)
    case ambiguous
}

enum TeamsLocalMeetingObservation: Equatable, Sendable {
    case resolved(TeamsWindowResolution)
    case unknown
}

struct TeamsLocalMeetingUpdate: Equatable, Sendable {
    let state: TeamsLocalMeetingDetectionState
    let meetingTransition: Bool?
}

struct TeamsLocalMeetingDetector {
    private let confirmObservations: Int
    private let endObservations: Int
    private var candidateIdentity: TeamsWindowIdentity?
    private var positiveCount = 0
    private var missingCount = 0
    private var meetingIsDetected = false
    private(set) var state: TeamsLocalMeetingDetectionState = .waiting

    init(confirmObservations: Int = 3, endObservations: Int = 30) {
        precondition(confirmObservations > 0 && endObservations > 0)
        self.confirmObservations = confirmObservations
        self.endObservations = endObservations
    }

    mutating func observe(
        _ observation: TeamsLocalMeetingObservation
    ) -> TeamsLocalMeetingUpdate {
        switch observation {
        case .unknown:
            return update()
        case .resolved(.ambiguous):
            guard !meetingIsDetected else { return update() }
            clearCandidate()
            state = .ambiguous
            return update()
        case .resolved(.waiting):
            return observeMissingWindow()
        case .resolved(.ready(let match)):
            return observeReadyWindow(match)
        }
    }

    mutating func reset() -> TeamsLocalMeetingUpdate {
        clearCandidate()
        missingCount = 0
        meetingIsDetected = false
        state = .waiting
        return update()
    }

    private mutating func observeReadyWindow(
        _ match: TeamsWindowMatch
    ) -> TeamsLocalMeetingUpdate {
        missingCount = 0
        if meetingIsDetected {
            state = .detected(match.confidence)
            return update()
        }

        if candidateIdentity == match.window.identity {
            positiveCount += 1
        } else {
            candidateIdentity = match.window.identity
            positiveCount = 1
        }

        guard positiveCount >= confirmObservations else {
            state = .confirming(
                secondsRemaining: confirmObservations - positiveCount
            )
            return update()
        }

        meetingIsDetected = true
        state = .detected(match.confidence)
        return update(transition: true)
    }

    private mutating func observeMissingWindow() -> TeamsLocalMeetingUpdate {
        guard meetingIsDetected else {
            clearCandidate()
            state = .waiting
            return update()
        }

        missingCount += 1
        guard missingCount >= endObservations else {
            state = .ending(secondsRemaining: endObservations - missingCount)
            return update()
        }

        clearCandidate()
        missingCount = 0
        meetingIsDetected = false
        state = .waiting
        return update(transition: false)
    }

    private mutating func clearCandidate() {
        candidateIdentity = nil
        positiveCount = 0
    }

    private func update(transition: Bool? = nil) -> TeamsLocalMeetingUpdate {
        TeamsLocalMeetingUpdate(state: state, meetingTransition: transition)
    }
}
