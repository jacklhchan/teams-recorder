@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct MuxedMediaProfile: Equatable, Sendable {
    let width: Int
    let height: Int
    let maximumFramesPerSecond: Int
    let videoBitRate: Int
    let audioBitRate: Int
    let pixelFormat: OSType

    static func production(pixelFormat: OSType) -> MuxedMediaProfile {
        MuxedMediaProfile(
            width: 1_600,
            height: 900,
            maximumFramesPerSecond: 10,
            videoBitRate: 1_200_000,
            audioBitRate: 128_000,
            pixelFormat: pixelFormat
        )
    }
}

protocol MuxedMediaWriting: AnyObject {
    func appendAudio(_ block: TimedMixedAudioBlock) throws
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws
    func finish(at audioEndTime: CMTime) async throws
}

enum MuxedMediaWriterError: Error, Equatable {
    case invalidAudioBlock
    case invalidPresentationTime
    case nonMonotonicAudioPTS(previous: CMTime, received: CMTime)
    case writerSetupFailed
    case writerFailed(description: String)
    case audioFIFOOverflow(limit: CMTime, queuedDuration: CMTime)
    case videoAppendDropped
    case finishTimedOut
    case finishFailed(description: String)
    case outputValidationFailed
    case closed
}

final class MuxedMediaWriter: MuxedMediaWriting, @unchecked Sendable {
    typealias Settings = (video: [String: Any], audio: [String: Any])

    private static let sampleRate: CMTimeScale = 48_000
    private static let maximumAudioFIFO = CMTime(value: 240_000, timescale: 48_000)

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private let writerQueue = DispatchQueue(label: "local.meeting.recorder.muxed-media-writer")
    private let finishTimeout: TimeInterval

    private var pendingAudio = AudioDrainState<PendingAudio>()
    private var lastAudioPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var terminalError: MuxedMediaWriterError?
    private var isFinishing = false
    private var isCompleting = false
    private var finishAudioEndTime: CMTime?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishTimer: DispatchSourceTimer?

    private struct PendingAudio {
        let sampleBuffer: CMSampleBuffer
        let start: CMTime
        let end: CMTime
    }

    init(
        url: URL,
        profile: MuxedMediaProfile,
        finishTimeout: TimeInterval = 10
    ) throws {
        self.finishTimeout = max(0, finishTimeout)
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw MuxedMediaWriterError.writerSetupFailed
        }

