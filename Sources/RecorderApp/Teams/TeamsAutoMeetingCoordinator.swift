enum TeamsAutoMeetingState: Equatable, Sendable {
    case disabled
    case waitingForMeeting
    case startCountdown(secondsRemaining: Int)
    case starting
    case automaticRecording
    case stopCountdown(secondsRemaining: Int)
    case suppressedUntilMeetingEnd
    case startBlocked(String)
    case startFailed(String)
}

enum TeamsAutoMeetingCommand: Equatable, Sendable {
    case startRecording
    case cancelAutomaticStart
    case stopRecording
    case transferRecordingToManual
}

@MainActor
final class TeamsAutoMeetingCoordinator {
    private enum TimerKind {
        case start
        case stop
    }

    private let startCountdownSeconds: Int
    private let stopDebounceSeconds: Int
    private let tick: @Sendable () async -> Void
    private var timerTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isEnabled = false
    private var isInMeeting = false
    private var suppressesStopCommandUntilEndDebounce = false

    private(set) var state: TeamsAutoMeetingState = .disabled {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((TeamsAutoMeetingState) -> Void)?
    var onCommand: ((TeamsAutoMeetingCommand) -> Void)?

    var isAutoMeetingEnabled: Bool {
        isEnabled
    }

    var hasPendingTimer: Bool {
        timerTask != nil
    }

    init(
        startCountdownSeconds: Int = 5,
        stopDebounceSeconds: Int = 10,
        tick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    ) {
        precondition(startCountdownSeconds > 0)
        precondition(stopDebounceSeconds > 0)
        self.startCountdownSeconds = startCountdownSeconds
        self.stopDebounceSeconds = stopDebounceSeconds
        self.tick = tick
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        invalidateTimer()
        if enabled {
            let expectedGeneration = generation
            state = .waitingForMeeting
            guard generation == expectedGeneration,
                  isEnabled,
                  state == .waitingForMeeting else { return }
            if isInMeeting {
                beginTimer(.start, seconds: startCountdownSeconds)
            }
        } else {
            let command: TeamsAutoMeetingCommand?
            switch state {
            case .starting:
                command = .cancelAutomaticStart
            case .automaticRecording, .stopCountdown:
                command = .transferRecordingToManual
            default:
                command = nil
            }
            state = .disabled
            if let command {
                onCommand?(command)
            }
        }
    }

    func handleMeetingState(isInMeeting: Bool) {
        self.isInMeeting = isInMeeting
        guard isEnabled else { return }

        if isInMeeting {
            switch state {
            case .waitingForMeeting:
                beginTimer(.start, seconds: startCountdownSeconds)
            case .stopCountdown
                where !suppressesStopCommandUntilEndDebounce:
                invalidateTimer()
                state = .automaticRecording
            default:
                break
            }
            return
        }

        switch state {
        case .startCountdown:
            invalidateTimer()
            state = .waitingForMeeting
        case .starting:
            state = .waitingForMeeting
            onCommand?(.cancelAutomaticStart)
        case .automaticRecording:
            beginTimer(.stop, seconds: stopDebounceSeconds)
        case .suppressedUntilMeetingEnd, .startBlocked, .startFailed:
            state = .waitingForMeeting
        default:
            break
        }
    }

    func cancelCountdown() {
        guard case .startCountdown = state else { return }
        invalidateTimer()
        state = .suppressedUntilMeetingEnd
    }

    func manualRecordingStarted() {
        guard isInMeeting else { return }
        suppressUntilMeetingEnd()
    }

    func suppressUntilMeetingEnd() {
        guard isEnabled else { return }
        switch state {
        case .starting:
            invalidateTimer()
            state = .suppressedUntilMeetingEnd
            onCommand?(.cancelAutomaticStart)
            return
        case .stopCountdown where !isInMeeting:
            suppressesStopCommandUntilEndDebounce = true
            return
        case .automaticRecording, .stopCountdown:
            invalidateTimer()
        default:
            invalidateTimer()
        }
        state = .suppressedUntilMeetingEnd
    }

    func automaticStartSucceeded() {
        guard state == .starting else { return }
        state = .automaticRecording
    }

    func automaticStartBlocked(_ message: String) {
        guard state == .starting else { return }
        state = .startBlocked(message)
    }

    func automaticStartFailed(_ message: String) {
        guard state == .starting else { return }
        state = .startFailed(message)
    }

    func automaticStopCompleted() {
        guard case .stopCountdown = state else { return }
        invalidateTimer()
        state = .waitingForMeeting
    }

    func invalidate() {
        invalidateTimer()
        isEnabled = false
        isInMeeting = false
        onStateChange = nil
        onCommand = nil
        state = .disabled
    }

    private func beginTimer(_ kind: TimerKind, seconds: Int) {
        invalidateTimer()
        let expectedGeneration = generation
        let expectedState: TeamsAutoMeetingState
        let expectedIsInMeeting: Bool
        switch kind {
        case .start:
            expectedState = .startCountdown(secondsRemaining: seconds)
            expectedIsInMeeting = true
        case .stop:
            expectedState = .stopCountdown(secondsRemaining: seconds)
            expectedIsInMeeting = false
        }
        state = expectedState
        guard generation == expectedGeneration,
              isEnabled,
              isInMeeting == expectedIsInMeeting,
              state == expectedState else { return }
        let tick = self.tick
        timerTask = Task { @MainActor [weak self, tick] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                await tick()
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration else { return }
                if remaining > 0 {
                    switch kind {
                    case .start:
                        self.state = .startCountdown(secondsRemaining: remaining)
                    case .stop:
                        self.state = .stopCountdown(secondsRemaining: remaining)
                    }
                } else {
                    self.timerTask = nil
                    switch kind {
                    case .start:
                        self.state = .starting
                        guard self.generation == expectedGeneration,
                              self.isEnabled,
                              self.isInMeeting,
                              self.state == .starting else { return }
                        self.onCommand?(.startRecording)
                    case .stop:
                        if self.suppressesStopCommandUntilEndDebounce {
                            self.suppressesStopCommandUntilEndDebounce = false
                            self.state = .waitingForMeeting
                        } else {
                            self.onCommand?(.stopRecording)
                        }
                    }
                }
            }
        }
    }

    private func invalidateTimer() {
        timerTask?.cancel()
        timerTask = nil
        suppressesStopCommandUntilEndDebounce = false
        generation &+= 1
    }
}
