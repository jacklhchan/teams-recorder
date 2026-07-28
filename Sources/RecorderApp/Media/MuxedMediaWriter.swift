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
        .init(
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
    func appendCriticalVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws
    func finish(at audioEndTime: CMTime) async throws
}

enum MuxedMediaWriterError: Error, Equatable {
    case invalidAudioBlock
    case invalidPresentationTime
    case writerSetupFailed
    case videoAppendDropped
    case criticalVideoAppendFailed
    case finishTimedOut
    case outputValidationFailed
    case closed
    case nonMonotonicAudioPTS(previous: CMTime, received: CMTime)
    case writerFailed(description: String)
    case audioFIFOOverflow(limit: CMTime, queuedDuration: CMTime)
    case finishFailed(description: String)
}

/// The deliberately small boundary around AVAssetWriter.  Production and deterministic
/// tests drive the same admission, FIFO, drain and finalization state machine.
protocol MuxedMediaWriterBackend: AnyObject {
    var isAudioReady: Bool { get }
    var failureDescription: String? { get }
    var outputURL: URL? { get }
    func installReadinessHandler(on queue: DispatchQueue, _ handler: @escaping () -> Void)
    func appendAudio(_ sample: CMSampleBuffer) -> Bool
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool
    func endSession(at time: CMTime)
    func markInputsFinished()
    func finish(_ completion: @escaping () -> Void)
    func cancel()
}

protocol MuxedMediaWriterTimeoutToken: AnyObject { func cancel() }
protocol MuxedMediaWriterTimeoutScheduling: AnyObject {
    func schedule(on queue: DispatchQueue, after: TimeInterval, _ action: @escaping () -> Void) -> MuxedMediaWriterTimeoutToken
}

private final class DispatchTimeoutToken: MuxedMediaWriterTimeoutToken {
    private let timer: DispatchSourceTimer
    init(_ timer: DispatchSourceTimer) { self.timer = timer }
    func cancel() { timer.cancel() }
}

private final class DispatchTimeoutScheduler: MuxedMediaWriterTimeoutScheduling {
    func schedule(on queue: DispatchQueue, after: TimeInterval, _ action: @escaping () -> Void) -> MuxedMediaWriterTimeoutToken {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, after))
        timer.setEventHandler(handler: action)
        timer.resume()
        return DispatchTimeoutToken(timer)
    }
}

final class MuxedMediaWriter: MuxedMediaWriting, @unchecked Sendable {
    typealias Settings = (video: [String: Any], audio: [String: Any])
    private static let sampleRate: CMTimeScale = 48_000
    static let maximumAudioFIFO = CMTime(value: 240_000, timescale: 48_000)

    private let backend: MuxedMediaWriterBackend
    private let audioFormat: CMAudioFormatDescription
    private let writerQueue = DispatchQueue(label: "local.meeting.recorder.muxed-media-writer")
    private let finishTimeout: TimeInterval
    private let timeoutScheduler: MuxedMediaWriterTimeoutScheduling
    private var pendingAudio: [PendingAudio] = []
    private var lastAudioPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var terminalError: MuxedMediaWriterError?
    private var isFinishing = false
    private var isCompleting = false
    private var finishAudioEndTime: CMTime?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishTimer: MuxedMediaWriterTimeoutToken?
    private var didCancelBackend = false

    private struct PendingAudio {
        let sampleBuffer: CMSampleBuffer
        let start: CMTime
        let end: CMTime
    }

    convenience init(url: URL, profile: MuxedMediaProfile, finishTimeout: TimeInterval = 10) throws {
        let backend = try AVFoundationMuxedBackend(url: url, profile: profile)
        try self.init(backend: backend, finishTimeout: finishTimeout, timeoutScheduler: DispatchTimeoutScheduler())
    }

    init(backend: MuxedMediaWriterBackend, finishTimeout: TimeInterval = 10, timeoutScheduler: MuxedMediaWriterTimeoutScheduling = DispatchTimeoutScheduler()) throws {
        self.backend = backend
        self.finishTimeout = max(0, finishTimeout)
        self.timeoutScheduler = timeoutScheduler
        self.audioFormat = try Self.makeAudioFormat()
        backend.installReadinessHandler(on: writerQueue) { [weak self] in self?.drainAudio() }
    }

