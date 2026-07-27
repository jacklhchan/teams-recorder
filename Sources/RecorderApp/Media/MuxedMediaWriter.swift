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

final class MuxedMediaWriter: MuxedMediaWriting {
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

    private var pendingAudio: [PendingAudio] = []
    private var lastAudioPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var terminalError: MuxedMediaWriterError?
    private var isFinishing = false
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
            let duration = coveredDuration(afterAdding: pending)
            guard CMTimeCompare(duration, Self.maximumAudioFIFO) <= 0 else {
                let error = MuxedMediaWriterError.audioFIFOOverflow(limit: Self.maximumAudioFIFO, queuedDuration: duration)
                terminalError = error
                throw error
            }
            pendingAudio.append(pending)
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
                self.finishContinuation = continuation
                self.scheduleFinishTimeout()
                self.drainAudio()
                if self.pendingAudio.isEmpty {
                    self.completeFinish(at: audioEndTime)
                }
            }
        }
    }

    private func drainAudio() {
        guard terminalError == nil else { return }
        while !pendingAudio.isEmpty, audioInput.isReadyForMoreMediaData {
            let pending = pendingAudio[0]
            guard audioInput.append(pending.sampleBuffer) else {
                if writer.status == .failed {
                    terminalError = failWriter()
                    finishWithTerminalError()
                }
                return
            }
            pendingAudio.removeFirst()
        }
    }

    private func completeFinish(at audioEndTime: CMTime) {
        guard finishContinuation != nil else { return }
        finishTimer?.cancel()
        finishTimer = nil
        writer.endSession(atSourceTime: audioEndTime)
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        writer.finishWriting { [weak self] in
            self?.writerQueue.async {
                guard let self, let continuation = self.finishContinuation else { return }
                self.finishContinuation = nil
                if self.writer.status == .completed, self.validateOutput() {
                    continuation.resume()
                } else if self.writer.status == .completed {
                    continuation.resume(throwing: MuxedMediaWriterError.outputValidationFailed)
                } else {
                    continuation.resume(throwing: MuxedMediaWriterError.finishFailed(
                        description: self.writer.error?.localizedDescription ?? "writer status \\(self.writer.status.rawValue)"
                    ))
                }
            }
        }
    }

    private func scheduleFinishTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + finishTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, let continuation = self.finishContinuation else { return }
            self.finishContinuation = nil
            self.writer.cancelWriting()
            continuation.resume(throwing: MuxedMediaWriterError.finishTimedOut)
        }
        finishTimer = timer
        timer.resume()
    }

    private func finishWithTerminalError() {
        guard let continuation = finishContinuation, let terminalError else { return }
        finishContinuation = nil
        finishTimer?.cancel()
        finishTimer = nil
        writer.cancelWriting()
        continuation.resume(throwing: terminalError)
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

    private func coveredDuration(afterAdding pending: PendingAudio) -> CMTime {
        guard let first = pendingAudio.first else { return pending.end - pending.start }
        return pending.end - first.start
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

    private func validateOutput() -> Bool {
        let asset = AVURLAsset(url: writer.outputURL)
        return asset.tracks(withMediaType: .video).count == 1 && asset.tracks(withMediaType: .audio).count == 1
    }

    struct AudioFIFO {
        struct Entry: Equatable {
            let start: CMTime
            let duration: CMTime
        }

        private var entries: [Entry] = []
        var isEmpty: Bool { entries.isEmpty }

        mutating func enqueue(start: CMTime, duration: CMTime) throws {
            let entry = Entry(start: start, duration: duration)
            let span = (start + duration) - (entries.first?.start ?? start)
            guard CMTimeCompare(span, MuxedMediaWriter.maximumAudioFIFO) <= 0 else {
                throw MuxedMediaWriterError.audioFIFOOverflow(limit: MuxedMediaWriter.maximumAudioFIFO, queuedDuration: span)
            }
            entries.append(entry)
        }

        mutating func drain(ready: [Bool]) -> [Entry] {
            guard ready.last == true else { return [] }
            let drained = entries
            entries.removeAll()
            return drained
        }
    }

    static func finishResult(fifoDrained: Bool, deadlineReached: Bool) -> MuxedMediaWriterError? {
        !fifoDrained && deadlineReached ? .finishTimedOut : nil
    }
}
