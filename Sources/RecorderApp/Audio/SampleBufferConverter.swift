@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

enum SampleBufferConverterError: Error, Equatable {
    case invalidSampleBuffer
    case missingFormatDescription
    case unsupportedFormat
    case unsupportedByteOrder
    case unsupportedAlignedHighPCM
    case unsupportedChannelCount(Int)
    case unsupportedPCMLayout
    case invalidPCMFrameStride
    case invalidPCMLayout
    case invalidPresentationTime
    case audioBufferListUnavailable
    case audioBufferListReadFailed
    case mismatchedChannelFrames
    case nonFiniteSample
    case converterCreationFailed
    case converterFailed
}

struct OwnedPCMBuffer: Equatable {
    let sampleRate: Double
    let channels: [[Float]]

    var frameCount: Int {
        channels.first?.count ?? 0
    }
}

struct OwnedAudioPacket: Equatable {
    let pcm: OwnedPCMBuffer
    let presentationTime: CMTime
}

enum PCMEncoding: Equatable {
    case float32
    case signedInt16
    case signedInt24Packed
    case signedInt32

    var storageByteCount: Int {
        switch self {
        case .signedInt16:
            return 2
        case .signedInt24Packed:
            return 3
        case .float32, .signedInt32:
            return 4
        }
    }
}

struct PCMLayout: Equatable {
    let sampleRate: Double
    let channelCount: Int
    let isInterleaved: Bool
    let bytesPerFrame: Int
    let encoding: PCMEncoding
}

enum PCMLayoutValidator {
    static func validate(_ format: AudioStreamBasicDescription) throws -> PCMLayout {
        guard format.mFormatID == kAudioFormatLinearPCM else {
            throw SampleBufferConverterError.unsupportedFormat
        }
        guard format.mSampleRate.isFinite, format.mSampleRate > 0 else {
            throw SampleBufferConverterError.invalidPCMLayout
        }

        let flags = format.mFormatFlags
        guard flags & UInt32(kAudioFormatFlagIsBigEndian) == 0 else {
            throw SampleBufferConverterError.unsupportedByteOrder
        }
        guard flags & UInt32(kAudioFormatFlagIsAlignedHigh) == 0 else {
            throw SampleBufferConverterError.unsupportedAlignedHighPCM
        }
        guard flags & UInt32(kAudioFormatFlagIsPacked) != 0 else {
            throw SampleBufferConverterError.unsupportedPCMLayout
        }

        let channelCount = Int(format.mChannelsPerFrame)
        guard (1...2).contains(channelCount) else {
            throw SampleBufferConverterError.unsupportedChannelCount(channelCount)
        }
        guard format.mFramesPerPacket == 1 else {
            throw SampleBufferConverterError.unsupportedPCMLayout
        }

        let isFloat = flags & UInt32(kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = flags & UInt32(kAudioFormatFlagIsSignedInteger) != 0
        let encoding: PCMEncoding
        switch (isFloat, isSignedInteger, format.mBitsPerChannel) {
        case (true, false, 32):
            encoding = .float32
        case (false, true, 16):
            encoding = .signedInt16
        case (false, true, 24):
            encoding = .signedInt24Packed
        case (false, true, 32):
            encoding = .signedInt32
        default:
            throw SampleBufferConverterError.unsupportedPCMLayout
        }

        let isNonInterleaved = flags & UInt32(kAudioFormatFlagIsNonInterleaved) != 0
        let expectedBytesPerFrame = encoding.storageByteCount * (isNonInterleaved ? 1 : channelCount)
        guard Int(format.mBytesPerFrame) == expectedBytesPerFrame else {
            throw SampleBufferConverterError.invalidPCMFrameStride
        }
        guard format.mBytesPerPacket == format.mBytesPerFrame else {
            throw SampleBufferConverterError.unsupportedPCMLayout
        }

        return PCMLayout(
            sampleRate: format.mSampleRate,
            channelCount: channelCount,
            isInterleaved: !isNonInterleaved,
            bytesPerFrame: expectedBytesPerFrame,
            encoding: encoding
        )
    }
}

enum PCMByteDecoder {
    static func decode(_ bytes: [UInt8], encoding: PCMEncoding) throws -> Float {
        guard bytes.count == encoding.storageByteCount else {
            throw SampleBufferConverterError.invalidPCMLayout
        }
        return try decode(encoding: encoding) { offset in
            bytes[offset]
        }
    }

