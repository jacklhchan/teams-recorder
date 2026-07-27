import CoreMedia
import Foundation

enum VideoGateAction: Equatable {
    case appendBlack(CMTime)
    case appendReal(CMTime)
    case drop
}

struct VideoGate {
    private static let timescale: CMTimeScale = 48_000
    private static let stallFrames: Int64 = 72_000

    private let activeFilterRevision: CaptureFilterRevision
    private var screenIntent = false
    private var started = false
    private var openIntervalStartFrame: Int64?
    private var lastCompleteFrame: Int64?
    private var lastAppendedFrame: Int64?
    private(set) var recordedScreenIntervals: [RecordedScreenInterval] = []

    init(activeFilterRevision: CaptureFilterRevision) {
        self.activeFilterRevision = activeFilterRevision
    }

    mutating func start(at audioTime: CMTime) -> [VideoGateAction] {
        guard !started else { return [] }
        started = true
        lastAppendedFrame = 0
        return [.appendBlack(.zero)]
    }

    mutating func setScreenIntent(_ enabled: Bool, at audioTime: CMTime) -> [VideoGateAction] {
        screenIntent = enabled
        guard !enabled, let frame = frame(for: audioTime) else { return [] }
        return closeWithBlack(at: frame)
    }

    mutating func submitFrame(
        at audioTime: CMTime,
        isComplete: Bool,
        sourceAvailable: Bool,
        filterRevision: CaptureFilterRevision
    ) -> [VideoGateAction] {
        guard let frame = frame(for: audioTime) else { return [.drop] }
        if filterRevision != activeFilterRevision {
            return openIntervalStartFrame == nil ? [.drop] : closeWithBlack(at: frame)
        }
        guard screenIntent, isComplete, sourceAvailable else {
            if !sourceAvailable { return closeWithBlack(at: frame) }
            return [.drop]
        }

        lastCompleteFrame = frame
        openIntervalStartFrame = openIntervalStartFrame ?? frame
        lastAppendedFrame = frame
        return [.appendReal(time(for: frame))]
    }

    mutating func checkForStall(at audioTime: CMTime) -> [VideoGateAction] {
        guard let frame = frame(for: audioTime), let lastCompleteFrame else {
            return []
        }
        let (elapsed, overflow) = frame.subtractingReportingOverflow(lastCompleteFrame)
        guard (overflow && frame > lastCompleteFrame) || (!overflow && elapsed >= Self.stallFrames) else {
            return []
        }
        return closeWithBlack(at: frame)
    }

    mutating func finish(atAudioEnd audioEndTime: CMTime) -> [VideoGateAction] {
        guard let audioEndFrame = frame(for: audioEndTime), let openIntervalStartFrame else {
            return []
        }
        let (finalBlackFrame, subtractionOverflow) = audioEndFrame.subtractingReportingOverflow(1)
        guard !subtractionOverflow else {
            closeInterval(startFrame: openIntervalStartFrame, endFrame: audioEndFrame)
            self.openIntervalStartFrame = nil
            return []
        }
        guard let lastAppendedFrame, finalBlackFrame > lastAppendedFrame else {
            closeInterval(startFrame: openIntervalStartFrame, endFrame: audioEndFrame)
            self.openIntervalStartFrame = nil
            return []
        }
        self.openIntervalStartFrame = nil
        closeInterval(startFrame: openIntervalStartFrame, endFrame: finalBlackFrame)
        self.lastAppendedFrame = finalBlackFrame
        return [.appendBlack(time(for: finalBlackFrame))]
    }

    private mutating func closeWithBlack(at frame: Int64) -> [VideoGateAction] {
        guard let openIntervalStartFrame else { return [] }
        self.openIntervalStartFrame = nil
        closeInterval(startFrame: openIntervalStartFrame, endFrame: frame)
        guard lastAppendedFrame.map({ frame > $0 }) ?? true else { return [] }
        lastAppendedFrame = frame
        return [.appendBlack(time(for: frame))]
    }

    private mutating func closeInterval(startFrame: Int64, endFrame: Int64) {
        guard endFrame > startFrame else { return }
        recordedScreenIntervals.append(RecordedScreenInterval(
            startSeconds: Double(startFrame) / Double(Self.timescale),
            endSeconds: Double(endFrame) / Double(Self.timescale)
        ))
    }

    private func frame(for time: CMTime) -> Int64? {
        guard time.isValid, time.isNumeric, time >= .zero else { return nil }
        return SampleBufferConverter.startFrame(for: time)
    }

    private func time(for frame: Int64) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: Self.timescale)
    }
}
