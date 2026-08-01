@preconcurrency import AVFoundation
import XCTest
import Combine
@testable import RecorderApp

@MainActor
final class PlaybackFeatureModelTests: XCTestCase {
    func testPlaybackFeatureAcceptsOnlyCurrentLoadAndSnapshotGeneration() async {
        let coordinator = FeaturePlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let first = makeSession()
        let second = makeSession()

        feature.play(first, successStatus: "first")
        await Task.yield()
        feature.play(second, successStatus: "second")
        await Task.yield()

        coordinator.emit(.init(
            sessionID: first.id,
            progress: 9,
            duration: 12,
            isPlaying: true
        ))
        XCTAssertEqual(feature.activeSessionID, second.id)
        XCTAssertEqual(feature.presentation.session?.id, second.id)

        coordinator.emit(.init(
            sessionID: second.id,
            progress: 4,
            duration: 12,
            isPlaying: true
        ))
        XCTAssertEqual(feature.presentation.progress, 4)
        XCTAssertTrue(feature.presentation.isPlaying)
    }

    func testFailedLoadClearsOnlyTheOwnedActiveSession() async {
        let coordinator = FeaturePlaybackCoordinator()
        coordinator.loadError = FeaturePlaybackError.unavailable
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let session = makeSession()
        var statuses: [String] = []
        feature.onStatusMessage = { statuses.append($0) }

        feature.play(session, successStatus: "Playing")
        await Task.yield()

        XCTAssertNil(feature.activeSessionID)
        XCTAssertNil(feature.presentation.session)
        XCTAssertTrue(statuses.last?.contains("Playback failed") == true)
    }

    func testStopIfActiveIgnoresAnotherSessionAndStopsMatchingSession() async {
        let coordinator = FeaturePlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let session = makeSession()
        let other = makeSession()

        feature.play(session, successStatus: "Playing")
        await Task.yield()
        feature.stopIfActive(sessionID: other.id)
        XCTAssertEqual(feature.activeSessionID, session.id)

        feature.stopIfActive(sessionID: session.id)
        XCTAssertNil(feature.activeSessionID)
        XCTAssertNil(feature.presentation.session)
        XCTAssertGreaterThanOrEqual(coordinator.stopCount, 2)
    }

    func testShutdownIsIdempotentAndSuppressesLateSnapshots() async {
        let coordinator = FeaturePlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let session = makeSession()

        feature.play(session, successStatus: "Playing")
        await Task.yield()
        feature.shutdown()
        feature.shutdown()
        coordinator.emit(.init(
            sessionID: session.id,
            progress: 5,
            duration: 12,
            isPlaying: true
        ))

        XCTAssertNil(feature.activeSessionID)
        XCTAssertNil(feature.presentation.session)
        XCTAssertEqual(coordinator.stopCount, 2)
    }

    func testLatePendingLoadCannotReplaceCurrentPlaybackOrStatus() async {
        let coordinator = DelayedPlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let first = makeSession()
        let second = makeSession()
        var statuses: [String] = []
        feature.onStatusMessage = { statuses.append($0) }

        feature.play(first, successStatus: "first")
        await waitUntil { coordinator.pendingLoadIDs == [first.id] }
        feature.play(second, successStatus: "second")
        await waitUntil { coordinator.pendingLoadIDs.contains(second.id) }

        coordinator.succeedLoad(for: second.id)
        await waitUntil { coordinator.playCount == 1 }
        coordinator.failLoad(for: first.id, error: FeaturePlaybackError.unavailable)
        await Task.yield()

        XCTAssertEqual(feature.activeSessionID, second.id)
        XCTAssertEqual(feature.presentation.session?.id, second.id)
        XCTAssertEqual(coordinator.playCount, 1)
        XCTAssertEqual(statuses, ["second"])
    }

