@preconcurrency import AVFoundation
import XCTest
@testable import RecorderApp

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    func testLoadPlayPauseSeekAndStopPublishesClampedSnapshotsForM4A() async throws {
        let fixture = try makeFixture(extension: "m4a")
        let observer = TestPlaybackObserver()
        let coordinator = PlaybackCoordinator(player: AVPlayer(), observer: observer)
        var snapshots: [PlaybackSnapshot] = []
        coordinator.onSnapshot = { snapshots.append($0) }

        let isPlayable = try await AVURLAsset(url: fixture.session.recordingURL).load(.isPlayable)
        XCTAssertTrue(isPlayable)
        try await coordinator.load(fixture.session)
        XCTAssertEqual(observer.periodicIntervals, [CMTime(value: 1, timescale: 10)])
        coordinator.play()
        observer.firePeriodic(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        coordinator.pause()
        await coordinator.seek(to: 999)

        XCTAssertTrue(snapshots.contains(where: \.isPlaying))
        XCTAssertFalse(try XCTUnwrap(snapshots.last).isPlaying)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).progress, fixture.duration, accuracy: 0.05)

        coordinator.stop()
        XCTAssertEqual(try XCTUnwrap(snapshots.last), .empty)
        XCTAssertNil(coordinator.player.currentItem)
    }

    func testLoadsMP4AndOnlyExactCurrentItemCompletionStopsPlayback() async throws {
        let first = try makeFixture(extension: "mp4")
        let second = try makeFixture(extension: "mp4")
        let observer = TestPlaybackObserver()
        let coordinator = PlaybackCoordinator(player: AVPlayer(), observer: observer)
        var snapshots: [PlaybackSnapshot] = []
        coordinator.onSnapshot = { snapshots.append($0) }

        let firstIsPlayable = try await AVURLAsset(url: first.session.recordingURL).load(.isPlayable)
        let secondIsPlayable = try await AVURLAsset(url: second.session.recordingURL).load(.isPlayable)
        XCTAssertTrue(firstIsPlayable)
        XCTAssertTrue(secondIsPlayable)
        try await coordinator.load(first.session)
        let firstToken = try XCTUnwrap(observer.endTokens.last)
        try await coordinator.load(second.session)
        let secondToken = try XCTUnwrap(observer.endTokens.last)

        XCTAssertEqual(observer.observedItems.count, 2)
        XCTAssertTrue(observer.observedItems[1] === coordinator.player.currentItem)

        observer.fireEnd(token: firstToken)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).sessionID, second.session.id)

        observer.fireStaleEnd(token: firstToken)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).sessionID, second.session.id)

        coordinator.play()
        observer.fireEnd(token: secondToken)
        XCTAssertFalse(try XCTUnwrap(snapshots.last).isPlaying)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).progress, 0, accuracy: 0.001)
    }

    func testReplacementStopAndDeinitRemovePeriodicAndEndObservers() async throws {
        let first = try makeFixture(extension: "m4a")
        let second = try makeFixture(extension: "m4a")
        let observer = TestPlaybackObserver()
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(player: AVPlayer(), observer: observer)

        try await coordinator?.load(first.session)
        try await coordinator?.load(second.session)
        XCTAssertEqual(observer.removedPeriodicCount, 1)
        XCTAssertEqual(observer.removedEndCount, 1)

        coordinator?.stop()
        XCTAssertEqual(observer.removedPeriodicCount, 2)
        XCTAssertEqual(observer.removedEndCount, 2)

        coordinator = nil
        XCTAssertEqual(observer.removedPeriodicCount, 2)
        XCTAssertEqual(observer.removedEndCount, 2)

        let deinitObserver = TestPlaybackObserver()
        var deinitializingCoordinator: PlaybackCoordinator? = PlaybackCoordinator(player: AVPlayer(), observer: deinitObserver)
        try await deinitializingCoordinator?.load(first.session)
        deinitializingCoordinator = nil
        XCTAssertEqual(deinitObserver.removedPeriodicCount, 1)
        XCTAssertEqual(deinitObserver.removedEndCount, 1)
    }

    func testUnknownDurationCanOnlySeekToZero() async throws {
        let fixture = try makeFixture(extension: "m4a")
        let observer = TestPlaybackObserver()
        observer.loadedDuration = .invalid
        let coordinator = PlaybackCoordinator(player: AVPlayer(), observer: observer)
        var snapshots: [PlaybackSnapshot] = []
        coordinator.onSnapshot = { snapshots.append($0) }

        try await coordinator.load(fixture.session)
        await coordinator.seek(to: 12)

        XCTAssertEqual(try XCTUnwrap(snapshots.last).progress, 0, accuracy: 0.001)
    }

    func testInFlightSeekCannotPolluteReplacementSession() async throws {
        let first = try makeFixture(extension: "m4a")
        let second = try makeFixture(extension: "mp4")
        let observer = TestPlaybackObserver()
        observer.suspendSeeks = true
        let coordinator = PlaybackCoordinator(player: AVPlayer(), observer: observer)
        var snapshots: [PlaybackSnapshot] = []
        coordinator.onSnapshot = { snapshots.append($0) }

        try await coordinator.load(first.session)
        let firstItem = try XCTUnwrap(coordinator.player.currentItem)
        let seekTask = Task { await coordinator.seek(to: 0.75) }
        for _ in 0..<300 where observer.pendingSeekCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(observer.pendingSeekCount, 1, "Seek must be suspended before replacing playback")

        try await coordinator.load(second.session)
        let replacementSnapshotCount = snapshots.count
        observer.finishPendingSeeks()
        await seekTask.value

        XCTAssertTrue(observer.seekItems.first === firstItem)
        XCTAssertTrue(observer.cancelledSeekItems.contains(where: { $0 === firstItem }))
        XCTAssertEqual(snapshots.count, replacementSnapshotCount)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).sessionID, second.session.id)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).progress, 0, accuracy: 0.001)
    }

    func testInterruptedSameItemSeekCannotPublishStaleProgress() async throws {
        let fixture = try makeFixture(extension: "mp4")
        let observer = TestPlaybackObserver()
        observer.suspendSeeks = true
        let coordinator = PlaybackCoordinator(player: AVPlayer(), observer: observer)
        var snapshots: [PlaybackSnapshot] = []
        coordinator.onSnapshot = { snapshots.append($0) }

        try await coordinator.load(fixture.session)
        let olderSeek = Task { await coordinator.seek(to: 0.25) }
        for _ in 0..<300 where observer.pendingSeekCount < 1 {
            await Task.yield()
        }
        let newerSeek = Task { await coordinator.seek(to: 0.75) }
        for _ in 0..<300 where observer.pendingSeekCount < 2 {
            await Task.yield()
        }
        XCTAssertEqual(observer.pendingSeekCount, 2)

        observer.finishNewestPendingSeek(succeeded: true)
        await newerSeek.value
        XCTAssertEqual(try XCTUnwrap(snapshots.last).progress, 0.75, accuracy: 0.001)
        let snapshotCountAfterNewerSeek = snapshots.count

        observer.finishOldestPendingSeek(succeeded: false)
        await olderSeek.value
        XCTAssertEqual(snapshots.count, snapshotCountAfterNewerSeek)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).progress, 0.75, accuracy: 0.001)
    }

    func testCurrentLoadDurationFailureResetsItemObserversAndSnapshot() async throws {
        let first = try makeFixture(extension: "m4a")
        let second = try makeFixture(extension: "m4a")
        let observer = TestPlaybackObserver()
        let coordinator = PlaybackCoordinator(player: AVPlayer(), observer: observer)
        var snapshots: [PlaybackSnapshot] = []
        coordinator.onSnapshot = { snapshots.append($0) }

        try await coordinator.load(first.session)
        observer.durationError = TestPlaybackError.durationUnavailable

        do {
            try await coordinator.load(second.session)
            XCTFail("Expected duration loading to fail")
        } catch TestPlaybackError.durationUnavailable {
            // Expected.
        }

        XCTAssertNil(coordinator.player.currentItem)
        XCTAssertEqual(observer.removedPeriodicCount, 1)
        XCTAssertEqual(observer.removedEndCount, 1)
        XCTAssertEqual(snapshots.last, .empty)
    }

    func testOffMainFinalReleaseRemovesObserversExactlyOnce() async throws {
        let fixture = try makeFixture(extension: "m4a")
        let observer = TestPlaybackObserver()
        let removed = expectation(description: "observers removed after off-main final release")
        observer.onBothObserversRemoved = { removed.fulfill() }
        let releaseBox = OffMainReleaseBox()
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(player: AVPlayer(), observer: observer)

        try await coordinator?.load(fixture.session)
        releaseBox.store(coordinator)
        coordinator = nil

        await Task.detached {
            releaseBox.release()
        }.value
        await fulfillment(of: [removed], timeout: 1)

        XCTAssertEqual(observer.removedPeriodicCount, 1)
        XCTAssertEqual(observer.removedEndCount, 1)
    }
}

