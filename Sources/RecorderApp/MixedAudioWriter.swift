@preconcurrency import AVFoundation
import Foundation

protocol MixedAudioWriting: AnyObject {
    func write(_ block: MixedAudioBlock) throws
    func close() throws
}

typealias MixedAudioWriterFactory = (URL) throws -> MixedAudioWriting

enum AACMixedAudioWriterError: Error, Equatable {
    case invalidBitRate(Int)
    case closed
    case emptyBlock
    case mismatchedChannelFrameCounts(left: Int, right: Int)
    case bufferAllocationFailed
}

struct AACMixedAudioWriterSettings: Equatable {
    let bitRate: Int
    let sampleRate: Double
    let channelCount: AVAudioChannelCount

    // Kept observable so tests can verify the exact settings handed to AVAudioFile.
    var avFoundationSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate
        ]
    }
}

final class AACMixedAudioWriter: MixedAudioWriting {
    private let format: AVAudioFormat
    private var file: AVAudioFile?

    init(url: URL, bitRate: Int = 192_000) throws {
        let settings = try Self.outputSettings(bitRate: bitRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: settings.sampleRate,
            channels: settings.channelCount,
            interleaved: false
        ) else {
            throw RecordingEngineError.unsupportedFormat
        }
        self.format = format
        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings.avFoundationSettings
        )
    }

    static func outputSettings(
        bitRate: Int = 192_000
    ) throws -> AACMixedAudioWriterSettings {
        guard bitRate > 0 else {
            throw AACMixedAudioWriterError.invalidBitRate(bitRate)
        }
        return AACMixedAudioWriterSettings(
            bitRate: bitRate,
            sampleRate: 48_000,
            channelCount: 2
        )
    }

    func write(_ block: MixedAudioBlock) throws {
        guard let file else {
            throw AACMixedAudioWriterError.closed
        }
        guard !block.left.isEmpty else {
            throw AACMixedAudioWriterError.emptyBlock
        }
        guard block.left.count == block.right.count else {
            throw AACMixedAudioWriterError.mismatchedChannelFrameCounts(
                left: block.left.count,
                right: block.right.count
            )
        }
        guard let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(block.left.count)
              ),
              let channels = buffer.floatChannelData else {
            throw AACMixedAudioWriterError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(block.left.count)
        for index in block.left.indices {
            channels[0][index] = block.left[index]
            channels[1][index] = block.right[index]
        }
        try file.write(from: buffer)
    }

    func close() throws {
        file = nil
    }
}
