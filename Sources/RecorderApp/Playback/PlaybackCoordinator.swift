@preconcurrency import AVFoundation
import Foundation

struct PlaybackSnapshot: Equatable {
    let sessionID: RecordingSession.ID?
    let progress: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    static let empty = PlaybackSnapshot(sessionID: nil, progress: 0, duration: 0, isPlaying: false)
}

@MainActor
protocol PlaybackCoordinating: AnyObject {
    var player: AVPlayer { get }
    var onSnapshot: ((PlaybackSnapshot) -> Void)? { get set }

    func load(_ session: RecordingSession) async throws
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    func stop()
}

@MainActor
protocol PlaybackObserving: AnyObject {
    func duration(for item: AVPlayerItem) async throws -> CMTime
    func addPeriodicTimeObserver(to player: AVPlayer, interval: CMTime, using block: @escaping @MainActor @Sendable (CMTime) -> Void) -> Any
    func removePeriodicTimeObserver(_ token: Any, from player: AVPlayer)
    func addEndObserver(for item: AVPlayerItem, using block: @escaping @MainActor @Sendable () -> Void) -> Any
    func removeEndObserver(_ token: Any)
}

@MainActor
final class PlaybackCoordinator: PlaybackCoordinating {
    let player: AVPlayer
    var onSnapshot: ((PlaybackSnapshot) -> Void)?

    private let observer: PlaybackObserving
    private let periodicInterval = CMTime(value: 1, timescale: 10)
    private var periodicObserver: Any?
    private var endObserver: Any?
    private var currentItem: AVPlayerItem?
    private var currentSessionID: RecordingSession.ID?
    private var duration: TimeInterval = 0
    private var isPlaying = false
    private var generation = 0

    init(player: AVPlayer, observer: PlaybackObserving) {
        self.player = player
        self.observer = observer
    }

    convenience init() {
        self.init(player: AVPlayer(), observer: AVPlayerPlaybackObserver())
    }

    isolated deinit {
        removeObserversAndItem()
    }

    func load(_ session: RecordingSession) async throws {
        generation += 1
        let loadGeneration = generation
        removeObserversAndItem()

        let item = AVPlayerItem(url: session.recordingURL)
        player.replaceCurrentItem(with: item)
        currentItem = item
        currentSessionID = session.id
        duration = 0
        isPlaying = false

        let loadedDuration: CMTime
        do {
            loadedDuration = try await observer.duration(for: item)
        } catch {
            guard generation == loadGeneration, currentItem === item else { throw error }
            removeObserversAndItem()
            onSnapshot?(.empty)
            throw error
        }
        guard generation == loadGeneration, currentItem === item else { return }

        duration = sanitizedDuration(loadedDuration)
        installObservers(for: item, generation: loadGeneration)
        publish(progress: 0)
    }

    func play() {
        guard currentItem != nil else { return }
        player.play()
        isPlaying = true
        publish(progress: currentProgress)
    }

    func pause() {
        guard currentItem != nil else { return }
        player.pause()
        isPlaying = false
        publish(progress: currentProgress)
    }

    func seek(to seconds: TimeInterval) async {
        guard currentItem != nil else { return }
        let target = clamped(seconds)
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        publish(progress: target)
    }

    func stop() {
        generation += 1
        removeObserversAndItem()
        onSnapshot?(.empty)
    }

    private func installObservers(for item: AVPlayerItem, generation: Int) {
        periodicObserver = observer.addPeriodicTimeObserver(to: player, interval: periodicInterval) { [weak self, weak item] time in
            guard let self, let item, self.generation == generation, self.currentItem === item else { return }
            self.publish(progress: self.clamped(CMTimeGetSeconds(time)))
        }
        endObserver = observer.addEndObserver(for: item) { [weak self, weak item] in
            guard let self, let item, self.generation == generation, self.currentItem === item else { return }
            self.player.pause()
            self.player.seek(to: .zero)
            self.isPlaying = false
            self.publish(progress: 0)
        }
    }

    private func removeObserversAndItem() {
        player.pause()
        if let periodicObserver {
            observer.removePeriodicTimeObserver(periodicObserver, from: player)
            self.periodicObserver = nil
        }
        if let endObserver {
            observer.removeEndObserver(endObserver)
            self.endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        currentSessionID = nil
        duration = 0
        isPlaying = false
    }

    private var currentProgress: TimeInterval {
        clamped(CMTimeGetSeconds(player.currentTime()))
    }

    private func clamped(_ seconds: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        guard !seconds.isNaN else { return 0 }
        return min(max(seconds, 0), duration)
    }

    private func sanitizedDuration(_ time: CMTime) -> TimeInterval {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    private func publish(progress: TimeInterval) {
        onSnapshot?(PlaybackSnapshot(
            sessionID: currentSessionID,
            progress: clamped(progress),
            duration: duration,
            isPlaying: isPlaying
        ))
    }
}

@MainActor
private final class AVPlayerPlaybackObserver: PlaybackObserving {
    func duration(for item: AVPlayerItem) async throws -> CMTime {
        try await item.asset.load(.duration)
    }

    func addPeriodicTimeObserver(to player: AVPlayer, interval: CMTime, using block: @escaping @MainActor @Sendable (CMTime) -> Void) -> Any {
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { @Sendable time in
            // AVFoundation invokes this closure on the explicitly selected main queue.
            MainActor.assumeIsolated {
                block(time)
            }
        }
    }

    func removePeriodicTimeObserver(_ token: Any, from player: AVPlayer) {
        player.removeTimeObserver(token)
    }

    func addEndObserver(for item: AVPlayerItem, using block: @escaping @MainActor @Sendable () -> Void) -> Any {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { @Sendable _ in
            // NotificationCenter delivers this observer on the explicitly selected main queue.
            MainActor.assumeIsolated {
                block()
            }
        }
    }

    func removeEndObserver(_ token: Any) {
        NotificationCenter.default.removeObserver(token)
    }
}
