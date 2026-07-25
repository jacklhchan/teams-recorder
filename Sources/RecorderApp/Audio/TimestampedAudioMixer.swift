import Foundation

enum TimestampedAudioMixerError: Error, Equatable {
    case unsupportedSampleRate(Int)
}

struct TimestampedAudioMixer {
    var isMicrophoneMuted = false
    private(set) var lateFrameCount = 0
    private(set) var isSystemSourceConnected = true

    private let blockFrames: Int
    private let maximumPendingFrames: Int
    private var nextOutputFrame: Int64?
    private var highestKnownEnd: [AudioSourceKind: Int64] = [:]
    private var pendingSamples: [AudioSourceKind: [Int64: StereoSample]] = [:]

    var pendingFrameCount: Int {
        pendingSamples.values.reduce(0) { $0 + $1.count }
    }

    init(
        sampleRate: Int,
        blockFrames: Int,
        maximumPendingFrames: Int? = nil
    ) throws {
        guard sampleRate == 48_000 else {
            throw TimestampedAudioMixerError.unsupportedSampleRate(sampleRate)
        }
        precondition(blockFrames > 0)

        self.blockFrames = blockFrames
        self.maximumPendingFrames = max(
            blockFrames,
            maximumPendingFrames ?? sampleRate * 2
        )
    }

    mutating func setSystemSourceConnected(_ isConnected: Bool) {
        guard isSystemSourceConnected != isConnected else {
            return
        }

        isSystemSourceConnected = isConnected
        highestKnownEnd[.system] = nil
        pendingSamples[.system] = [:]
    }

    mutating func push(_ block: AudioFrameBlock) -> [MixedAudioBlock] {
        guard block.frameCount > 0 else {
            return []
        }
        guard block.source != .system || isSystemSourceConnected else {
            return []
        }

        if nextOutputFrame == nil {
            nextOutputFrame = block.startFrame
        }
        guard let outputFrame = nextOutputFrame else {
            return []
        }

        let endFrame = block.startFrame + Int64(block.frameCount)
        highestKnownEnd[block.source] = max(highestKnownEnd[block.source] ?? 0, endFrame)

        for index in 0..<block.frameCount {
            let frame = block.startFrame + Int64(index)
            if frame < outputFrame {
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
        if nextOutputFrame == nil {
            nextOutputFrame = 0
        }
        return emit(through: frame)
    }

    private mutating func emitThroughKnownFrames() -> [MixedAudioBlock] {
        let knownEnd: Int64
        if isSystemSourceConnected {
            guard let systemEnd = highestKnownEnd[.system],
                  let microphoneEnd = highestKnownEnd[.microphone] else {
                return []
            }
            knownEnd = min(systemEnd, microphoneEnd)
        } else if let microphoneEnd = highestKnownEnd[.microphone] {
            knownEnd = microphoneEnd
        } else {
            return []
        }

        skipUnobservedGap(through: knownEnd)
        return emit(through: knownEnd)
    }

    private mutating func emit(through frame: Int64) -> [MixedAudioBlock] {
        var output: [MixedAudioBlock] = []
        let blockFrameCount = Int64(blockFrames)

        while let outputFrame = nextOutputFrame,
              outputFrame + blockFrameCount <= frame {
            output.append(makeMixedBlock(startFrame: outputFrame))
            consumePendingSamples(through: outputFrame + blockFrameCount)
            nextOutputFrame = outputFrame + blockFrameCount
        }

        return output
    }

    private mutating func emitToMaintainPendingLimit() -> [MixedAudioBlock] {
        var output: [MixedAudioBlock] = []
        let blockFrameCount = Int64(blockFrames)

        while pendingFrameCount > maximumPendingFrames,
              let outputFrame = nextOutputFrame {
            output.append(makeMixedBlock(startFrame: outputFrame))
            consumePendingSamples(through: outputFrame + blockFrameCount)
            nextOutputFrame = outputFrame + blockFrameCount
        }

        return output
    }

    private mutating func skipUnobservedGap(through frame: Int64) {
        guard let outputFrame = nextOutputFrame,
              let earliestPendingFrame = pendingSamples.values
                .flatMap({ $0.keys })
                .filter({ $0 >= outputFrame && $0 < frame })
                .min(),
              earliestPendingFrame > outputFrame else {
            return
        }

        nextOutputFrame = earliestPendingFrame
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