    static func productionSettings(profile: MuxedMediaProfile) -> Settings {
        let video: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: profile.width,
            AVVideoHeightKey: profile.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: profile.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: profile.maximumFramesPerSecond,
                AVVideoAllowFrameReorderingKey: false
            ],
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        ]
        let audio: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Int(sampleRate),
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
            let span = pending.end - (pendingAudio.first?.start ?? pending.start)
            guard CMTimeCompare(span, Self.maximumAudioFIFO) <= 0 else {
                let error = MuxedMediaWriterError.audioFIFOOverflow(limit: Self.maximumAudioFIFO, queuedDuration: span)
                latch(error)
                throw error
            }
            pendingAudio.append(pending)
            lastAudioPTS = block.presentationTime
            drainAudio()
            if let terminalError { throw terminalError }
        }
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws {
        try appendVideoFrame(
            pixelBuffer,
            at: time,
            enforcesCadence: true,
            failureIsTerminal: false
        )
    }

    func appendCriticalVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws {
        try appendVideoFrame(
            pixelBuffer,
            at: time,
            enforcesCadence: false,
            failureIsTerminal: true
        )
    }

    private func appendVideoFrame(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime,
        enforcesCadence: Bool,
        failureIsTerminal: Bool
    ) throws {
        try writerQueue.sync {
            try ensureOpen()
            guard time.isValid, time.isNumeric, CMTimeCompare(time, .zero) >= 0 else {
                throw MuxedMediaWriterError.invalidPresentationTime
            }
            if let lastVideoPTS,
               enforcesCadence,
               CMTimeCompare(time - lastVideoPTS, CMTime(value: 1, timescale: 10)) < 0 {
                throw MuxedMediaWriterError.videoAppendDropped
            }
            if let lastVideoPTS,
               CMTimeCompare(time, lastVideoPTS) <= 0 {
                let error = failureIsTerminal
                    ? MuxedMediaWriterError.criticalVideoAppendFailed
                    : MuxedMediaWriterError.videoAppendDropped
                if failureIsTerminal { throw latch(error) }
                throw error
            }
            guard backend.appendVideo(pixelBuffer, at: time) else {
                if let description = backend.failureDescription { throw latch(.writerFailed(description: description)) }
                if failureIsTerminal { throw latch(.criticalVideoAppendFailed) }
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
                guard audioEndTime.isValid,
                      audioEndTime.isNumeric,
                      CMTimeCompare(audioEndTime, .zero) >= 0 else {
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
                self.finishTimer = self.timeoutScheduler.schedule(on: self.writerQueue, after: self.finishTimeout) { [weak self] in self?.timeoutFinish() }
                self.drainAudio()
            }
        }
    }

    private func drainAudio() {
        guard terminalError == nil else {
            finishWithTerminalError()
            return
        }
        if let description = backend.failureDescription {
            latch(.writerFailed(description: description))
            finishWithTerminalError()
            return
        }
        while !pendingAudio.isEmpty, backend.isAudioReady {
            let next = pendingAudio[0]
            guard backend.appendAudio(next.sampleBuffer) else {
                if let description = backend.failureDescription {
                    latch(.writerFailed(description: description))
                    finishWithTerminalError()
                }
                return
            }
            pendingAudio.removeFirst()
        }
        if isFinishing, pendingAudio.isEmpty, let end = finishAudioEndTime { completeFinish(at: end) }
    }

    private func completeFinish(at audioEndTime: CMTime) {
        guard finishContinuation != nil, !isCompleting else { return }
        isCompleting = true
        backend.endSession(at: audioEndTime)
        backend.markInputsFinished()
        backend.finish { [weak self] in
            guard let self else { return }
            self.writerQueue.async {
                let outputURL = self.backend.outputURL
                let failureDescription = self.backend.failureDescription
                Task { [weak self] in
                    guard let self else { return }
                    let valid = await self.validateOutput(
                        outputURL: outputURL,
                        backendWasSuccessful: failureDescription == nil
                    )
                    self.writerQueue.async {
                        if let failure = self.backend.failureDescription {
                            self.resumeFinish(throwing: .finishFailed(description: failure))
                        } else if valid {
                            self.resumeFinish()
                        } else {
                            self.resumeFinish(throwing: .outputValidationFailed)
                        }
                    }
                }
            }
        }
    }

    private func timeoutFinish() {
        guard finishContinuation != nil else { return }
        cancelBackendOnce()
        resumeFinish(throwing: .finishTimedOut)
    }

    private func finishWithTerminalError() {
        guard let terminalError, finishContinuation != nil else { return }
        resumeFinish(throwing: terminalError)
    }

    private func ensureOpen() throws {
        if let terminalError { throw terminalError }
        guard !isFinishing else { throw MuxedMediaWriterError.closed }
        if let description = backend.failureDescription { throw latch(.writerFailed(description: description)) }
    }

    @discardableResult private func latch(_ error: MuxedMediaWriterError) -> MuxedMediaWriterError {
        if terminalError == nil {
            terminalError = error
            cancelBackendOnce()
        }
        return terminalError ?? error
    }

    private func cancelBackendOnce() {
        guard !didCancelBackend else { return }
        didCancelBackend = true
        backend.cancel()
    }

    private func resumeFinish(throwing error: MuxedMediaWriterError? = nil) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        finishTimer?.cancel()
        finishTimer = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func makeAudioSample(_ timedBlock: TimedMixedAudioBlock) throws -> CMSampleBuffer {
        let block = timedBlock.block
        guard !block.left.isEmpty, block.left.count == block.right.count else { throw MuxedMediaWriterError.invalidAudioBlock }
        guard timedBlock.presentationTime.isValid, timedBlock.presentationTime.isNumeric, block.left.allSatisfy(\.isFinite), block.right.allSatisfy(\.isFinite) else { throw MuxedMediaWriterError.invalidPresentationTime }
        var interleaved = [Float]()
        interleaved.reserveCapacity(block.left.count * 2)
        for index in block.left.indices {
            interleaved.append(block.left[index])
            interleaved.append(block.right[index])
        }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr, let blockBuffer else { throw MuxedMediaWriterError.writerSetupFailed }
        let replace = interleaved.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount) }
        guard replace == kCMBlockBufferNoErr else { throw MuxedMediaWriterError.writerSetupFailed }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Self.sampleRate), presentationTimeStamp: timedBlock.presentationTime, decodeTimeStamp: .invalid)
        var sampleSize = 2 * MemoryLayout<Float>.size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: audioFormat, sampleCount: block.left.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else { throw MuxedMediaWriterError.writerSetupFailed }
        return sample
    }

    private static func makeAudioFormat() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw MuxedMediaWriterError.writerSetupFailed }
        return format
    }

    private func validateOutput(outputURL: URL?, backendWasSuccessful: Bool) async -> Bool {
        guard backendWasSuccessful else { return false }
        guard let outputURL else { return true }
        let asset = AVURLAsset(url: outputURL)
        do {
            guard try await asset.load(.isPlayable) else { return false }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard videoTracks.count == 1, audioTracks.count == 1, let video = videoTracks.first, let audio = audioTracks.first,
                  let videoDescription = try await video.load(.formatDescriptions).first,
                  CMFormatDescriptionGetMediaSubType(videoDescription) == kCMVideoCodecType_HEVC,
                  CMVideoFormatDescriptionGetDimensions(videoDescription).width == 1_600,
                  CMVideoFormatDescriptionGetDimensions(videoDescription).height == 900,
                  let audioDescription = try await audio.load(.formatDescriptions).first,
                  CMFormatDescriptionGetMediaSubType(audioDescription) == kAudioFormatMPEG4AAC,
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee else { return false }
            return abs(stream.mSampleRate - 48_000) < 0.01 && stream.mChannelsPerFrame == 2
        } catch { return false }
    }
}

