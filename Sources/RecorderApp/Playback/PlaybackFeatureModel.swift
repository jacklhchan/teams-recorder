import Combine
import Foundation

private final class PlaybackFeatureDeinitCleanup: @unchecked Sendable {
    private let coordinator: any PlaybackCoordinating

    init(coordinator: any PlaybackCoordinating) {
        self.coordinator = coordinator
    }

    @MainActor
    func perform() {
        coordinator.onSnapshot = nil
        coordinator.stop()
    }
}

@MainActor
final class PlaybackFeatureModel: ObservableObject {
    let presentation: PlaybackPresentationModel

    @Published private(set) var activeSessionID: RecordingSession.ID?

    var onStatusMessage: ((String) -> Void)?

    private let coordinator: any PlaybackCoordinating
    private var loadTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var isShutdown = false

    init(coordinator: any PlaybackCoordinating) {
        self.coordinator = coordinator
        presentation = PlaybackPresentationModel(player: coordinator.player)
        coordinator.onSnapshot = { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    deinit {
        loadTask?.cancel()
        seekTask?.cancel()
        let cleanup = PlaybackFeatureDeinitCleanup(coordinator: coordinator)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                cleanup.perform()
            }
        } else {
            DispatchQueue.main.async {
                cleanup.perform()
            }
        }
    }

    func play(_ session: RecordingSession, successStatus: String) {
        guard !isShutdown else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        cancelSeek()
        coordinator.stop()
        presentation.begin(session: session)
        activeSessionID = session.id

        let coordinator = coordinator
        loadTask = Task { [weak self, coordinator] in
            do {
                try await coordinator.load(session)
                guard !Task.isCancelled,
                      let self,
                      !self.isShutdown,
                      self.loadGeneration == generation,
                      self.activeSessionID == session.id else { return }
                coordinator.play()
                self.onStatusMessage?(successStatus)
                self.loadTask = nil
            } catch {
                guard !Task.isCancelled,
                      let self,
                      !self.isShutdown,
                      self.loadGeneration == generation,
                      self.activeSessionID == session.id else { return }
                self.loadTask = nil
                self.activeSessionID = nil
                self.presentation.clear()
                self.onStatusMessage?(
                    "Playback failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func toggle() {
        guard activeSessionID != nil, !isShutdown else { return }
        if presentation.isPlaying {
            coordinator.pause()
        } else {
            coordinator.play()
        }
    }

    func seek(to time: TimeInterval) {
        guard activeSessionID != nil, !isShutdown else { return }
        let generation = loadGeneration
        seekGeneration &+= 1
        let requestGeneration = seekGeneration
        seekTask?.cancel()
        let coordinator = coordinator
        seekTask = Task { [weak self, coordinator] in
            await coordinator.seek(to: time)
            guard let self,
                  !self.isShutdown,
                  !Task.isCancelled,
                  self.loadGeneration == generation,
                  self.seekGeneration == requestGeneration else { return }
            self.seekTask = nil
        }
    }

    func stop() {
        guard !isShutdown else { return }
        stopOwnedPlayback()
    }

    func stopIfActive(sessionID: RecordingSession.ID) {
        guard activeSessionID == sessionID, !isShutdown else { return }
        stopOwnedPlayback()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        cancelSeek()
        activeSessionID = nil
        presentation.clear()
        coordinator.onSnapshot = nil
        coordinator.stop()
    }

    private func stopOwnedPlayback() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        cancelSeek()
        activeSessionID = nil
        coordinator.stop()
        presentation.clear()
    }

    private func handle(_ snapshot: PlaybackSnapshot) {
        guard !isShutdown, snapshot.sessionID == activeSessionID else { return }
        presentation.apply(snapshot)
    }

    private func cancelSeek() {
        seekGeneration &+= 1
        seekTask?.cancel()
        seekTask = nil
    }
}
