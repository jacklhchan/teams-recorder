import Foundation

struct TeamsMuteRelayResult: Equatable, Sendable {
    let didFailClosed: Bool
}

final class TeamsMuteRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let microphoneMuteGate: MicrophoneMuteGate
    private var generation: UInt64 = 0
    private var isEnabled = false
    private var lastMeetingState: TeamsMeetingState?

    init(microphoneMuteGate: MicrophoneMuteGate) {
        self.microphoneMuteGate = microphoneMuteGate
    }

    func enable() -> UInt64 {
        lock.withLock {
            generation &+= 1
            isEnabled = true
            lastMeetingState = nil
            return generation
        }
    }

    func disable() -> MicrophoneMuteSnapshot {
        lock.withLock {
            generation &+= 1
            isEnabled = false
            lastMeetingState = nil
            return microphoneMuteGate.applyTeamsState(
                TeamsMeetingState(
                    isInMeeting: false,
                    isMuted: false,
                    canToggleMute: false,
                    canPair: false
                )
            )
        }
    }

    func invalidate() {
        lock.withLock {
            generation &+= 1
            isEnabled = false
            lastMeetingState = nil
        }
    }

    func apply(
        _ event: TeamsMuteSyncEvent,
        generation expectedGeneration: UInt64
    ) -> TeamsMuteRelayResult? {
        lock.withLock {
            guard isEnabled, generation == expectedGeneration else {
                return nil
            }

            switch event {
            case .meetingState(let state):
                lastMeetingState = state
                microphoneMuteGate.applyTeamsState(state)
                return TeamsMuteRelayResult(didFailClosed: false)

            case .status(let status):
                guard lastMeetingState?.isInMeeting == true,
                      statusRequiresFailClosedMute(status) else {
                    return TeamsMuteRelayResult(didFailClosed: false)
                }
                microphoneMuteGate.applyTeamsState(
                    TeamsMeetingState(
                        isInMeeting: true,
                        isMuted: true,
                        canToggleMute: false,
                        canPair: false
                    )
                )
                return TeamsMuteRelayResult(didFailClosed: true)
            }
        }
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.withLock {
            isEnabled && generation == expectedGeneration
        }
    }

    private func statusRequiresFailClosedMute(
        _ status: TeamsMuteSyncStatus
    ) -> Bool {
        switch status {
        case .connecting, .waitingForTeamsAPI, .waitingForMeeting,
             .waitingForPairingApproval, .failed:
            true
        case .disabled, .ready, .inMeeting:
            false
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
