import Foundation

enum AudioSourceKind: Hashable {
    case system
    case microphone
}

struct AudioFrameBlock: Equatable {
    let source: AudioSourceKind
    let startFrame: Int64
    let left: [Float]
    let right: [Float]

    var frameCount: Int {
        min(left.count, right.count)
    }

    static func stereo(
        source: AudioSourceKind,
        startFrame: Int64,
        left: [Float],
        right: [Float]
    ) -> AudioFrameBlock {
        AudioFrameBlock(
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