@MainActor
private final class TestPlaybackObserver: PlaybackObserving {
    private final class Token {}
    private struct PendingSeek {
        let item: AVPlayerItem
        let continuation: CheckedContinuation<Bool, Never>
    }

    var loadedDuration: CMTime? = CMTime(seconds: 1, preferredTimescale: 600)
    var durationError: Error?
    var suspendSeeks = false
    var onBothObserversRemoved: (() -> Void)?
    private(set) var endTokens: [Any] = []
    private(set) var observedItems: [AVPlayerItem] = []
    private(set) var seekItems: [AVPlayerItem] = []
    private(set) var cancelledSeekItems: [AVPlayerItem] = []
    private(set) var pendingSeekCount = 0
    private(set) var periodicIntervals: [CMTime] = []
    private(set) var removedPeriodicCount = 0
    private(set) var removedEndCount = 0
    private var endHandlers: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]
    private var allEndHandlers: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]
    private var periodicHandlers: [ObjectIdentifier: @MainActor @Sendable (CMTime) -> Void] = [:]
    private var pendingSeeks: [PendingSeek] = []
    private var hasReportedBothRemovals = false

    func duration(for item: AVPlayerItem) async throws -> CMTime {
        if let durationError { throw durationError }
        return loadedDuration ?? .zero
    }

    func seek(_ item: AVPlayerItem, to _: CMTime) async -> Bool {
        seekItems.append(item)
        guard suspendSeeks else { return true }
        pendingSeekCount += 1
        return await withCheckedContinuation { continuation in
            pendingSeeks.append(PendingSeek(item: item, continuation: continuation))
        }
    }

    func cancelPendingSeeks(for item: AVPlayerItem) {
        cancelledSeekItems.append(item)
        resumeSeek(for: item)
    }

    func addPeriodicTimeObserver(to player: AVPlayer, interval: CMTime, using block: @escaping @MainActor @Sendable (CMTime) -> Void) -> Any {
        let token = Token()
        periodicIntervals.append(interval)
        periodicHandlers[ObjectIdentifier(token)] = block
        return token
    }

    func removePeriodicTimeObserver(_ token: Any, from player: AVPlayer) {
        removedPeriodicCount += 1
        if let token = token as? Token {
            periodicHandlers.removeValue(forKey: ObjectIdentifier(token))
        }
        reportBothObserversRemovedIfNeeded()
    }

    func addEndObserver(for item: AVPlayerItem, using block: @escaping @MainActor @Sendable () -> Void) -> Any {
        let token = Token()
        endTokens.append(token)
        observedItems.append(item)
        endHandlers[ObjectIdentifier(token)] = block
        allEndHandlers[ObjectIdentifier(token)] = block
        return token
    }

    func removeEndObserver(_ token: Any) {
        removedEndCount += 1
        if let token = token as? Token {
            endHandlers.removeValue(forKey: ObjectIdentifier(token))
        }
        reportBothObserversRemovedIfNeeded()
    }

    func fireEnd(token: Any) {
        guard let token = token as? Token else { return }
        endHandlers[ObjectIdentifier(token)]?()
    }

    func fireStaleEnd(token: Any) {
        guard let token = token as? Token else { return }
        allEndHandlers[ObjectIdentifier(token)]?()
    }

    func firePeriodic(at time: CMTime) {
        periodicHandlers.values.forEach { $0(time) }
    }

    func finishPendingSeeks() {
        let pending = pendingSeeks
        pendingSeeks.removeAll()
        pendingSeekCount = 0
        pending.forEach { $0.continuation.resume(returning: true) }
    }

    func finishNewestPendingSeek(succeeded: Bool) {
        guard let pending = pendingSeeks.popLast() else { return }
        pendingSeekCount -= 1
        pending.continuation.resume(returning: succeeded)
    }

    func finishOldestPendingSeek(succeeded: Bool) {
        guard !pendingSeeks.isEmpty else { return }
        let pending = pendingSeeks.removeFirst()
        pendingSeekCount -= 1
        pending.continuation.resume(returning: succeeded)
    }

    private func resumeSeek(for item: AVPlayerItem) {
        var cancelled: [PendingSeek] = []
        pendingSeeks.removeAll { pending in
            guard pending.item === item else { return false }
            cancelled.append(pending)
            return true
        }
        pendingSeekCount -= cancelled.count
        cancelled.forEach { $0.continuation.resume(returning: false) }
    }

    private func reportBothObserversRemovedIfNeeded() {
        guard !hasReportedBothRemovals, removedPeriodicCount > 0, removedEndCount > 0 else { return }
        hasReportedBothRemovals = true
        onBothObserversRemoved?()
    }
}

