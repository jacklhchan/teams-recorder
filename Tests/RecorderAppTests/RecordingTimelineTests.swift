import CoreMedia
import XCTest
@testable import RecorderApp

final class RecordingTimelineTests: XCTestCase {
    func testFirstMixedAudioAnchorsSessionAtZero() {
        var timeline = RecordingTimeline()
        let mapped = timeline.mapAudio(block(96_000, count: 480))

        XCTAssertEqual(mapped.presentationTime, .zero)
        XCTAssertEqual(timeline.currentAudioEndTime, time(480))
    }

    func testEarlyVideoIsBoundedUntilAudioAnchorExists() {
        var timeline = RecordingTimeline()
        XCTAssertEqual(timeline.mapVideo(time(100)), .pending)
        XCTAssertEqual(timeline.mapVideo(time(109)), .pending)

        timeline.establishVideoAnchor(at: time(100))
        XCTAssertEqual(timeline.mapVideo(time(100)), .append(.zero))
        XCTAssertEqual(timeline.mapVideo(time(109)), .append(time(9)))
    }

    func testVideoCanAnchorAfterOneSecondWithoutAudio() {
        var timeline = RecordingTimeline()
        timeline.establishVideoAnchor(at: time(200))

        XCTAssertEqual(timeline.mapVideo(time(200)), .append(.zero))
        XCTAssertEqual(timeline.mapVideo(time(48_200)), .append(time(48_000)))
    }

    func testForcedVideoAnchorIsImmutableWhenAudioArrives() {
        var timeline = RecordingTimeline()
        timeline.establishVideoAnchor(at: time(100))
        let mapped = timeline.mapAudio(block(48_100, count: 480))

        XCTAssertEqual(mapped.presentationTime, time(48_000))
        XCTAssertEqual(timeline.currentAudioEndTime, time(48_480))
    }

    func testInitialVideoBeforeAnchorDropsBackwardWithoutNegativePTS() {
        var timeline = RecordingTimeline()
        timeline.establishVideoAnchor(at: time(100))

        XCTAssertEqual(timeline.mapVideo(time(99)), .dropBackward)
        XCTAssertEqual(timeline.backwardVideoCount, 1)
    }

    func testAudioGapUsesSparsePresentationTimeWithoutAllocatingSilence() {
        var timeline = RecordingTimeline()
        let first = timeline.mapAudio(block(0, count: 4))
        let second = timeline.mapAudio(block(172_800_000, count: 4))

        XCTAssertEqual(first.presentationTime, .zero)
        XCTAssertEqual(second.presentationTime, time(172_800_000))
        XCTAssertEqual(timeline.currentAudioEndTime, time(172_800_004))
        XCTAssertEqual(first.block.left.count + second.block.left.count, 8)
    }

    func testDuplicateBackwardAndFarFutureVideoPTSIsRejected() {
        var timeline = RecordingTimeline()
        _ = timeline.mapAudio(block(0, count: 480))
        XCTAssertEqual(timeline.mapVideo(time(480)), .append(time(480)))
        XCTAssertEqual(timeline.mapVideo(time(480)), .dropDuplicate)
        XCTAssertEqual(timeline.mapVideo(time(479)), .dropBackward)
        XCTAssertEqual(timeline.mapVideo(time(96_481)), .dropFarFuture)
        XCTAssertEqual(timeline.duplicateVideoCount, 1)
        XCTAssertEqual(timeline.backwardVideoCount, 1)
        XCTAssertEqual(timeline.farFutureVideoCount, 1)
    }

    func testDuplicateIsClassifiedBeforeFarFuture() {
        var timeline = RecordingTimeline()
        timeline.establishVideoAnchor(at: time(200_000))
        XCTAssertEqual(timeline.mapVideo(time(200_000)), .append(.zero))
        XCTAssertEqual(timeline.mapVideo(time(200_000)), .dropDuplicate)
        XCTAssertEqual(timeline.duplicateVideoCount, 1)
        XCTAssertEqual(timeline.farFutureVideoCount, 0)
    }

    func testInclusiveTwoSecondVideoBoundaryIsAccepted() {
        var timeline = RecordingTimeline()
        _ = timeline.mapAudio(block(0, count: 480))
        XCTAssertEqual(timeline.mapVideo(time(96_480)), .append(time(96_480)))
    }

    func testVideoSourcePTSUsesTowardZero48kConversion() {
        var timeline = RecordingTimeline()
        _ = timeline.mapAudio(block(48_000, count: 480))
        XCTAssertEqual(timeline.mapVideo(CMTime(value: 90_001, timescale: 90_000)), .append(.zero))
    }

    func testAudioEndTimeUsesStartFramePlusFrameCount() {
        var timeline = RecordingTimeline()
        _ = timeline.mapAudio(block(48_000, count: 1))
        let mapped = timeline.mapAudio(block(49_920, count: 960))

        XCTAssertEqual(mapped.presentationTime, time(1_920))
        XCTAssertEqual(timeline.currentAudioEndTime, time(2_880))
    }

    func testExtremeAudioFramesSaturateWithoutAllocatingOrTrapping() {
        var timeline = RecordingTimeline()
        let first = timeline.mapAudio(block(Int64.min, count: 1))
        let second = timeline.mapAudio(block(Int64.max, count: 1))

        XCTAssertEqual(first.presentationTime, .zero)
        XCTAssertEqual(second.presentationTime, time(Int64.max))
        XCTAssertEqual(timeline.currentAudioEndTime, time(Int64.max))
        XCTAssertEqual(first.block.left.count + second.block.left.count, 2)
    }

    func testOverflowingVideoDifferenceDropsSafely() {
        var timeline = RecordingTimeline()
        _ = timeline.mapAudio(block(Int64.min, count: 1))
        _ = timeline.mapAudio(block(Int64.max, count: 1))

        XCTAssertEqual(timeline.mapVideo(time(Int64.max)), .dropFarFuture)
        XCTAssertEqual(timeline.farFutureVideoCount, 1)
    }

    func testOverflowingVideoLeadLimitDropsSafely() {
        var timeline = RecordingTimeline()
        timeline.establishVideoAnchor(at: .zero)
        _ = timeline.mapAudio(block(Int64.max, count: 1))

        XCTAssertEqual(timeline.mapVideo(time(Int64.max)), .dropFarFuture)
        XCTAssertEqual(timeline.farFutureVideoCount, 1)
    }

    private func block(_ startFrame: Int64, count: Int) -> MixedAudioBlock {
        MixedAudioBlock(startFrame: startFrame, left: Array(repeating: 0, count: count), right: Array(repeating: 0, count: count))
    }

    private func time(_ frame: Int64) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: 48_000)
    }
}
