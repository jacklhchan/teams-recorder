@preconcurrency import AVFoundation
import CoreVideo
import XCTest
@testable import RecorderApp

final class MuxedMediaWriterIntegrationTests: XCTestCase {
    func testProductionDimensionsFrameRateAndBitratesAreStable() {
        let profile = MuxedMediaProfile.production(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(profile.width, 1_600); XCTAssertEqual(profile.height, 900); XCTAssertEqual(profile.maximumFramesPerSecond, 10)
        XCTAssertEqual(profile.videoBitRate, 1_200_000); XCTAssertEqual(profile.audioBitRate, 128_000)
        let settings = MuxedMediaWriter.productionSettings(profile: profile)
        XCTAssertEqual(settings.video[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertEqual(settings.video[AVVideoWidthKey] as? Int, 1_600); XCTAssertEqual(settings.video[AVVideoHeightKey] as? Int, 900)
        XCTAssertEqual((settings.video[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? Int, 1_200_000)
        XCTAssertEqual(settings.audio[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC); XCTAssertEqual(settings.audio[AVSampleRateKey] as? Int, 48_000)
        XCTAssertEqual(settings.audio[AVNumberOfChannelsKey] as? Int, 2); XCTAssertEqual(settings.audio[AVEncoderBitRateKey] as? Int, 128_000)
    }

    func testProductionSettingsPreferButDoNotRequireHardwareHEVC() {
        let settings = MuxedMediaWriter.productionSettings(profile: .production(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        let specification = settings.video[AVVideoEncoderSpecificationKey] as? [String: Any]
        XCTAssertEqual(specification?["EnableHardwareAcceleratedVideoEncoder"] as? Bool, true)
        XCTAssertNil(specification?["RequireHardwareAcceleratedVideoEncoder"])
    }

    func testReadinessRecoveryDrainsFIFOInPTSOrderAndFinishesOnce() async throws {
        let backend = FakeBackend(readiness: false)
        let scheduler = ManualTimeoutScheduler()
        let writer = try MuxedMediaWriter(backend: backend, timeoutScheduler: scheduler)
        try writer.appendAudio(audioBlock(start: 0, frames: 24_000, value: 0.1))
        try writer.appendAudio(audioBlock(start: 24_000, frames: 24_000, value: -0.1))
        XCTAssertEqual(backend.audioPTS, [])
        let finish = Task { try await writer.finish(at: time(48_000)) }
        backend.setReady(false); backend.setReady(false); backend.setReady(true)
        await fulfillAsync { backend.finishCalls == 1 }
        backend.completeFinish()
        try await finish.value
        XCTAssertEqual(backend.audioPTS, [time(0), time(24_000)])
        XCTAssertEqual(backend.finishCalls, 1); XCTAssertEqual(backend.cancelCalls, 0)
    }

    func testAppendFalseRetainsFIFOAndFailedBackendLatchesFirstTerminalError() async throws {
        let backend = FakeBackend(readiness: true, appendResults: [false, true])
        let writer = try MuxedMediaWriter(backend: backend)
        try writer.appendAudio(audioBlock(start: 0, frames: 24_000, value: 0.1))
        XCTAssertEqual(backend.audioPTS, [])
        backend.fireReadiness()
        await fulfillAsync { backend.audioPTS.count == 1 }
        XCTAssertEqual(backend.audioPTS, [time(0)])

        let failed = FakeBackend(readiness: true, appendResults: [false], failureOnAppendFalse: "disk failed")
        let failedWriter = try MuxedMediaWriter(backend: failed)
        XCTAssertThrowsError(try failedWriter.appendAudio(audioBlock(start: 0, frames: 1, value: 0))) { error in
            XCTAssertEqual(error as? MuxedMediaWriterError, .writerFailed(description: "disk failed"))
        }
        XCTAssertThrowsError(try failedWriter.appendVideo(try! self.pixelBuffer(width: 1_600, height: 900, color: 0), at: .zero)) {
            XCTAssertEqual($0 as? MuxedMediaWriterError, .writerFailed(description: "disk failed"))
        }
    }

    func testFiveSecondFIFOBoundaryOverflowAndFirstErrorLatching() throws {
        let backend = FakeBackend(readiness: false)
        let writer = try MuxedMediaWriter(backend: backend)
        try writer.appendAudio(audioBlock(start: 0, frames: 240_000, value: 0))
        XCTAssertThrowsError(try writer.appendAudio(audioBlock(start: 240_000, frames: 1, value: 0))) { error in
            guard case .audioFIFOOverflow = error as? MuxedMediaWriterError else { return XCTFail("expected FIFO overflow") }
        }
        XCTAssertThrowsError(try writer.appendAudio(audioBlock(start: 240_001, frames: 1, value: 0))) { error in
            guard case .audioFIFOOverflow = error as? MuxedMediaWriterError else { return XCTFail("first error was lost") }
        }
    }

    func testTimeoutBeforeDrainAndAfterFinishAreExactlyOnce() async throws {
        let drainBackend = FakeBackend(readiness: false)
        let drainScheduler = ManualTimeoutScheduler()
        let drainWriter = try MuxedMediaWriter(backend: drainBackend, timeoutScheduler: drainScheduler)
        try drainWriter.appendAudio(audioBlock(start: 0, frames: 1, value: 0))
        let drainFinish = Task { try await drainWriter.finish(at: time(1)) }
        await fulfillAsync { drainScheduler.count == 1 }
        drainScheduler.fire()
        await XCTAssertThrowsErrorAsync(try await drainFinish.value) { XCTAssertEqual($0 as? MuxedMediaWriterError, .finishTimedOut) }
        XCTAssertEqual(drainBackend.cancelCalls, 1)

        let finishBackend = FakeBackend(readiness: true)
        let finishScheduler = ManualTimeoutScheduler()
        let finishWriter = try MuxedMediaWriter(backend: finishBackend, timeoutScheduler: finishScheduler)
        let lateFinish = Task { try await finishWriter.finish(at: .zero) }
        await fulfillAsync { finishBackend.finishCalls == 1 && finishScheduler.count == 1 }
        finishScheduler.fire()
        await XCTAssertThrowsErrorAsync(try await lateFinish.value) { XCTAssertEqual($0 as? MuxedMediaWriterError, .finishTimedOut) }
        finishBackend.completeFinish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(finishBackend.cancelCalls, 1)
    }

    func testClosedAndDroppableVideoAreNonTerminal() async throws {
        let backend = FakeBackend(readiness: true, videoResults: [false, true])
        let writer = try MuxedMediaWriter(backend: backend)
        XCTAssertThrowsError(try writer.appendVideo(try pixelBuffer(width: 1_600, height: 900, color: 0), at: .zero)) { XCTAssertEqual($0 as? MuxedMediaWriterError, .videoAppendDropped) }
        try writer.appendVideo(try pixelBuffer(width: 1_600, height: 900, color: 0), at: time(4_800))
        let first = Task { try await writer.finish(at: time(4_800)) }
        await fulfillAsync { backend.finishCalls == 1 }
        let second = Task { try await writer.finish(at: time(4_800)) }
        await XCTAssertThrowsErrorAsync(try await second.value) { XCTAssertEqual($0 as? MuxedMediaWriterError, .closed) }
        XCTAssertThrowsError(try writer.appendAudio(audioBlock(start: 4_800, frames: 1, value: 0))) { XCTAssertEqual($0 as? MuxedMediaWriterError, .closed) }
        backend.completeFinish(); try await first.value
    }

    func testAudioBeforeRealScreenFrameAndSeekableMP4() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let writer = try MuxedMediaWriter(url: fixture.url, profile: fixture.profile)
        try writer.appendAudio(audioBlock(start: 0, frames: 9_600, value: 0.1))
        try await appendVideo(writer, color: 0, at: .zero)
        try await appendVideo(writer, color: 80, at: time(9_600))
        try writer.appendAudio(audioBlock(start: 9_600, frames: 9_600, value: -0.1))
        try await appendVideo(writer, color: 0, at: time(14_400))
        try await writer.finish(at: time(19_200))
        let inspected = try await inspect(fixture.url, seekAt: time(9_600))
        XCTAssertEqual(inspected.video.count, 3); XCTAssertEqual(inspected.video.map(\.colorClass), [.black, .real, .black])
    }

    func testNeverEnabledScreenAndDisabledAtStopRemainValidMP4() async throws {
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let writer = try MuxedMediaWriter(url: fixture.url, profile: fixture.profile)
        try await appendVideo(writer, color: 0, at: .zero)
        try writer.appendAudio(audioBlock(start: 0, frames: 14_400, value: 0.1))
        try await appendVideo(writer, color: 0, at: time(9_600))
        try await writer.finish(at: time(14_400))
        let inspected = try await inspect(fixture.url)
        XCTAssertTrue(inspected.video.allSatisfy { $0.colorClass == .black })
        XCTAssertLessThanOrEqual(inspected.avEndDifference, 0.1 + 0.03)
    }

    func testTwoIntervalsNormalizedCanvasAndDroppedFrameThenOutput() async throws {
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let writer = try MuxedMediaWriter(url: fixture.url, profile: fixture.profile)
        try await appendVideo(writer, color: 0, at: .zero)
        try writer.appendAudio(audioBlock(start: 0, frames: 28_800, value: 0.1))
        try await appendVideo(writer, color: 50, at: time(4_800))
        XCTAssertThrowsError(try writer.appendVideo(try pixelBuffer(width: 1_600, height: 900, color: 100), at: time(7_200))) { XCTAssertEqual($0 as? MuxedMediaWriterError, .videoAppendDropped) }
        try await appendVideo(writer, color: 0, at: time(9_600))
        try await appendVideo(writer, color: 150, at: time(14_400))
        try await appendVideo(writer, color: 0, at: time(19_200))
        try await writer.finish(at: time(28_800))
        let inspected = try await inspect(fixture.url)
        XCTAssertEqual(inspected.video.map(\.colorClass), [.black, .real, .black, .real, .black])
        XCTAssertEqual(inspected.dimensions, CGSize(width: 1_600, height: 900))
    }

    private func makeFixture() throws -> (url: URL, folder: URL, profile: MuxedMediaProfile) {
        let root = URL(fileURLWithPath: "/private/tmp/recorder-task5-media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder.appendingPathComponent("fixture.mp4"), folder, .production(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    }

    private func audioBlock(start: Int64, frames: Int, value: Float) -> TimedMixedAudioBlock {
        .init(block: .init(startFrame: start, left: Array(repeating: value, count: frames), right: Array(repeating: value, count: frames)), presentationTime: time(start))
    }
    private func time(_ frames: Int64) -> CMTime { .init(value: frames, timescale: 48_000) }

    private func pixelBuffer(width: Int, height: Int, color: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result); CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)), plane == 0 ? Int32(color) : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }

    private func appendVideo(_ writer: MuxedMediaWriter, color: UInt8, at pts: CMTime) async throws {
        let buffer = try pixelBuffer(width: 1_600, height: 900, color: color)
        for _ in 0..<100 {
            do { try writer.appendVideo(buffer, at: pts); return } catch MuxedMediaWriterError.videoAppendDropped { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        throw MuxedMediaWriterError.videoAppendDropped
    }

    private enum ColorClass { case black, real }
    private struct Inspection { let video: [(pts: CMTime, colorClass: ColorClass)]; let dimensions: CGSize; let avEndDifference: Double }
    private func inspect(_ url: URL, seekAt: CMTime? = nil) async throws -> Inspection {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let video = try XCTUnwrap(videos.first), audio = try XCTUnwrap(audios.first)
        let videoFormats = try await video.load(.formatDescriptions)
        let vd = try XCTUnwrap(videoFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(vd), kCMVideoCodecType_HEVC)
        let audioFormats = try await audio.load(.formatDescriptions)
        let ad = try XCTUnwrap(audioFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(ad), kAudioFormatMPEG4AAC)
        let stream = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(ad)?.pointee); XCTAssertEqual(stream.mSampleRate, 48_000, accuracy: 0.01); XCTAssertEqual(stream.mChannelsPerFrame, 2)
        let videoSamples = try await readVideo(url: url, timeRange: seekAt.map { CMTimeRange(start: $0, duration: .positiveInfinity) })
        let allVideo = try await readVideo(url: url, timeRange: nil)
        XCTAssertFalse(videoSamples.isEmpty); XCTAssertMonotonic(allVideo.map(\.pts))
        for pair in zip(allVideo, allVideo.dropFirst()) { XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(pair.1.pts - pair.0.pts), 0.1 - 0.000_1) }
        let audioEnd = (try await audio.load(.timeRange)).end, videoEnd = (try await video.load(.timeRange)).end
        return .init(video: allVideo, dimensions: CGSize(width: Int(CMVideoFormatDescriptionGetDimensions(vd).width), height: Int(CMVideoFormatDescriptionGetDimensions(vd).height)), avEndDifference: abs(CMTimeGetSeconds(videoEnd - audioEnd)))
    }

    private func readVideo(url: URL, timeRange: CMTimeRange?) async throws -> [(pts: CMTime, colorClass: ColorClass)] {
        let freshAsset = AVURLAsset(url: url)
        let tracks = try await freshAsset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: freshAsset); if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]); reader.add(output); XCTAssertTrue(reader.startReading())
        var result: [(CMTime, ColorClass)] = []
        while let sample = output.copyNextSampleBuffer() {
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample)); CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let value = CVPixelBufferGetBaseAddress(pixel).map { $0.load(as: UInt8.self) } ?? 0; CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            result.append((CMSampleBufferGetPresentationTimeStamp(sample), value < 10 ? .black : .real))
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "reader incomplete")
        return result
    }

    private func XCTAssertMonotonic(_ values: [CMTime], file: StaticString = #filePath, line: UInt = #line) { for pair in zip(values, values.dropFirst()) { XCTAssertGreaterThanOrEqual(CMTimeCompare(pair.1, pair.0), 0, file: file, line: line) } }
    private func fulfillAsync(_ predicate: @escaping () -> Bool) async { for _ in 0..<100 where !predicate() { try? await Task.sleep(nanoseconds: 2_000_000) }; XCTAssertTrue(predicate()) }
    private func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Void, _ handler: (Error) -> Void) async { do { try await expression(); XCTFail("expected error") } catch { handler(error) } }
}

private final class FakeBackend: MuxedMediaWriterBackend, @unchecked Sendable {
    private let lock = NSLock(); private var handler: (() -> Void)?
    private var ready: Bool; private var appendResults: [Bool]; private var videoResults: [Bool]; private let failureOnAppendFalse: String?
    var failureDescription: String?; var outputURL: URL? { nil }; private(set) var audioPTS: [CMTime] = []; private(set) var finishCalls = 0; private(set) var cancelCalls = 0; private var completion: (() -> Void)?
    init(readiness: Bool, appendResults: [Bool] = [], videoResults: [Bool] = [], failureDescription: String? = nil, failureOnAppendFalse: String? = nil) { ready = readiness; self.appendResults = appendResults; self.videoResults = videoResults; self.failureDescription = failureDescription; self.failureOnAppendFalse = failureOnAppendFalse }
    var isAudioReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    func installReadinessHandler(on queue: DispatchQueue, _ handler: @escaping () -> Void) { lock.lock(); self.handler = { queue.async(execute: handler) }; lock.unlock() }
    func appendAudio(_ sample: CMSampleBuffer) -> Bool { lock.lock(); defer { lock.unlock() }; let result = appendResults.isEmpty ? true : appendResults.removeFirst(); if result { audioPTS.append(CMSampleBufferGetPresentationTimeStamp(sample)) } else if let failureOnAppendFalse { failureDescription = failureOnAppendFalse }; return result }
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool { lock.lock(); defer { lock.unlock() }; return videoResults.isEmpty ? true : videoResults.removeFirst() }
    func endSession(at time: CMTime) {}
    func markInputsFinished() {}
    func finish(_ completion: @escaping () -> Void) { lock.lock(); finishCalls += 1; self.completion = completion; lock.unlock() }
    func cancel() { lock.lock(); cancelCalls += 1; lock.unlock() }
    func setReady(_ value: Bool) { lock.lock(); ready = value; let handler = self.handler; lock.unlock(); handler?() }
    func fireReadiness() { lock.lock(); let handler = self.handler; lock.unlock(); handler?() }
    func completeFinish() { lock.lock(); let completion = self.completion; lock.unlock(); completion?() }
}

private final class ManualTimeoutScheduler: MuxedMediaWriterTimeoutScheduling {
    private let lock = NSLock(); private var actions: [() -> Void] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return actions.count }
    func schedule(on queue: DispatchQueue, after: TimeInterval, _ action: @escaping () -> Void) -> MuxedMediaWriterTimeoutToken { lock.lock(); actions.append(action); let index = actions.count - 1; lock.unlock(); return ManualToken { [weak self] in self?.remove(index) } }
    func fire() { lock.lock(); let action = actions.first; lock.unlock(); action?() }
    private func remove(_ index: Int) { lock.lock(); if actions.indices.contains(index) { actions[index] = {} }; lock.unlock() }
}
private final class ManualToken: MuxedMediaWriterTimeoutToken { private let action: () -> Void; init(_ action: @escaping () -> Void) { self.action = action }; func cancel() { action() } }
