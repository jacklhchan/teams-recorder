import Foundation

enum AudioSourceKind: Hashable {
    case system
    case microphone
}

enum AudioFrameBlockError: Error, Equatable {
    case mismatchedChannelFrameCounts(left: Int, right: Int)
}

struct AudioFrameBlock: Equatable {
    let source: AudioSourceKind
    let startFrame: Int64
    let left: [Float]
    let right: [Float]

    private init(
        source: AudioSourceKind,
        startFrame: Int64,
        left: [Float],
        right: [Float]
    ) {
        self.source = source
        self.startFrame = startFrame
        self.left = left
        self.right = right
    }

    var frameCount: Int {
        left.count
    }

    static func stereo(
        source: AudioSourceKind,
        startFrame: Int64,
        left: [Float],
        right: [Float]
    ) throws -> AudioFrameBlock {
        guard left.count == right.count else {
            throw AudioFrameBlockError.mismatchedChannelFrameCounts(
                left: left.count,
                right: right.count
            )
        }

        return AudioFrameBlock(
            source: source,
            startFrame: startFrame,
            left: left,
            right: right
        )
    }
}

struct MixedAudioBlock: Equatable {
    let startFrame: Int64
    let left: [Float]
    let right: [Float]

    static func silence(startFrame: Int64, frameCount: Int) -> MixedAudioBlock {
        MixedAudioBlock(
            startFrame: startFrame,
            left: Array(repeating: 0, count: frameCount),
            right: Array(repeating: 0, count: frameCount)
        )
    }
}