    static func decode(
        _ pointer: UnsafeRawPointer,
        encoding: PCMEncoding
    ) throws -> Float {
        try decode(encoding: encoding) { offset in
            pointer.load(fromByteOffset: offset, as: UInt8.self)
        }
    }

    private static func decode(
        encoding: PCMEncoding,
        byteAt: (Int) -> UInt8
    ) throws -> Float {
        let value: Float
        switch encoding {
        case .float32:
            let bitPattern = UInt32(byteAt(0))
                | (UInt32(byteAt(1)) << 8)
                | (UInt32(byteAt(2)) << 16)
                | (UInt32(byteAt(3)) << 24)
            value = Float(bitPattern: bitPattern)
        case .signedInt16:
            let bitPattern = UInt16(byteAt(0)) | (UInt16(byteAt(1)) << 8)
            let integer = Int16(bitPattern: bitPattern)
            value = Float(Double(integer) / 32_768.0)
        case .signedInt24Packed:
            let unsigned = Int32(byteAt(0))
                | (Int32(byteAt(1)) << 8)
                | (Int32(byteAt(2)) << 16)
            let integer = unsigned & 0x80_0000 == 0 ? unsigned : unsigned | ~0xFF_FFFF
            value = Float(Double(integer) / 8_388_608.0)
        case .signedInt32:
            let bitPattern = UInt32(byteAt(0))
                | (UInt32(byteAt(1)) << 8)
                | (UInt32(byteAt(2)) << 16)
                | (UInt32(byteAt(3)) << 24)
            let integer = Int32(bitPattern: bitPattern)
            value = Float(Double(integer) / 2_147_483_648.0)
        }
        guard value.isFinite else {
            throw SampleBufferConverterError.nonFiniteSample
        }
        return value
    }
}

enum SampleBufferConverter {
    static let outputSampleRate = 48_000.0

    /// All sources use the same integer frame timeline: PTS rounded toward zero at 48 kHz.
    static func startFrame(for presentationTime: CMTime) -> Int64 {
        CMTimeConvertScale(
            presentationTime,
            timescale: Int32(outputSampleRate),
            method: .roundTowardZero
        ).value
    }

    static func copy(_ sampleBuffer: CMSampleBuffer) throws -> OwnedAudioPacket {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            throw SampleBufferConverterError.invalidSampleBuffer
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric, presentationTime >= .zero else {
            throw SampleBufferConverterError.invalidPresentationTime
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw SampleBufferConverterError.missingFormatDescription
        }

        let layout = try PCMLayoutValidator.validate(streamDescription.pointee)
        let pcm = try copyPCM(
            sampleBuffer,
            layout: layout,
            frameCount: CMSampleBufferGetNumSamples(sampleBuffer)
        )
        return OwnedAudioPacket(pcm: pcm, presentationTime: presentationTime)
    }

