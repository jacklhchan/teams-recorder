import XCTest
@testable import RecorderApp

final class TimestampedAudioMixerTests: XCTestCase {
    func testAlignsSourcesByAbsoluteStartFrame() throws {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 0,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))

        let output = mixer.push(.stereo(
            source: .microphone,
            startFrame: 2,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))

        let block = try XCTUnwrap(output.first)
        XCTAssertEqual(block.startFrame, 0)
        XCTAssertEqual(block.left.count, 4)
        XCTAssertEqual(block.left[0], 0.48, accuracy: 0.001)
        XCTAssertGreaterThan(block.left[2], 0.48)
    }

    func testMissingSourceProducesSilenceWithoutBlockingTimeline() {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)

        let output = mixer.flushThrough(frame: 4)

        XCTAssertEqual(output, [.silence(startFrame: 0, frameCount: 4)])
    }

    func testMutedMicrophoneDoesNotEnterMix() throws {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        mixer.isMicrophoneMuted = true
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 0,
            left: [0.5, 0.5, 0.5, 0.5],
            right: [0.5, 0.5, 0.5, 0.5]
        ))

        let output = mixer.push(.stereo(
            source: .microphone,
            startFrame: 0,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))

        XCTAssertEqual(try XCTUnwrap(output.first).left[0], 0.24, accuracy: 0.001)
    }

    func testLateBlockCannotRewriteAlreadyEmittedFrames() throws {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 0,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))
        let emitted = mixer.push(.stereo(
            source: .microphone,
            startFrame: 0,
            left: [0, 0, 0, 0],
            right: [0, 0, 0, 0]
        ))

        let lateOutput = mixer.push(.stereo(
            source: .system,
            startFrame: 2,
            left: [-1, -1, -1, -1],
            right: [-1, -1, -1, -1]
        ))
        let flushed = mixer.flushThrough(frame: 8)

        XCTAssertEqual(try XCTUnwrap(emitted.first).left[2], 0.48, accuracy: 0.001)
        XCTAssertTrue(lateOutput.isEmpty)
        XCTAssertEqual(mixer.lateFrameCount, 2)
        XCTAssertEqual(try XCTUnwrap(flushed.first).startFrame, 4)
    }

    func testOverlappingBlocksReplaceOnlySameSourcePendingFrames() throws {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 0,
            left: [0.1, 0.1, 0.1, 0.1],
            right: [0.1, 0.1, 0.1, 0.1]
        ))
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 2,
            left: [0.5, 0.5, 0.5, 0.5],
            right: [0.5, 0.5, 0.5, 0.5]
        ))

        let output = mixer.push(.stereo(
            source: .microphone,
            startFrame: 0,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))

        let block = try XCTUnwrap(output.first)
        XCTAssertEqual(block.left[0], 0.528, accuracy: 0.001)
        XCTAssertEqual(block.left[2], 0.72, accuracy: 0.001)
    }

    func testSoftLimiterKeepsSamplesWithinUnitRange() throws {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 0,
            left: [10, 10, 10, 10],
            right: [-10, -10, -10, -10]
        ))

        let output = mixer.push(.stereo(
            source: .microphone,
            startFrame: 0,
            left: [10, 10, 10, 10],
            right: [-10, -10, -10, -10]
        ))
        let block = try XCTUnwrap(output.first)

        XCTAssertTrue(block.left.allSatisfy { (-1...1).contains($0) })
        XCTAssertTrue(block.right.allSatisfy { (-1...1).contains($0) })
    }

    func testFlushAdvancesAcrossMultipleBlocks() {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)

        let output = mixer.flushThrough(frame: 12)

        XCTAssertEqual(output.map(\.startFrame), [0, 4, 8])
        XCTAssertEqual(output.map(\.left.count), [4, 4, 4])
    }

    func testPendingStateIsBoundedWhenOneSourceRunsAhead() {
        var mixer = TimestampedAudioMixer(
            sampleRate: 48_000,
            blockFrames: 4,
            maximumPendingFrames: 4
        )
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 0,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 4,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))

        XCTAssertLessThanOrEqual(mixer.pendingFrameCount, 4)
    }

    func testBoundedPendingStateDoesNotDiscardFramesFromRunningAheadSource() throws {
        var mixer = TimestampedAudioMixer(
            sampleRate: 48_000,
            blockFrames: 4,
            maximumPendingFrames: 4
        )
        _ = mixer.push(.stereo(
            source: .system,
            startFrame: 0,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))
        let forced = mixer.push(.stereo(
            source: .system,
            startFrame: 4,
            left: [1, 1, 1, 1],
            right: [1, 1, 1, 1]
        ))
        _ = mixer.push(.stereo(
            source: .microphone,
            startFrame: 0,
            left: [0, 0, 0, 0],
            right: [0, 0, 0, 0]
        ))
        let next = mixer.push(.stereo(
            source: .microphone,
            startFrame: 4,
            left: [0, 0, 0, 0],
            right: [0, 0, 0, 0]
        ))

        XCTAssertEqual(try XCTUnwrap(forced.first).startFrame, 0)
        XCTAssertEqual(try XCTUnwrap(next.first).left[0], 0.48, accuracy: 0.001)
    }
}
