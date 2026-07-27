@preconcurrency import AVFoundation
import CoreVideo
import XCTest
@testable import RecorderApp

final class MuxedMediaWriterIntegrationTests: XCTestCase {
    func testProductionDimensionsFrameRateAndBitratesAreStable() {
        let profile = MuxedMediaProfile.production(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        XCTAssertEqual(profile.width, 1_600)
        XCTAssertEqual(profile.height, 900)
        XCTAssertEqual(profile.maximumFramesPerSecond, 10)
        XCTAssertEqual(profile.videoBitRate, 1_200_000)
        XCTAssertEqual(profile.audioBitRate, 128_000)

        let settings = MuxedMediaWriter.productionSettings(profile: profile)
        XCTAssertEqual(settings.video[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertEqual(settings.video[AVVideoWidthKey] as? Int, 1_600)
        XCTAssertEqual(settings.video[AVVideoHeightKey] as? Int, 900)
        let compression = settings.video[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(compression?[AVVideoAverageBitRateKey] as? Int, 1_200_000)
        XCTAssertEqual(compression?[AVVideoExpectedSourceFrameRateKey] as? Int, 10)
        XCTAssertEqual(settings.audio[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings.audio[AVSampleRateKey] as? Int, 48_000)
        XCTAssertEqual(settings.audio[AVNumberOfChannelsKey] as? Int, 2)
        XCTAssertEqual(settings.audio[AVEncoderBitRateKey] as? Int, 128_000)
    }

    func testProductionSettingsPreferButDoNotRequireHardwareHEVC() {
        let settings = MuxedMediaWriter.productionSettings(profile: .production(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ))
        let specification = try? XCTUnwrap(settings.video[AVVideoEncoderSpecificationKey] as? [String: Any])

        XCTAssertEqual(specification?["EnableHardwareAcceleratedVideoEncoder"] as? Bool, true)
        XCTAssertNil(specification?["RequireHardwareAcceleratedVideoEncoder"])
    }

    func testSyntheticMP4HasReopenableHEVCAACTracksAndCappedVideoPTS() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let writer = try MuxedMediaWriter(url: fixture.url, profile: fixture.profile)

        try await appendVideo(writer, color: 0, at: .zero)
        try writer.appendAudio(audioBlock(start: 0, frames: 12_000, value: 0.1))
        try await appendVideo(writer, color: 80, at: time(9_600))
        try writer.appendAudio(audioBlock(start: 12_000, frames: 12_000, value: -0.1))
        try await appendVideo(writer, color: 160, at: time(19_200))
        try writer.appendAudio(audioBlock(start: 24_000, frames: 12_000, value: 0.2))
        try await appendVideo(writer, color: 40, at: time(28_800))
        try writer.appendAudio(audioBlock(start: 36_000, frames: 12_000, value: -0.2))
        try await appendVideo(writer, color: 0, at: time(43_200))
        try await writer.finish(at: time(48_000))

        let asset = AVURLAsset(url: fixture.url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(playable)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)

        let video = try XCTUnwrap(tracks.first)
        let videoDescriptions = try await video.load(.formatDescriptions)
        let videoDescription = try XCTUnwrap(videoDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoDescription), kCMVideoCodecType_HEVC)
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoDescription)
        XCTAssertEqual(Int(dimensions.width), 1_600)
        XCTAssertEqual(Int(dimensions.height), 900)

        let audio = try XCTUnwrap(audioTracks.first)
        let audioDescriptions = try await audio.load(.formatDescriptions)
        let audioDescription = try XCTUnwrap(audioDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioDescription), kAudioFormatMPEG4AAC)
        let stream = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee)
        XCTAssertEqual(stream.mSampleRate, 48_000, accuracy: 0.01)
        XCTAssertEqual(stream.mChannelsPerFrame, 2)

        let videoSamples = try await sampleTimes(url: fixture.url, mediaType: .video)
        let audioSamples = try await sampleTimes(url: fixture.url, mediaType: .audio)
        XCTAssertGreaterThanOrEqual(videoSamples.count, 2)
        XCTAssertFalse(audioSamples.isEmpty)
        XCTAssertMonotonic(videoSamples.map(\.start))
        XCTAssertMonotonic(audioSamples.map(\.start))
        for pair in zip(videoSamples, videoSamples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(pair.1.start - pair.0.start), 0.1 - 0.000_1)
        }
        let videoEnd = try await video.load(.timeRange).end
        let audioEnd = try await audio.load(.timeRange).end
        XCTAssertLessThanOrEqual(abs(CMTimeGetSeconds(videoEnd - audioEnd)), 0.1 + 0.03)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while output.copyNextSampleBuffer() != nil {}
        XCTAssertEqual(reader.status, .completed, "\\(reader.error?.localizedDescription ?? \"no reader error\")")
    }

    func testTemporaryAudioBackpressureRecoversInProductionDrainStateAndFinishes() throws {
        var state = MuxedMediaWriter.AudioDrainState<String>()
        try state.enqueue("first", start: .zero, end: time(24_000))
        try state.enqueue("second", start: time(24_000), end: time(48_000))
        var readiness = [false, false, true, true, false]
        var appended: [String] = []

        state.drain(
            isReady: { readiness.removeFirst() },
            append: { appended.append($0); return true }
        )
        state.drain(
            isReady: { readiness.removeFirst() },
            append: { appended.append($0); return true }
        )
        XCTAssertTrue(appended.isEmpty)
        XCTAssertFalse(state.isEmpty)

        state.drain(
            isReady: { readiness.removeFirst() },
            append: { appended.append($0); return true }
        )
        XCTAssertEqual(appended, ["first", "second"])
        XCTAssertTrue(state.isEmpty)
    }

    func testAudioFIFOOverflowReturnsTypedTerminalMuxFailure() throws {
        var fifo = MuxedMediaWriter.AudioDrainState<String>()
        try fifo.enqueue("five-seconds", start: .zero, end: time(240_000))
        XCTAssertThrowsError(try fifo.enqueue("overflow", start: time(240_000), end: time(240_001))) {
            guard case .audioFIFOOverflow = $0 as? MuxedMediaWriterError else {
                return XCTFail("expected typed FIFO overflow, got \\($0)")
            }
        }
    }

    func testDrainStatePreservesFirstAppendFailureForWriterStatusInspection() throws {
        var state = MuxedMediaWriter.AudioDrainState<String>()
        try state.enqueue("first", start: .zero, end: time(1))
        var attempted = 0
        state.drain(isReady: { true }, append: { _ in attempted += 1; return false })

        XCTAssertEqual(attempted, 1)
        XCTAssertFalse(state.isEmpty)
    }

    private func makeFixture() throws -> (url: URL, folder: URL, profile: MuxedMediaProfile) {
        let root = URL(fileURLWithPath: "/private/tmp/recorder-task5-media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (
            folder.appendingPathComponent("synthetic-hevc-aac.mp4"),
            folder,
            .production(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        )
    }

    private func audioBlock(start: Int64, frames: Int, value: Float) -> TimedMixedAudioBlock {
        TimedMixedAudioBlock(
            block: MixedAudioBlock(startFrame: start, left: Array(repeating: value, count: frames), right: Array(repeating: value, count: frames)),
            presentationTime: time(start)
        )
    }

    private func pixelBuffer(color: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 1_600, 900,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        ), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane))
            memset(address, plane == 0 ? Int32(color) : 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
        }
        return pixelBuffer
    }

    private func appendVideo(_ writer: MuxedMediaWriter, color: UInt8, at time: CMTime) async throws {
        let buffer = try pixelBuffer(color: color)
        for _ in 0..<100 {
            do {
                try writer.appendVideo(buffer, at: time)
                return
            } catch MuxedMediaWriterError.videoAppendDropped {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        throw MuxedMediaWriterError.videoAppendDropped
    }

    private func sampleTimes(url: URL, mediaType: AVMediaType) async throws -> [(start: CMTime, end: CMTime)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any]? = mediaType == .video ? [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ] : [
            AVFormatIDKey: kAudioFormatLinearPCM
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [(CMTime, CMTime)] = []
        while let sample = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            result.append((start, start + CMSampleBufferGetDuration(sample)))
        }
        XCTAssertEqual(reader.status, .completed, "\\(reader.error?.localizedDescription ?? \"no reader error\")")
        return result
    }

    private func time(_ frames: Int64) -> CMTime { CMTime(value: frames, timescale: 48_000) }

    private func XCTAssertMonotonic(_ times: [CMTime], file: StaticString = #filePath, line: UInt = #line) {
        for pair in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(CMTimeCompare(pair.1, pair.0), 0, file: file, line: line)
        }
    }
}