private enum TestPlaybackError: Error {
    case durationUnavailable
}

private final class OffMainReleaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlaybackCoordinator?

    func store(_ coordinator: PlaybackCoordinator?) {
        lock.lock()
        value = coordinator
        lock.unlock()
    }

    func release() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

private extension PlaybackCoordinatorTests {
    struct Fixture {
        let session: RecordingSession
        let duration: TimeInterval
    }

    func makeFixture(extension fileExtension: String) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recordingURL = folder.appendingPathComponent("recording.\(fileExtension)")
        let duration = try SyntheticPlayableMedia.write(to: recordingURL, fileExtension: fileExtension)
        return Fixture(
            session: RecordingSessionStore.session(for: folder, recordingURL: recordingURL),
            duration: duration
        )
    }
}

private enum SyntheticPlayableMedia {
    static func write(to url: URL, fileExtension: String) throws -> TimeInterval {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileExtension == "mp4" ? .mp4 : .m4a)
        let output = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
        )
        guard writer.canAdd(output) else { throw TestMediaError.cannotStart }
        writer.add(output)
        guard writer.startWriting() else { throw writer.error ?? TestMediaError.cannotStart }
        writer.startSession(atSourceTime: .zero)
        guard output.append(try audioSample(frameCount: 44_100)) else {
            throw writer.error ?? TestMediaError.cannotStart
        }
        output.markAsFinished()
        let completion = DispatchSemaphore(value: 0)
        writer.finishWriting { completion.signal() }
        guard completion.wait(timeout: .now() + 5) == .success, writer.status == .completed else {
            throw writer.error ?? TestMediaError.cannotFinish
        }
        return 1
    }

    private static func audioSample(frameCount: Int) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &format,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            throw TestMediaError.cannotStart
        }

        let samples = [Int16](repeating: 0, count: frameCount)
        var blockBuffer: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Int16>.size
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            throw TestMediaError.cannotStart
        }
        let replaceStatus = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaceStatus == kCMBlockBufferNoErr else { throw TestMediaError.cannotStart }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = MemoryLayout<Int16>.size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw TestMediaError.cannotStart
        }
        return sample
    }

    enum TestMediaError: Error { case cannotStart, cannotFinish }
}
