import CoreMedia
import Foundation

enum VideoGateAction: Equatable {
    case appendBlack(CMTime)
    case appendClosingBlack(CMTime)
    case appendReal(CMTime)
    case drop
}

struct VideoGate {
    private static let timescale: CMTimeScale = 48_000

    private let activeFilterRevision: CaptureFilterRevision
    private var screenIntent = false
    private var started = false
    private var openIntervalStartFrame: Int64?
    private var lastAppendedFrame: Int64?
    private var closingBlackPending = false
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
        guard screenIntent, sourceAvailable else {
            if !sourceAvailable { return closeWithBlack(at: frame) }
            return [.drop]
        }
        guard isComplete || openIntervalStartFrame == nil else { return [.drop] }

        return [.appendReal(time(for: frame))]
    }

    mutating func commitRealFrame(at time: CMTime) {
        guard let frame = frame(for: time) else { return }
        openIntervalStartFrame = openIntervalStartFrame ?? frame
        lastAppendedFrame = frame
    }

    mutating func commitClosingBlack(at time: CMTime) {
        guard closingBlackPending,
              let frame = frame(for: time),
              let openIntervalStartFrame else {
            return
        }
        closingBlackPending = false
        self.openIntervalStartFrame = nil
        closeInterval(startFrame: openIntervalStartFrame, endFrame: frame)
        lastAppendedFrame = frame
    }

    mutating func finish(atAudioEnd audioEndTime: CMTime) -> [VideoGateAction] {
        guard !closingBlackPending,
              let audioEndFrame = frame(for: audioEndTime),
              let openIntervalStartFrame else {
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
        closingBlackPending = true
        return [.appendClosingBlack(time(for: finalBlackFrame))]
    }

    private mutating func closeWithBlack(at frame: Int64) -> [VideoGateAction] {
        guard openIntervalStartFrame != nil,
              !closingBlackPending else {
            return []
        }
        guard lastAppendedFrame.map({ frame > $0 }) ?? true else { return [] }
        closingBlackPending = true
        return [.appendClosingBlack(time(for: frame))]
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
