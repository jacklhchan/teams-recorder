import CoreMedia
import XCTest
@testable import RecorderApp

final class VideoGateTests: XCTestCase {
    func testGateStartsWithBlackAndDropsFramesWhileOff() {
        var gate = VideoGate(activeFilterRevision: revision(7))
        XCTAssertEqual(gate.start(at: time(0)), [.appendBlack(time(0))])
        XCTAssertEqual(gate.submitFrame(at: time(960), isComplete: true, sourceAvailable: true, filterRevision: revision(7)), [.drop])
        XCTAssertTrue(gate.recordedScreenIntervals.isEmpty)
    }

    func testGateStartAlwaysAppendsBlackAtZero() {
        var gate = VideoGate(activeFilterRevision: revision(7))
        XCTAssertEqual(gate.start(at: time(960)), [.appendBlack(.zero)])
    }

    func testEnableDisableReenableCreatesTwoIntervals() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(480))
        XCTAssertEqual(gate.submitFrame(at: time(960), isComplete: true, sourceAvailable: true, filterRevision: revision(7)), [.appendReal(time(960))])
        XCTAssertEqual(gate.setScreenIntent(false, at: time(1_440)), [.appendBlack(time(1_440))])
        _ = gate.setScreenIntent(true, at: time(1_920))
        XCTAssertEqual(gate.submitFrame(at: time(2_400), isComplete: true, sourceAvailable: true, filterRevision: revision(7)), [.appendReal(time(2_400))])
        XCTAssertEqual(gate.recordedScreenIntervals, [RecordedScreenInterval(startSeconds: 0.02, endSeconds: 0.03)])
    }

    func testStallClosesIntervalAndHoldsBlackAtExactOnePointFiveSeconds() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))
        _ = gate.submitFrame(at: time(960), isComplete: true, sourceAvailable: true, filterRevision: revision(7))
        XCTAssertEqual(gate.checkForStall(at: time(72_959)), [])
        XCTAssertEqual(gate.checkForStall(at: time(72_960)), [.appendBlack(time(72_960))])
        XCTAssertEqual(gate.checkForStall(at: time(72_961)), [])
    }

    func testIdleSourceActivityKeepsTheOpenIntervalAlive() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))
        _ = gate.submitFrame(
            at: time(960),
            isComplete: true,
            sourceAvailable: true,
            filterRevision: revision(7)
        )
        _ = gate.submitFrame(
            at: time(48_000),
            isComplete: false,
            sourceAvailable: true,
            filterRevision: revision(7)
        )

        XCTAssertEqual(gate.checkForStall(at: time(72_960)), [])
    }

    func testReusableIdleFrameCanOpenAnIntervalAfterCompleteFrameWasDropped() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))

        let actions = gate.submitFrame(
            at: time(960),
            isComplete: false,
            sourceAvailable: true,
            filterRevision: revision(7)
        )

        XCTAssertEqual(actions, [.appendReal(time(960))])
    }

    func testStaleFilterRevisionCannotEnterRecording() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))
        XCTAssertEqual(gate.submitFrame(at: time(960), isComplete: true, sourceAvailable: true, filterRevision: revision(6)), [.drop])
        XCTAssertTrue(gate.recordedScreenIntervals.isEmpty)
    }

    func testStaleRevisionClosesActiveIntervalWithOneBlack() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))
        XCTAssertEqual(gate.submitFrame(at: time(960), isComplete: true, sourceAvailable: true, filterRevision: revision(7)), [.appendReal(time(960))])

        let staleSession = CaptureFilterRevision(sessionGeneration: 2, revision: 7)
        XCTAssertEqual(gate.submitFrame(at: time(1_440), isComplete: true, sourceAvailable: true, filterRevision: staleSession), [.appendBlack(time(1_440))])
        XCTAssertEqual(gate.recordedScreenIntervals, [RecordedScreenInterval(startSeconds: 0.02, endSeconds: 0.03)])
    }

    func testBackwardCloseDoesNotAppendBackwardBlackPTS() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))
        _ = gate.submitFrame(at: time(960), isComplete: true, sourceAvailable: true, filterRevision: revision(7))

        XCTAssertEqual(gate.submitFrame(at: time(959), isComplete: true, sourceAvailable: true, filterRevision: revision(6)), [])
    }

    func testFinishExtendsVideoTrackToAudioDuration() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))
        _ = gate.submitFrame(at: time(4_800), isComplete: true, sourceAvailable: true, filterRevision: revision(7))
        XCTAssertEqual(gate.finish(atAudioEnd: time(9_600)), [.appendBlack(time(9_599))])
    }

    func testFinishOmitsDegenerateFinalBlack() {
        var gate = startedGate()
        _ = gate.setScreenIntent(true, at: time(0))
        _ = gate.submitFrame(at: time(9_599), isComplete: true, sourceAvailable: true, filterRevision: revision(7))
        XCTAssertEqual(gate.finish(atAudioEnd: time(9_600)), [])
    }

    private func startedGate() -> VideoGate {
        var gate = VideoGate(activeFilterRevision: revision(7))
        _ = gate.start(at: time(0))
        return gate
    }

    private func time(_ frame: Int64) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: 48_000)
    }

    private func revision(_ revision: UInt64) -> CaptureFilterRevision {
        CaptureFilterRevision(sessionGeneration: 1, revision: revision)
    }
}
