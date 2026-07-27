import CoreMedia

struct TimedMixedAudioBlock: Equatable {
    let block: MixedAudioBlock
    let presentationTime: CMTime
}

enum VideoTimestampDecision: Equatable {
    case pending
    case append(CMTime)
    case dropDuplicate
    case dropBackward
    case dropFarFuture
}

struct RecordingTimeline {
    private static let timescale: CMTimeScale = 48_000
    private static let maximumVideoLeadFrames: Int64 = 96_000

    private var sourceAnchorFrame: Int64?
    private var currentAudioEndFrame: Int64 = 0
    private var lastAcceptedVideoFrame: Int64?

    private(set) var duplicateVideoCount = 0
    private(set) var backwardVideoCount = 0
    private(set) var farFutureVideoCount = 0

    var currentAudioEndTime: CMTime {
        time(for: currentAudioEndFrame)
    }

    mutating func mapAudio(_ block: MixedAudioBlock) -> TimedMixedAudioBlock {
        if sourceAnchorFrame == nil {
            sourceAnchorFrame = block.startFrame
        }

        let presentationFrame = block.startFrame - sourceAnchorFrame!
        let endFrame = presentationFrame + Int64(block.left.count)
        currentAudioEndFrame = max(currentAudioEndFrame, endFrame)
        return TimedMixedAudioBlock(block: block, presentationTime: time(for: presentationFrame))
    }

    mutating func mapVideo(_ sourcePTS: CMTime) -> VideoTimestampDecision {
        guard let sourceFrame = sourceFrame(for: sourcePTS), let sourceAnchorFrame else {
            return .pending
        }

        let presentationFrame = sourceFrame - sourceAnchorFrame
        if let lastAcceptedVideoFrame {
            if presentationFrame == lastAcceptedVideoFrame {
                duplicateVideoCount += 1
                return .dropDuplicate
            }
            if presentationFrame < lastAcceptedVideoFrame {
                backwardVideoCount += 1
                return .dropBackward
            }
        }

        let referenceFrame = max(currentAudioEndFrame, lastAcceptedVideoFrame ?? 0)
        guard presentationFrame <= referenceFrame + Self.maximumVideoLeadFrames else {
            farFutureVideoCount += 1
            return .dropFarFuture
        }

        lastAcceptedVideoFrame = presentationFrame
        return .append(time(for: presentationFrame))
    }

    mutating func establishVideoAnchor(at sourcePTS: CMTime) {
        guard sourceAnchorFrame == nil, let sourceFrame = sourceFrame(for: sourcePTS) else {
            return
        }
        sourceAnchorFrame = sourceFrame
    }

    private func sourceFrame(for presentationTime: CMTime) -> Int64? {
        guard presentationTime.isValid, presentationTime.isNumeric, presentationTime >= .zero else {
            return nil
        }
        return SampleBufferConverter.startFrame(for: presentationTime)
    }

    private func time(for frame: Int64) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: Self.timescale)
    }
}
