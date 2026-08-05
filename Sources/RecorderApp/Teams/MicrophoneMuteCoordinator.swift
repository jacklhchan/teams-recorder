import Foundation

struct MicrophoneMuteCoordinator {
    private(set) var localMuted: Bool
    private(set) var nativeInputMuted = false
    private(set) var teamsMuted = false

    init(localMuted: Bool = false) {
        self.localMuted = localMuted
    }

    var effectiveMuted: Bool {
        localMuted || nativeInputMuted || teamsMuted
    }

    @discardableResult
    mutating func setLocalMuted(_ muted: Bool) -> Bool? {
        let previous = effectiveMuted
        localMuted = muted
        return transition(from: previous)
    }

    @discardableResult
    mutating func setNativeInputMuted(_ muted: Bool) -> Bool? {
        let previous = effectiveMuted
        nativeInputMuted = muted
        return transition(from: previous)
    }

    @discardableResult
    mutating func setTeamsMuted(_ muted: Bool) -> Bool? {
        let previous = effectiveMuted
        teamsMuted = muted
        return transition(from: previous)
    }

    private func transition(from previous: Bool) -> Bool? {
        let current = effectiveMuted
        return current == previous ? nil : current
    }
}

struct MicrophoneMuteSnapshot: Equatable, Sendable {
    let localMuted: Bool
    let nativeInputMuted: Bool
    let teamsMuted: Bool
    let effectiveMuted: Bool
}

final class MicrophoneMuteGate: @unchecked Sendable {
    private let stateLock = NSLock()
    private let transitionLock = NSRecursiveLock()
    private let applyMuteToAudioPaths: (Bool) -> Void
    private var coordinator: MicrophoneMuteCoordinator
    private var hasAppliedMute = false
    private var isApplyingMute = false
    private var pendingAudioMute: Bool?

    init(
        localMuted: Bool = false,
        applyMuteToAudioPaths: @escaping (Bool) -> Void
    ) {
        coordinator = MicrophoneMuteCoordinator(localMuted: localMuted)
        self.applyMuteToAudioPaths = applyMuteToAudioPaths
    }

    var snapshot: MicrophoneMuteSnapshot {
        stateLock.withLock {
            makeSnapshot()
        }
    }

    @discardableResult
    func setLocalMuted(
        _ muted: Bool,
        ensureAudioGateIsApplied: Bool = false
    ) -> MicrophoneMuteSnapshot {
        applyTransition {
            let transition = coordinator.setLocalMuted(muted)
            return (transition, ensureAudioGateIsApplied)
        }
    }

    @discardableResult
    func setNativeInputMuted(
        _ muted: Bool,
        ensureAudioGateIsApplied: Bool = false
    ) -> MicrophoneMuteSnapshot {
        applyTransition {
            let transition = coordinator.setNativeInputMuted(muted)
            return (transition, ensureAudioGateIsApplied)
        }
    }

    @discardableResult
    func setTeamsMuted(
        _ muted: Bool,
        ensureAudioGateIsApplied: Bool = false
    ) -> MicrophoneMuteSnapshot {
        applyTransition {
            let transition = coordinator.setTeamsMuted(muted)
            return (transition, ensureAudioGateIsApplied)
        }
    }

    private func applyTransition(
        update: () -> (transition: Bool?, ensureAudioGateIsApplied: Bool)
    ) -> MicrophoneMuteSnapshot {
        transitionLock.lock()
        defer { transitionLock.unlock() }

        let result: (muted: Bool?, snapshot: MicrophoneMuteSnapshot) =
            stateLock.withLock {
                let update = update()
                let muted = update.transition
                    ?? (update.ensureAudioGateIsApplied && !hasAppliedMute
                        ? coordinator.effectiveMuted
                        : nil)
                if muted != nil {
                    hasAppliedMute = true
                }
                return (muted, makeSnapshot())
            }

        guard let muted = result.muted else {
            return result.snapshot
        }

        if isApplyingMute {
            pendingAudioMute = muted
            return result.snapshot
        }

        isApplyingMute = true
        defer {
            isApplyingMute = false
            pendingAudioMute = nil
        }

        var nextMute: Bool? = muted
        while let mute = nextMute {
            pendingAudioMute = nil
            applyMuteToAudioPaths(mute)
            nextMute = pendingAudioMute
        }

        return stateLock.withLock {
            makeSnapshot()
        }
    }

    private func makeSnapshot() -> MicrophoneMuteSnapshot {
        MicrophoneMuteSnapshot(
            localMuted: coordinator.localMuted,
            nativeInputMuted: coordinator.nativeInputMuted,
            teamsMuted: coordinator.teamsMuted,
            effectiveMuted: coordinator.effectiveMuted
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