    private static func copyPCM(
        _ sampleBuffer: CMSampleBuffer,
        layout: PCMLayout,
        frameCount: Int
    ) throws -> OwnedPCMBuffer {
        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard sizeStatus == noErr, requiredSize > 0 else {
            throw SampleBufferConverterError.audioBufferListUnavailable
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        retainedBlockBuffer = nil
        let readStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard readStatus == noErr else {
            throw SampleBufferConverterError.audioBufferListReadFailed
        }
        guard let retainedBlockBuffer else {
            throw SampleBufferConverterError.audioBufferListUnavailable
        }

        return try withExtendedLifetime(retainedBlockBuffer) {
            let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let expectedBufferCount = layout.isInterleaved ? 1 : layout.channelCount
            guard audioBuffers.count == expectedBufferCount else {
                throw SampleBufferConverterError.invalidPCMLayout
            }

            var channels = Array(
                repeating: [Float](),
                count: layout.channelCount
            )
            for channelIndex in channels.indices {
                channels[channelIndex].reserveCapacity(frameCount)
            }

            if layout.isInterleaved {
                let buffer = audioBuffers[0]
                guard Int(buffer.mNumberChannels) == layout.channelCount else {
                    throw SampleBufferConverterError.invalidPCMLayout
                }
                try decodeInterleaved(
                    buffer,
                    layout: layout,
                    frameCount: frameCount,
                    into: &channels
                )
            } else {
                for channelIndex in 0..<layout.channelCount {
                    let buffer = audioBuffers[channelIndex]
                    guard buffer.mNumberChannels == 1 else {
                        throw SampleBufferConverterError.invalidPCMLayout
                    }
                    try decodePlanar(
                        buffer,
                        layout: layout,
                        frameCount: frameCount,
                        into: &channels[channelIndex]
                    )
                }
            }

            return OwnedPCMBuffer(
                sampleRate: layout.sampleRate,
                channels: channels
            )
        }
    }

    private static func decodeInterleaved(
        _ buffer: AudioBuffer,
        layout: PCMLayout,
        frameCount: Int,
        into channels: inout [[Float]]
    ) throws {
        guard let data = buffer.mData,
              Int(buffer.mDataByteSize) >= frameCount * layout.bytesPerFrame else {
            throw SampleBufferConverterError.invalidPCMLayout
        }
        let sampleBytes = layout.encoding.storageByteCount
        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<layout.channelCount {
                let offset = frameIndex * layout.bytesPerFrame + channelIndex * sampleBytes
                channels[channelIndex].append(
                    try PCMByteDecoder.decode(
                        UnsafeRawPointer(data).advanced(by: offset),
                        encoding: layout.encoding
                    )
                )
            }
        }
    }

    private static func decodePlanar(
        _ buffer: AudioBuffer,
        layout: PCMLayout,
        frameCount: Int,
        into samples: inout [Float]
    ) throws {
        guard let data = buffer.mData,
              Int(buffer.mDataByteSize) >= frameCount * layout.bytesPerFrame else {
            throw SampleBufferConverterError.invalidPCMLayout
        }
        for frameIndex in 0..<frameCount {
            samples.append(
                try PCMByteDecoder.decode(
                    UnsafeRawPointer(data).advanced(by: frameIndex * layout.bytesPerFrame),
                    encoding: layout.encoding
                )
            )
        }
    }
}

final class PersistentAudioResampler {
    private let source: AudioSourceKind
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var inputSampleRate: Double?
    private var inputChannelCount: Int?
    private var expectedInputPresentationTime: CMTime?
    private var outputCursor: Int64?

    init(source: AudioSourceKind) {
        self.source = source
    }

    func process(_ packet: OwnedAudioPacket) throws -> AudioFrameBlock? {
        try validate(packet)

        let channelCount = packet.pcm.channels.count
        let mustReset = inputSampleRate != packet.pcm.sampleRate ||
            inputChannelCount != channelCount ||
            !isContinuous(packet.presentationTime, sampleRate: packet.pcm.sampleRate)
        if mustReset {
            try reset(
                sampleRate: packet.pcm.sampleRate,
                channelCount: channelCount,
                presentationTime: packet.presentationTime
            )
        }

        let normalized: OwnedPCMBuffer
        if packet.pcm.sampleRate == SampleBufferConverter.outputSampleRate {
            normalized = stereoPCM(from: packet.pcm)
        } else {
            normalized = try convert(packet.pcm)
        }
        expectedInputPresentationTime = CMTimeAdd(
            packet.presentationTime,
            CMTime(
                value: CMTimeValue(packet.pcm.frameCount),
                timescale: CMTimeScale(packet.pcm.sampleRate.rounded())
            )
        )

        guard normalized.frameCount > 0 else { return nil }
        let startFrame = outputCursor ?? SampleBufferConverter.startFrame(for: packet.presentationTime)
        let block = try AudioFrameBlock.stereo(
            source: source,
            startFrame: startFrame,
            left: normalized.channels[0],
            right: normalized.channels[1]
        )
        outputCursor = startFrame + Int64(block.frameCount)
        return block
    }

