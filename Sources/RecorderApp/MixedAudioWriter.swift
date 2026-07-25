@preconcurrency import AVFoundation
import Foundation

protocol MixedAudioWriting: AnyObject {
    func write(_ block: MixedAudioBlock) throws
    func close() throws
}

typealias MixedAudioWriterFactory = (URL) throws -> MixedAudioWriting

final class AACMixedAudioWriter: MixedAudioWriting {
    private let format: AVAudioFormat
    private var file: AVAudioFile?

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw RecordingEngineError.unsupportedFormat
        }
        self.format = format
        self.file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func write(_ block: MixedAudioBlock) throws {
        guard !block.left.isEmpty, block.left.count == block.right.count,
              let file,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(block.left.count)
              ),
              let channels = buffer.floatChannelData else {
            return
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