    func testLatePendingLoadSuccessCannotReplaceCurrentPlaybackOrStatus() async {
        let coordinator = DelayedPlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let first = makeSession()
        let second = makeSession()
        var statuses: [String] = []
        feature.onStatusMessage = { statuses.append($0) }

        feature.play(first, successStatus: "first")
        await waitUntil { coordinator.pendingLoadIDs == [first.id] }
        feature.play(second, successStatus: "second")
        await waitUntil { coordinator.pendingLoadIDs.contains(second.id) }

        coordinator.succeedLoad(for: second.id)
        await waitUntil { coordinator.playCount == 1 }
        coordinator.succeedLoad(for: first.id)
        await Task.yield()

        XCTAssertEqual(feature.activeSessionID, second.id)
        XCTAssertEqual(feature.presentation.session?.id, second.id)
        XCTAssertEqual(coordinator.playCount, 1)
        XCTAssertEqual(statuses, ["second"])
    }

    func testStopAndShutdownSuppressLatePendingLoadEffects() async {
        let stoppedCoordinator = DelayedPlaybackCoordinator()
        let stoppedFeature = PlaybackFeatureModel(coordinator: stoppedCoordinator)
        let stoppedSession = makeSession()
        var stoppedStatuses: [String] = []
        stoppedFeature.onStatusMessage = { stoppedStatuses.append($0) }

        stoppedFeature.play(stoppedSession, successStatus: "stopped")
        await waitUntil { stoppedCoordinator.pendingLoadIDs == [stoppedSession.id] }
        stoppedFeature.stop()
        stoppedCoordinator.succeedLoad(for: stoppedSession.id)
        await Task.yield()

        XCTAssertNil(stoppedFeature.activeSessionID)
        XCTAssertNil(stoppedFeature.presentation.session)
        XCTAssertEqual(stoppedCoordinator.playCount, 0)
        XCTAssertTrue(stoppedStatuses.isEmpty)

        let shutdownCoordinator = DelayedPlaybackCoordinator()
        let shutdownFeature = PlaybackFeatureModel(coordinator: shutdownCoordinator)
        let shutdownSession = makeSession()
        var shutdownStatuses: [String] = []
        shutdownFeature.onStatusMessage = { shutdownStatuses.append($0) }

        shutdownFeature.play(shutdownSession, successStatus: "shutdown")
        await waitUntil { shutdownCoordinator.pendingLoadIDs == [shutdownSession.id] }
        shutdownFeature.shutdown()
        shutdownCoordinator.failLoad(
            for: shutdownSession.id,
            error: FeaturePlaybackError.unavailable
        )
        await Task.yield()

        XCTAssertNil(shutdownFeature.activeSessionID)
        XCTAssertNil(shutdownFeature.presentation.session)
        XCTAssertEqual(shutdownCoordinator.playCount, 0)
        XCTAssertTrue(shutdownStatuses.isEmpty)
    }

    func testReplacementStopAndShutdownCancelDelayedSeek() async {
        let coordinator = DelayedPlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let first = makeSession()
        let second = makeSession()

        feature.play(first, successStatus: "first")
        await waitUntil { coordinator.pendingLoadIDs == [first.id] }
        coordinator.succeedLoad(for: first.id)
        await waitUntil { coordinator.playCount == 1 }
        feature.seek(to: 4)
        await waitUntil { coordinator.pendingSeekCount == 1 }
        feature.play(second, successStatus: "second")
        coordinator.finishNextSeek()
        await waitUntil { coordinator.completedSeekCancellationStates.count == 1 }

        XCTAssertEqual(coordinator.completedSeekCancellationStates, [true])
        XCTAssertEqual(feature.activeSessionID, second.id)

        coordinator.succeedLoad(for: second.id)
        await waitUntil { coordinator.playCount == 2 }
        feature.seek(to: 8)
        await waitUntil { coordinator.pendingSeekCount == 1 }
        feature.stop()
        coordinator.finishNextSeek()
        await waitUntil { coordinator.completedSeekCancellationStates.count == 2 }

        XCTAssertEqual(coordinator.completedSeekCancellationStates, [true, true])
        XCTAssertNil(feature.activeSessionID)

        feature.play(second, successStatus: "second")
        await waitUntil { coordinator.pendingLoadIDs == [second.id] }
        coordinator.succeedLoad(for: second.id)
        await waitUntil { coordinator.playCount == 3 }
        feature.seek(to: 10)
        await waitUntil { coordinator.pendingSeekCount == 1 }
        feature.shutdown()
        coordinator.finishNextSeek()
        await waitUntil { coordinator.completedSeekCancellationStates.count == 3 }

        XCTAssertEqual(coordinator.completedSeekCancellationStates, [true, true, true])
        XCTAssertNil(feature.activeSessionID)
    }