    private func validate(_ packet: OwnedAudioPacket) throws {
        guard packet.presentationTime.isValid,
              packet.presentationTime.isNumeric,
              packet.presentationTime >= .zero else {
            throw SampleBufferConverterError.invalidPresentationTime
        }
        guard packet.pcm.sampleRate.isFinite,
              packet.pcm.sampleRate > 0,
              (1...2).contains(packet.pcm.channels.count),
              packet.pcm.frameCount > 0,
              packet.pcm.channels.allSatisfy({ $0.count == packet.pcm.frameCount }) else {
            throw SampleBufferConverterError.mismatchedChannelFrames
        }
    }

    private func isContinuous(_ presentationTime: CMTime, sampleRate: Double) -> Bool {
        guard let expectedInputPresentationTime,
              inputSampleRate == sampleRate else {
            return false
        }
        let delta = abs(CMTimeGetSeconds(CMTimeSubtract(
            presentationTime,
            expectedInputPresentationTime
        )))
        return delta <= 0.5 / sampleRate
    }

    private func reset(
        sampleRate: Double,
        channelCount: Int,
        presentationTime: CMTime
    ) throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw SampleBufferConverterError.converterCreationFailed
        }
        self.inputFormat = inputFormat
        inputSampleRate = sampleRate
        inputChannelCount = channelCount
        expectedInputPresentationTime = nil
        outputCursor = SampleBufferConverter.startFrame(for: presentationTime)

        if sampleRate == SampleBufferConverter.outputSampleRate {
            converter = nil
            return
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SampleBufferConverter.outputSampleRate,
            channels: 2,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SampleBufferConverterError.converterCreationFailed
        }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        self.converter = converter
    }

    private func stereoPCM(from pcm: OwnedPCMBuffer) -> OwnedPCMBuffer {
        let right = pcm.channels.count == 2 ? pcm.channels[1] : pcm.channels[0]
        return OwnedPCMBuffer(
            sampleRate: SampleBufferConverter.outputSampleRate,
            channels: [pcm.channels[0], right]
        )
    }

    private func convert(_ pcm: OwnedPCMBuffer) throws -> OwnedPCMBuffer {
        guard let converter, let inputFormat,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(pcm.frameCount)
              ) else {
            throw SampleBufferConverterError.converterCreationFailed
        }
        inputBuffer.frameLength = AVAudioFrameCount(pcm.frameCount)
        let stereo = stereoPCM(from: pcm)
        guard let inputChannels = inputBuffer.floatChannelData else {
            throw SampleBufferConverterError.converterCreationFailed
        }
        for channelIndex in 0..<2 {
            stereo.channels[channelIndex].withUnsafeBufferPointer { samples in
                inputChannels[channelIndex].update(
                    from: samples.baseAddress!,
                    count: samples.count
                )
            }
        }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(pcm.frameCount) *
                SampleBufferConverter.outputSampleRate / pcm.sampleRate) + 64
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw SampleBufferConverterError.converterCreationFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil else {
            throw SampleBufferConverterError.converterFailed
        }
        guard outputBuffer.frameLength > 0,
              let outputChannels = outputBuffer.floatChannelData else {
            return OwnedPCMBuffer(
                sampleRate: SampleBufferConverter.outputSampleRate,
                channels: [[], []]
            )
        }

        let frameCount = Int(outputBuffer.frameLength)
        return OwnedPCMBuffer(
            sampleRate: SampleBufferConverter.outputSampleRate,
            channels: [
                Array(UnsafeBufferPointer(start: outputChannels[0], count: frameCount)),
                Array(UnsafeBufferPointer(start: outputChannels[1], count: frameCount))
            ]
        )
    }
}
