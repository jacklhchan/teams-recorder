import AudioToolbox
import CoreMedia
import Foundation

enum SampleBufferConverterError: Error, Equatable {
    case invalidSampleBuffer
    case missingFormatDescription
    case unsupportedFormat
    case unsupportedByteOrder
    case invalidPCMLayout
    case invalidPresentationTime
    case audioBufferListUnavailable
    case audioBufferListReadFailed
    case mismatchedChannelFrames
}

struct OwnedPCMBuffer: Equatable {
    let sampleRate: Double
    let channels: [[Float]]

    var frameCount: Int {
        channels.first?.count ?? 0
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

    static func convert(
        _ sampleBuffer: CMSampleBuffer,
        source: AudioSourceKind
    ) throws -> AudioFrameBlock {
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

        let format = streamDescription.pointee
        guard format.mFormatID == kAudioFormatLinearPCM else {
            throw SampleBufferConverterError.unsupportedFormat
        }

        let flags = format.mFormatFlags
        guard flags & UInt32(kAudioFormatFlagIsBigEndian) == 0 else {
            throw SampleBufferConverterError.unsupportedByteOrder
        }

        let pcm = try copyPCM(
            sampleBuffer,
            format: format,
            frameCount: CMSampleBufferGetNumSamples(sampleBuffer)
        )
        return try normalize(pcm, source: source, presentationTime: presentationTime)
    }

    static func normalize(
        _ pcm: OwnedPCMBuffer,
        source: AudioSourceKind,
        presentationTime: CMTime
    ) throws -> AudioFrameBlock {
        guard presentationTime.isValid, presentationTime.isNumeric, presentationTime >= .zero else {
            throw SampleBufferConverterError.invalidPresentationTime
        }
        guard pcm.sampleRate > 0, !pcm.channels.isEmpty, pcm.frameCount > 0,
              pcm.channels.allSatisfy({ $0.count == pcm.frameCount }) else {
            throw SampleBufferConverterError.mismatchedChannelFrames
        }

        let outputFrameCount = max(
            1,
            Int((Double(pcm.frameCount) * outputSampleRate / pcm.sampleRate).rounded(.towardZero))
        )
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(outputFrameCount)
        right.reserveCapacity(outputFrameCount)

        let rightChannel = pcm.channels.count > 1 ? pcm.channels[1] : pcm.channels[0]
        for outputIndex in 0..<outputFrameCount {
            let inputPosition = Double(outputIndex) * pcm.sampleRate / outputSampleRate
            let inputIndex = min(pcm.frameCount - 1, Int(inputPosition.rounded(.down)))
            left.append(pcm.channels[0][inputIndex])
            right.append(rightChannel[inputIndex])
        }

        return try AudioFrameBlock.stereo(
            source: source,
            startFrame: startFrame(for: presentationTime),
            left: left,
            right: right
        )
    }

    private static func copyPCM(
        _ sampleBuffer: CMSampleBuffer,
        format: AudioStreamBasicDescription,
        frameCount: Int
    ) throws -> OwnedPCMBuffer {
        let bitsPerChannel = Int(format.mBitsPerChannel)
        let bytesPerSample = (bitsPerChannel + 7) / 8
        let bytesPerFrame = Int(format.mBytesPerFrame)
        let channelCount = Int(format.mChannelsPerFrame)
        let isFloat = format.mFormatFlags & UInt32(kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = format.mFormatFlags & UInt32(kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = format.mFormatFlags & UInt32(kAudioFormatFlagIsNonInterleaved) != 0

        guard channelCount > 0, bytesPerSample > 0, bytesPerFrame >= bytesPerSample,
              isFloat || isSignedInteger else {
            throw SampleBufferConverterError.invalidPCMLayout
        }

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

        let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels: [[Float]] = []
        channels.reserveCapacity(channelCount)

        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else {
                throw SampleBufferConverterError.invalidPCMLayout
            }
            let channelsInBuffer = max(1, Int(audioBuffer.mNumberChannels))
            let interleavedBuffer = !isNonInterleaved && channelsInBuffer > 1
            for channelIndex in 0..<channelsInBuffer {
                guard channels.count < channelCount else { break }
                var samples: [Float] = []
                samples.reserveCapacity(frameCount)
                for frameIndex in 0..<frameCount {
                    let offset = frameIndex * bytesPerFrame + (interleavedBuffer ? channelIndex * bytesPerSample : 0)
                    guard offset + bytesPerSample <= Int(audioBuffer.mDataByteSize) else {
                        throw SampleBufferConverterError.invalidPCMLayout
                    }
                    samples.append(
                        try sample(
                            at: data.advanced(by: offset),
                            bitsPerChannel: bitsPerChannel,
                            isFloat: isFloat
                        )
                    )
                }
                channels.append(samples)
            }
        }

        guard channels.count == channelCount else {
            throw SampleBufferConverterError.invalidPCMLayout
        }
        return OwnedPCMBuffer(sampleRate: format.mSampleRate, channels: channels)
    }

    private static func sample(
        at pointer: UnsafeMutableRawPointer,
        bitsPerChannel: Int,
        isFloat: Bool
    ) throws -> Float {
        switch (isFloat, bitsPerChannel) {
        case (true, 32):
            return Float(bitPattern: UInt32(littleEndian: pointer.loadUnaligned(as: UInt32.self)))
        case (false, 16):
            let value = Int16(littleEndian: pointer.loadUnaligned(as: Int16.self))
            return Float(value) / Float(Int16.max)
        case (false, 24):
            let bytes = pointer.assumingMemoryBound(to: UInt8.self)
            let unsigned = Int32(bytes[0]) | (Int32(bytes[1]) << 8) | (Int32(bytes[2]) << 16)
            let value = unsigned & 0x80_0000 == 0 ? unsigned : unsigned | ~0xFF_FFFF
            return Float(value) / 8_388_607
        case (false, 32):
            let value = Int32(littleEndian: pointer.loadUnaligned(as: Int32.self))
            return Float(value) / Float(Int32.max)
        default:
            throw SampleBufferConverterError.unsupportedFormat
        }
    }
}