private final class AVFoundationMuxedBackend: MuxedMediaWriterBackend, @unchecked Sendable {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput
    let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    var isAudioReady: Bool { audioInput.isReadyForMoreMediaData }
    var failureDescription: String? { writer.status == .failed ? (writer.error?.localizedDescription ?? "writer status failed") : nil }
    var outputURL: URL? { writer.outputURL }

    init(url: URL, profile: MuxedMediaProfile) throws {
        try? FileManager.default.removeItem(at: url)
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw MuxedMediaWriterError.writerSetupFailed }
        let settings = MuxedMediaWriter.productionSettings(profile: profile)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.video)
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audio)
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: profile.pixelFormat, kCVPixelBufferWidthKey as String: profile.width, kCVPixelBufferHeightKey as String: profile.height])
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw MuxedMediaWriterError.writerSetupFailed }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw MuxedMediaWriterError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)
    }
    func installReadinessHandler(on queue: DispatchQueue, _ handler: @escaping () -> Void) { audioInput.requestMediaDataWhenReady(on: queue, using: handler) }
    func appendAudio(_ sample: CMSampleBuffer) -> Bool { audioInput.append(sample) }
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool { videoInput.isReadyForMoreMediaData && videoAdaptor.append(pixelBuffer, withPresentationTime: time) }
    func endSession(at time: CMTime) { writer.endSession(atSourceTime: time) }
    func markInputsFinished() {
        videoInput.markAsFinished()
        audioInput.markAsFinished()
    }
    func finish(_ completion: @escaping () -> Void) { writer.finishWriting(completionHandler: completion) }
    func cancel() { writer.cancelWriting() }
}
