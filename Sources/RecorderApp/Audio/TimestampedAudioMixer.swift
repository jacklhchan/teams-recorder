import Foundation

enum TimestampedAudioMixerError: Error, Equatable {
    case unsupportedSampleRate(Int)
}

struct TimestampedAudioMixer {
    var isMicrophoneMuted = false
    private(set) var lateFrameCount = 0
    private(set) var isSystemSourceConnected = true
    private(set) var isMicrophoneSourceConnected = true
    /// Downstream engines must compare block start frames with prior end frames and report gaps.
    /// A discontinuity must not be treated as continuous elapsed recording duration.
    private(set) var timelineDiscontinuityCount = 0

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

    mutating func setMicrophoneSourceConnected(_ isConnected: Bool) {
        guard isMicrophoneSourceConnected != isConnected else {
            return
        }

        isMicrophoneSourceConnected = isConnected
        highestKnownEnd[.microphone] = nil
        pendingSamples[.microphone] = [:]
    }

    mutating func push(_ block: AudioFrameBlock) -> [MixedAudioBlock] {
        guard block.frameCount > 0 else {
            return []
        }
        guard (block.source != .system || isSystemSourceConnected),
              (block.source != .microphone || isMicrophoneSourceConnected) else {
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
        emitContiguousSegments(through: frame, policy: .final)
    }

    private mutating func emitThroughKnownFrames() -> [MixedAudioBlock] {
        let knownEnd: Int64
        if isSystemSourceConnected && isMicrophoneSourceConnected {
            guard let systemEnd = highestKnownEnd[.system],
                  let microphoneEnd = highestKnownEnd[.microphone] else {
                return []
            }
            knownEnd = min(systemEnd, microphoneEnd)
        } else if isSystemSourceConnected, let systemEnd = highestKnownEnd[.system] {
            knownEnd = systemEnd
        } else if let microphoneEnd = highestKnownEnd[.microphone] {
            knownEnd = microphoneEnd
        } else {
            return []
        }

        return emitContiguousSegments(through: knownEnd, policy: .live)
    }

    private mutating func emitToMaintainPendingLimit() -> [MixedAudioBlock] {
        emitContiguousSegments(through: nil, policy: .pressure)
    }

    private mutating func emitContiguousSegments(
        through frame: Int64?,
        policy: EmissionPolicy
    ) -> [MixedAudioBlock] {
        var output: [MixedAudioBlock] = []

        while true {
            if policy == .pressure,
               pendingFrameCount <= maximumPendingFrames {
                break
            }
            guard let segment = nextContiguousSegment(before: frame) else {
                break
            }

            if policy == .live,
               segment.frameCount < blockFrames,
               earliestPendingFrame(
                   atOrAfter: segment.endFrame,
                   before: frame
               ) == nil {
                break
            }

            output.append(makeMixedBlock(
                startFrame: segment.startFrame,
                frameCount: segment.frameCount
            ))
            consumePendingSamples(through: segment.endFrame)
            nextOutputFrame = segment.endFrame
        }

        return output
    }

    private mutating func nextContiguousSegment(
        before frame: Int64?
    ) -> PendingSegment? {
        guard let outputFrame = nextOutputFrame,
              let earliestPendingFrame = earliestPendingFrame(
                  atOrAfter: outputFrame,
                  before: frame
              ) else {
            return nil
        }
        if earliestPendingFrame > outputFrame {
            nextOutputFrame = earliestPendingFrame
            timelineDiscontinuityCount += 1
        }
        guard let startFrame = nextOutputFrame else {
            return nil
        }

        let maximumEndFrame = min(
            frame ?? startFrame + Int64(blockFrames),
            startFrame + Int64(blockFrames)
        )
        var contiguousEndFrame = startFrame
        while contiguousEndFrame < maximumEndFrame,
              hasPendingSample(at: contiguousEndFrame) {
            contiguousEndFrame += 1
        }
        guard contiguousEndFrame > startFrame else {
            return nil
        }

        return PendingSegment(
            startFrame: startFrame,
            frameCount: Int(contiguousEndFrame - startFrame)
        )
    }

    private func earliestPendingFrame(
        atOrAfter startFrame: Int64,
        before endFrame: Int64?
    ) -> Int64? {
        pendingSamples.values
            .flatMap(\.keys)
            .filter { pendingFrame in
                pendingFrame >= startFrame &&
                    (endFrame.map { pendingFrame < $0 } ?? true)
            }
            .min()
    }

    private func hasPendingSample(at frame: Int64) -> Bool {
        pendingSamples[.system]?[frame] != nil ||
            pendingSamples[.microphone]?[frame] != nil
    }

    private func makeMixedBlock(
        startFrame: Int64,
        frameCount: Int
    ) -> MixedAudioBlock {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            let frame = startFrame + Int64(index)
            let system = isSystemSourceConnected
                ? pendingSamples[.system]?[frame] ?? .silence
                : .silence
            let microphone = isMicrophoneMuted || !isMicrophoneSourceConnected
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

private enum EmissionPolicy {
    case live
    case pressure
    case final
}

private struct PendingSegment {
    let startFrame: Int64
    let frameCount: Int

    var endFrame: Int64 {
        startFrame + Int64(frameCount)
    }
}

private struct StereoSample {
    let left: Float
    let right: Float

    static let silence = StereoSample(left: 0, right: 0)
}