        let settings = Self.productionSettings(profile: profile)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.video)
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audio)
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: profile.pixelFormat,
                kCVPixelBufferWidthKey as String: profile.width,
                kCVPixelBufferHeightKey as String: profile.height
            ]
        )
        audioFormat = try Self.makeAudioFormat()

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw MuxedMediaWriterError.writerSetupFailed
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw MuxedMediaWriterError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)
        audioInput.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
            self?.drainAudio()
        }
    }

    static func productionSettings(profile: MuxedMediaProfile) -> Settings {
        let video: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: profile.width,
            AVVideoHeightKey: profile.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: profile.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: profile.maximumFramesPerSecond
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
        ]
        let audio: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Int(Self.sampleRate),
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: profile.audioBitRate
        ]
        return (video, audio)
    }

    func appendAudio(_ block: TimedMixedAudioBlock) throws {
        let sample = try makeAudioSample(block)
        try writerQueue.sync {
            try ensureOpen()
            if let lastAudioPTS, CMTimeCompare(block.presentationTime, lastAudioPTS) < 0 {
                throw MuxedMediaWriterError.nonMonotonicAudioPTS(previous: lastAudioPTS, received: block.presentationTime)
            }
            let pending = PendingAudio(sampleBuffer: sample, start: block.presentationTime, end: block.presentationTime + sample.duration)
            try pendingAudio.enqueue(pending, start: pending.start, end: pending.end)
            lastAudioPTS = block.presentationTime
            drainAudio()
        }
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws {
        try writerQueue.sync {
            try ensureOpen()
            guard time.isValid, time.isNumeric, CMTimeCompare(time, .zero) >= 0 else {
                throw MuxedMediaWriterError.invalidPresentationTime
            }
            if let lastVideoPTS,
               CMTimeCompare(time - lastVideoPTS, CMTime(value: 1, timescale: CMTimeScale(10))) < 0 {
                throw MuxedMediaWriterError.videoAppendDropped
            }
            guard videoInput.isReadyForMoreMediaData else {
                throw MuxedMediaWriterError.videoAppendDropped
            }
            guard videoAdaptor.append(pixelBuffer, withPresentationTime: time) else {
                if writer.status == .failed {
                    throw failWriter()
                }
                throw MuxedMediaWriterError.videoAppendDropped
            }
            lastVideoPTS = time
        }
    }

    func finish(at audioEndTime: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MuxedMediaWriterError.closed)
                    return
                }
                guard audioEndTime.isValid, audioEndTime.isNumeric else {
                    continuation.resume(throwing: MuxedMediaWriterError.invalidPresentationTime)
                    return
                }
                guard !self.isFinishing else {
                    continuation.resume(throwing: MuxedMediaWriterError.closed)
                    return
                }
                if let terminalError = self.terminalError {
                    continuation.resume(throwing: terminalError)
                    return
                }
                self.isFinishing = true
                self.finishAudioEndTime = audioEndTime
                self.finishContinuation = continuation
                self.scheduleFinishTimeout()
                self.drainAudio()
            }
        }
    }

    private func drainAudio() {
        guard terminalError == nil else { return }
        pendingAudio.drain(
            isReady: { self.audioInput.isReadyForMoreMediaData },
            append: { self.audioInput.append($0.sampleBuffer) }
        )
        if !pendingAudio.isEmpty, writer.status == .failed {
            terminalError = failWriter()
            finishWithTerminalError()
            return
        }
        if isFinishing, pendingAudio.isEmpty, let finishAudioEndTime {
            completeFinish(at: finishAudioEndTime)
        }
    }

    private func completeFinish(at audioEndTime: CMTime) {
        guard finishContinuation != nil, !isCompleting else { return }
        isCompleting = true
        writer.endSession(atSourceTime: audioEndTime)
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            Task {
                let isValid = await self.validateOutput()
                self.writerQueue.async {
                    guard self.writer.status == .completed, isValid else {
                        self.resumeFinish(throwing: self.writer.status == .completed
                            ? MuxedMediaWriterError.outputValidationFailed
                            : MuxedMediaWriterError.finishFailed(description: self.writer.error?.localizedDescription ?? "writer status \\(self.writer.status.rawValue)"))
                        return
                    }
                    self.resumeFinish()
                }
            }
        }
    }

    private func scheduleFinishTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + finishTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.finishContinuation != nil else { return }
            self.writer.cancelWriting()
            self.resumeFinish(throwing: MuxedMediaWriterError.finishTimedOut)
        }
        finishTimer = timer
        timer.resume()
    }

    private func finishWithTerminalError() {
        guard finishContinuation != nil, let terminalError else { return }
        writer.cancelWriting()
        resumeFinish(throwing: terminalError)
    }

    private func ensureOpen() throws {
        if let terminalError { throw terminalError }
        guard !isFinishing else { throw MuxedMediaWriterError.closed }
        guard writer.status == .writing else { throw failWriter() }
    }

    private func failWriter() -> MuxedMediaWriterError {
        let error = MuxedMediaWriterError.writerFailed(description: writer.error?.localizedDescription ?? "writer status \\(writer.status.rawValue)")
        terminalError = error
        return error
    }

    private func resumeFinish(throwing error: Error? = nil) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        finishTimer?.cancel()
        finishTimer = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func makeAudioSample(_ timedBlock: TimedMixedAudioBlock) throws -> CMSampleBuffer {
        let block = timedBlock.block
        guard !block.left.isEmpty, block.left.count == block.right.count else {
            throw MuxedMediaWriterError.invalidAudioBlock
        }
        guard timedBlock.presentationTime.isValid, timedBlock.presentationTime.isNumeric,
              block.left.allSatisfy({ $0.isFinite }), block.right.allSatisfy({ $0.isFinite }) else {
            throw MuxedMediaWriterError.invalidPresentationTime
        }
        var interleaved = [Float]()
        interleaved.reserveCapacity(block.left.count * 2)
        for index in block.left.indices {
            interleaved.append(block.left[index])
            interleaved.append(block.right[index])
        }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
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
            throw MuxedMediaWriterError.writerSetupFailed
        }
        let replaceStatus = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { throw MuxedMediaWriterError.writerSetupFailed }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Self.sampleRate),
            presentationTimeStamp: timedBlock.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = 2 * MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: audioFormat,
            sampleCount: block.left.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            throw MuxedMediaWriterError.writerSetupFailed
        }
        return sampleBuffer
    }

    private static func makeAudioFormat() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            throw MuxedMediaWriterError.writerSetupFailed
        }
        return format
    }

    private func validateOutput() async -> Bool {
        let asset = AVURLAsset(url: writer.outputURL)
        do {
            guard try await asset.load(.isPlayable) else { return false }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard videoTracks.count == 1, audioTracks.count == 1,
                  let video = videoTracks.first, let audio = audioTracks.first else { return false }
            let videoDescription = try await video.load(.formatDescriptions).first
            guard let videoDescription,
                  CMFormatDescriptionGetMediaSubType(videoDescription) == kCMVideoCodecType_HEVC else { return false }
            let dimensions = CMVideoFormatDescriptionGetDimensions(videoDescription)
            guard dimensions.width == 1_600, dimensions.height == 900 else { return false }
            let audioDescription = try await audio.load(.formatDescriptions).first
            guard let audioDescription,
                  CMFormatDescriptionGetMediaSubType(audioDescription) == kAudioFormatMPEG4AAC,
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee else { return false }
            return abs(stream.mSampleRate - 48_000) < 0.01 && stream.mChannelsPerFrame == 2
        } catch {
            return false
        }
    }

    struct AudioDrainState<Element> {
        private struct Entry {
            let element: Element
            let start: CMTime
            let end: CMTime
        }

        private var entries: [Entry] = []
        var isEmpty: Bool { entries.isEmpty }

        mutating func enqueue(_ element: Element, start: CMTime, end: CMTime) throws {
            let span = end - (entries.first?.start ?? start)
            guard CMTimeCompare(span, MuxedMediaWriter.maximumAudioFIFO) <= 0 else {
                throw MuxedMediaWriterError.audioFIFOOverflow(limit: MuxedMediaWriter.maximumAudioFIFO, queuedDuration: span)
            }
            entries.append(Entry(element: element, start: start, end: end))
        }

        mutating func drain(isReady: () -> Bool, append: (Element) -> Bool) {
            while let entry = entries.first, isReady() {
                guard append(entry.element) else { return }
                entries.removeFirst()
            }
        }
    }
}
