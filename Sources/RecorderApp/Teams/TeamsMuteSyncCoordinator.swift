import Foundation

@MainActor
final class TeamsMuteSyncCoordinator {
    private let controller: any TeamsMuteControlling
    private let microphoneMuteGate: MicrophoneMuteGate
    private let tick: @Sendable () async -> Void
    private var pollTask: Task<Void, Never>?
    private var pollingProcessID: pid_t?

    private(set) var state: TeamsMicMuteState = .unknown(.inactive) {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((TeamsMicMuteState) -> Void)?
    var onMuteSnapshotChange: ((MicrophoneMuteSnapshot) -> Void)?

    var hasPollingTask: Bool { pollTask != nil }

    init(
        controller: any TeamsMuteControlling,
        microphoneMuteGate: MicrophoneMuteGate,
        tick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    ) {
        self.controller = controller
        self.microphoneMuteGate = microphoneMuteGate
        self.tick = tick
    }

    deinit {
        pollTask?.cancel()
    }

    func updatePolling(
        isPanelActive: Bool,
        isRecording: Bool,
        processID: pid_t?
    ) {
        guard isPanelActive, isRecording, let processID else {
            stopPolling()
            return
        }
        guard pollTask == nil || pollingProcessID != processID else { return }

        stopPolling()
        pollingProcessID = processID
        let controller = self.controller
        let tick = self.tick
        pollTask = Task { @MainActor [weak self, controller, tick] in
            while !Task.isCancelled {
                await tick()
                guard !Task.isCancelled, let self,
                      self.pollingProcessID == processID else { return }
                let observation = await controller.readState(
                    processID: processID
                )
                guard !Task.isCancelled,
                      self.pollingProcessID == processID else { return }
                self.applyObservation(observation)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollingProcessID = nil
        state = .unknown(.inactive)
    }

    func resetTeamsSource() {
        stopPolling()
        publishMuteSnapshot(microphoneMuteGate.setTeamsMuted(false))
    }

    func setMuted(
        _ muted: Bool,
        processID: pid_t?
    ) async -> TeamsMicMuteState {
        guard let processID else {
            publishMuteSnapshot(microphoneMuteGate.setLocalMuted(muted))
            return .unknown(.inactive)
        }

        if muted {
            publishMuteSnapshot(microphoneMuteGate.setLocalMuted(true))
            let result = await controller.setMuted(true, processID: processID)
            applyObservation(result)
            return result
        }

        let result = await controller.setMuted(false, processID: processID)
        applyObservation(result)
        if result == .unmuted {
            publishMuteSnapshot(microphoneMuteGate.setLocalMuted(false))
        }
        return result
    }

    func requestPermission() {
        controller.requestPermission()
    }

    private func applyObservation(_ observation: TeamsMicMuteState) {
        state = observation
        switch observation {
        case .muted:
            publishMuteSnapshot(microphoneMuteGate.setTeamsMuted(true))
        case .unmuted:
            publishMuteSnapshot(microphoneMuteGate.setTeamsMuted(false))
        case .unknown:
            break
        }
    }

    private func publishMuteSnapshot(_ snapshot: MicrophoneMuteSnapshot) {
        onMuteSnapshotChange?(snapshot)
    }
}