    func testPeriodicSnapshotPublishesPresentationWithoutPublishingFeature() async {
        let coordinator = FeaturePlaybackCoordinator()
        let feature = PlaybackFeatureModel(coordinator: coordinator)
        let session = makeSession()
        feature.play(session, successStatus: "Playing")
        await Task.yield()

        var featurePublicationCount = 0
        var presentationPublicationCount = 0
        let featureObservation = feature.objectWillChange.sink {
            featurePublicationCount += 1
        }
        let presentationObservation = feature.presentation.objectWillChange.sink {
            presentationPublicationCount += 1
        }
        coordinator.emit(.init(
            sessionID: session.id,
            progress: 3,
            duration: 12,
            isPlaying: true
        ))

        XCTAssertEqual(featurePublicationCount, 0)
        XCTAssertGreaterThan(presentationPublicationCount, 0)
        withExtendedLifetime((featureObservation, presentationObservation)) {}
    }

    func testDeinitClearsSnapshotCallbackAndStopsCoordinator() async {
        let coordinator = FeaturePlaybackCoordinator()
        var feature: PlaybackFeatureModel? = PlaybackFeatureModel(
            coordinator: coordinator
        )
        weak var weakFeature = feature

        feature = nil
        await waitUntil { weakFeature == nil && coordinator.onSnapshot == nil }

        XCTAssertEqual(coordinator.stopCount, 1)
    }

    private func makeSession() -> RecordingSession {
        let folder = URL(
            fileURLWithPath: "/tmp/playback-feature-\(UUID().uuidString)",
            isDirectory: true
        )
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 12,
            fileSize: 0,
            metadata: .init()
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}

@MainActor
private final class FeaturePlaybackCoordinator: PlaybackCoordinating {
    let player = AVPlayer()
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var loadError: Error?
    private(set) var stopCount = 0

    func load(_: RecordingSession) async throws {
        if let loadError { throw loadError }
    }

    func play() {}
    func pause() {}
    func seek(to _: TimeInterval) async {}
    func stop() { stopCount += 1 }
    func emit(_ snapshot: PlaybackSnapshot) { onSnapshot?(snapshot) }
}

private enum FeaturePlaybackError: LocalizedError {
    case unavailable

    var errorDescription: String? { "unavailable" }
}

@MainActor
private final class DelayedPlaybackCoordinator: PlaybackCoordinating {
    let player = AVPlayer()
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    private(set) var pendingLoadIDs: [RecordingSession.ID] = []
    private var loadContinuations: [
        RecordingSession.ID: CheckedContinuation<Void, Error>
    ] = [:]
    private var seekContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var pendingSeekCount = 0
    private(set) var completedSeekCancellationStates: [Bool] = []
    private(set) var playCount = 0
    private(set) var stopCount = 0

    func load(_ session: RecordingSession) async throws {
        pendingLoadIDs.append(session.id)
        try await withCheckedThrowingContinuation { continuation in
            loadContinuations[session.id] = continuation
        }
    }

    func play() { playCount += 1 }
    func pause() {}

    func seek(to _: TimeInterval) async {
        pendingSeekCount += 1
        await withCheckedContinuation { continuation in
            seekContinuations.append(continuation)
        }
        pendingSeekCount -= 1
        completedSeekCancellationStates.append(Task.isCancelled)
    }

    func stop() { stopCount += 1 }

    func succeedLoad(for sessionID: RecordingSession.ID) {
        pendingLoadIDs.removeAll { $0 == sessionID }
        loadContinuations.removeValue(forKey: sessionID)?.resume()
    }

    func failLoad(for sessionID: RecordingSession.ID, error: Error) {
        pendingLoadIDs.removeAll { $0 == sessionID }
        loadContinuations.removeValue(forKey: sessionID)?.resume(throwing: error)
    }

    func finishNextSeek() {
        guard !seekContinuations.isEmpty else { return }
        seekContinuations.removeFirst().resume()
    }
}
