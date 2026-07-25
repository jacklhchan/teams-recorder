import Foundation

struct TimestampedAudioMixer {
    var isMicrophoneMuted = false
    private(set) var lateFrameCount = 0

    private let blockFrames: Int
    private let maximumPendingFrames: Int
    private var nextOutputFrame: Int64 = 0
    private var highestKnownEnd: [AudioSourceKind: Int64] = [:]
    private var pendingSamples: [AudioSourceKind: [Int64: StereoSample]] = [:]

    var pendingFrameCount: Int {
        pendingSamples.values.reduce(0) { $0 + $1.count }
    }

    init(
        sampleRate: Int,
        blockFrames: Int,
        maximumPendingFrames: Int? = nil
    ) {
        precondition(sampleRate > 0)
        precondition(blockFrames > 0)

        self.blockFrames = blockFrames
        self.maximumPendingFrames = max(
            blockFrames,
            maximumPendingFrames ?? sampleRate * 2
        )
    }

    mutating func push(_ block: AudioFrameBlock) -> [MixedAudioBlock] {
        guard block.frameCount > 0 else {
            return []
        }

        let endFrame = block.startFrame + Int64(block.frameCount)
        highestKnownEnd[block.source] = max(highestKnownEnd[block.source] ?? 0, endFrame)

        for index in 0..<block.frameCount {
            let frame = block.startFrame + Int64(index)
            if frame < nextOutputFrame {
                lateFrameCount += 1
            } else {
                pendingSamples[block.source, default: [:]][frame] = StereoSample(
                    left: block.left[index],
                    right: block.right[index]
                )
            }
        }

        return emitThroughKnownFrames() + emitToMaintainPendingLimit()
    }

    mutating func flushThrough(frame: Int64) -> [MixedAudioBlock] {
        emit(through: frame)
    }

    private mutating func emitThroughKnownFrames() -> [MixedAudioBlock] {
        guard let systemEnd = highestKnownEnd[.system],
              let microphoneEnd = highestKnownEnd[.microphone] else {
            return []
        }

        return emit(through: min(systemEnd, microphoneEnd))
    }

    private mutating func emit(through frame: Int64) -> [MixedAudioBlock] {
        var output: [MixedAudioBlock] = []
        let blockFrameCount = Int64(blockFrames)

        while nextOutputFrame + blockFrameCount <= frame {
            output.append(makeMixedBlock(startFrame: nextOutputFrame))
            consumePendingSamples(through: nextOutputFrame + blockFrameCount)
            nextOutputFrame += blockFrameCount
        }

        return output
    }

    private mutating func emitToMaintainPendingLimit() -> [MixedAudioBlock] {
        var output: [MixedAudioBlock] = []
        let blockFrameCount = Int64(blockFrames)

        while pendingFrameCount > maximumPendingFrames {
            output.append(makeMixedBlock(startFrame: nextOutputFrame))
            consumePendingSamples(through: nextOutputFrame + blockFrameCount)
            nextOutputFrame += blockFrameCount
        }

        return output
    }

    private func makeMixedBlock(startFrame: Int64) -> MixedAudioBlock {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(blockFrames)
        right.reserveCapacity(blockFrames)

        for index in 0..<blockFrames {
            let frame = startFrame + Int64(index)
            let system = pendingSamples[.system]?[frame] ?? .silence
            let microphone = isMicrophoneMuted
                ? .silence
                : pendingSamples[.microphone]?[frame] ?? .silence
            left.append(mix(system.left, microphone.left))
            right.append(mix(system.right, microphone.right))
        }

        return MixedAudioBlock(startFrame: startFrame, left: left, right: right)
    }

    private mutating func consumePendingSamples(through frame: Int64) {
        for source in [AudioSourceKind.system, .microphone] {
            guard let pending = pendingSamples[source] else {
                continue
            }
            pendingSamples[source] = pending.filter { $0.key >= frame }
        }
    }

    private func mix(_ systemSample: Float, _ microphoneSample: Float) -> Float {
        let mixed = (systemSample + microphoneSample) * 0.48
        guard abs(mixed) > 1 else {
            return mixed
        }

        let normalized = Float(tanh(Double(mixed) * 1.15) / tanh(1.15))
        return min(max(normalized, -1), 1)
    }
}

private struct StereoSample {
    let left: Float
    let right: Float

    static let silence = StereoSample(left: 0, right: 0)
}
