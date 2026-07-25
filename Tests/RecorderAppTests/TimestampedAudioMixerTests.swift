import XCTest
@testable import RecorderApp

final class TimestampedAudioMixerTests: XCTestCase {
    func testAlignsSourcesByAbsoluteStartFrame() throws {
        var mixer = try makeMixer()
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))

        let output = try mixer.push(stereo(
            .microphone,
            startFrame: 2,
            samples: [1, 1, 1, 1]
        ))

        let block = try XCTUnwrap(output.first)
        XCTAssertEqual(block.startFrame, 0)
        XCTAssertEqual(block.left.count, 4)
        XCTAssertEqual(block.left[0], 0.48, accuracy: 0.001)
        XCTAssertGreaterThan(block.left[2], 0.48)
    }

    func testMissingSourceProducesSilenceWithoutBlockingTimeline() throws {
        var mixer = try makeMixer()

        let output = mixer.flushThrough(frame: 4)

        XCTAssertEqual(output, [.silence(startFrame: 0, frameCount: 4)])
    }

    func testMutedMicrophoneDoesNotEnterMix() throws {
        var mixer = try makeMixer()
        mixer.isMicrophoneMuted = true
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [0.5, 0.5, 0.5, 0.5]))

        let output = try mixer.push(stereo(.microphone, startFrame: 0, samples: [1, 1, 1, 1]))

        XCTAssertEqual(try XCTUnwrap(output.first).left[0], 0.24, accuracy: 0.001)
    }

    func testLateBlockCannotRewriteAlreadyEmittedFrames() throws {
        var mixer = try makeMixer()
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))
        let emitted = try mixer.push(stereo(.microphone, startFrame: 0, samples: [0, 0, 0, 0]))

        let lateOutput = try mixer.push(stereo(.system, startFrame: 2, samples: [-1, -1, -1, -1]))
        let flushed = mixer.flushThrough(frame: 8)

        XCTAssertEqual(try XCTUnwrap(emitted.first).left[2], 0.48, accuracy: 0.001)
        XCTAssertTrue(lateOutput.isEmpty)
        XCTAssertEqual(mixer.lateFrameCount, 2)
        XCTAssertEqual(try XCTUnwrap(flushed.first).startFrame, 4)
    }

    func testOverlappingBlocksReplaceOnlySameSourcePendingFrames() throws {
        var mixer = try makeMixer()
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [0.1, 0.1, 0.1, 0.1]))
        _ = try mixer.push(stereo(.system, startFrame: 2, samples: [0.5, 0.5, 0.5, 0.5]))

        let output = try mixer.push(stereo(.microphone, startFrame: 0, samples: [1, 1, 1, 1]))

        let block = try XCTUnwrap(output.first)
        XCTAssertEqual(block.left[0], 0.528, accuracy: 0.001)
        XCTAssertEqual(block.left[2], 0.72, accuracy: 0.001)
    }

    func testSoftLimiterKeepsSamplesWithinUnitRange() throws {
        var mixer = try makeMixer()
        _ = try mixer.push(stereo(.system, startFrame: 0, left: [10, 10, 10, 10], right: [-10, -10, -10, -10]))

        let output = try mixer.push(stereo(.microphone, startFrame: 0, left: [10, 10, 10, 10], right: [-10, -10, -10, -10]))
        let block = try XCTUnwrap(output.first)

        XCTAssertTrue(block.left.allSatisfy { (-1...1).contains($0) })
        XCTAssertTrue(block.right.allSatisfy { (-1...1).contains($0) })
    }

    func testFlushAdvancesAcrossMultipleBlocks() throws {
        var mixer = try makeMixer()

        let output = mixer.flushThrough(frame: 12)

        XCTAssertEqual(output.map(\.startFrame), [0, 4, 8])
        XCTAssertEqual(output.map(\.left.count), [4, 4, 4])
    }

    func testPendingStateIsBoundedWhenOneSourceRunsAhead() throws {
        var mixer = try makeMixer(maximumPendingFrames: 4)
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))
        _ = try mixer.push(stereo(.system, startFrame: 4, samples: [1, 1, 1, 1]))

        XCTAssertLessThanOrEqual(mixer.pendingFrameCount, 4)
    }

    func testBoundedPendingStateDoesNotDiscardFramesFromRunningAheadSource() throws {
        var mixer = try makeMixer(maximumPendingFrames: 4)
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))
        let forced = try mixer.push(stereo(.system, startFrame: 4, samples: [1, 1, 1, 1]))
        _ = try mixer.push(stereo(.microphone, startFrame: 0, samples: [0, 0, 0, 0]))
        let next = try mixer.push(stereo(.microphone, startFrame: 4, samples: [0, 0, 0, 0]))

        XCTAssertEqual(try XCTUnwrap(forced.first).startFrame, 0)
        XCTAssertEqual(try XCTUnwrap(next.first).left[0], 0.48, accuracy: 0.001)
    }

    func testApprovedLimiterKeepsNormalMixedSamplesLinear() throws {
        var mixer = try makeMixer()
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [0.5, 0.5, 0.5, 0.5]))

        let output = try mixer.push(stereo(.microphone, startFrame: 0, samples: [0.5, 0.5, 0.5, 0.5]))

        XCTAssertEqual(try XCTUnwrap(output.first).left[0], 0.48, accuracy: 0.001)
    }

    func testFirstLargeTimestampAnchorsTimelineWithoutSilenceRunaway() throws {
        let firstFrame: Int64 = 48_000 * 3_600
        var mixer = try makeMixer()
        let systemOutput = try mixer.push(stereo(.system, startFrame: firstFrame, samples: [1, 1, 1, 1]))
        let microphoneOutput = try mixer.push(stereo(.microphone, startFrame: firstFrame, samples: [0, 0, 0, 0]))
        let output = systemOutput + microphoneOutput

        XCTAssertLessThanOrEqual(output.count, 1)
        XCTAssertEqual(output.map(\.startFrame), [firstFrame])
        XCTAssertTrue(isStrictlyMonotonic(output.map(\.startFrame)))
    }

    func testLaterLargeTimestampGapSkipsUnobservedFramesWithoutSilenceRunaway() throws {
        let laterFrame: Int64 = 48_000 * 3_600
        var mixer = try makeMixer()
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))
        let initial = try mixer.push(stereo(.microphone, startFrame: 0, samples: [0, 0, 0, 0]))
        let systemOutput = try mixer.push(stereo(.system, startFrame: laterFrame, samples: [1, 1, 1, 1]))
        let microphoneOutput = try mixer.push(stereo(.microphone, startFrame: laterFrame, samples: [0, 0, 0, 0]))
        let output = systemOutput + microphoneOutput

        XCTAssertEqual(initial.map(\.startFrame), [0])
        XCTAssertLessThanOrEqual(output.count, 1)
        XCTAssertEqual(output.map(\.startFrame), [laterFrame])
        XCTAssertTrue(isStrictlyMonotonic(initial.map(\.startFrame) + output.map(\.startFrame)))
    }

    func testSparseFutureSourceReanchorsUnderPendingPressureAndSignalsDiscontinuity() throws {
        let futureFrame: Int64 = 48_000 * 3_600
        var mixer = try makeMixer(maximumPendingFrames: 4)
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))
        let initial = try mixer.push(stereo(.microphone, startFrame: 0, samples: [0, 0, 0, 0]))

        let output = try mixer.push(stereo(
            .system,
            startFrame: futureFrame,
            samples: [1, 1, 1, 1, 1, 1, 1, 1]
        ))

        XCTAssertEqual(initial.map(\.startFrame), [0])
        XCTAssertLessThanOrEqual(output.count, 1)
        XCTAssertEqual(output.map(\.startFrame), [futureFrame])
        XCTAssertTrue(isStrictlyMonotonic(initial.map(\.startFrame) + output.map(\.startFrame)))
        XCTAssertEqual(mixer.timelineDiscontinuityCount, 1)
        XCTAssertLessThanOrEqual(mixer.pendingFrameCount, 4)
    }

    func testDelayedMicrophoneBeforePressurePreservesCursorAndFutureSystemFrames() throws {
        var mixer = try makeMixer(maximumPendingFrames: 4)
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))
        _ = try mixer.push(stereo(.microphone, startFrame: 0, samples: [0, 0, 0, 0]))

        let earlySystemOutput = try mixer.push(stereo(
            .system,
            startFrame: 8,
            samples: [1, 1, 1, 1]
        ))
        let delayedMicrophoneOutput = try mixer.push(stereo(
            .microphone,
            startFrame: 4,
            samples: [1, 1, 1, 1]
        ))

        XCTAssertTrue(earlySystemOutput.isEmpty)
        XCTAssertEqual(delayedMicrophoneOutput.map(\.startFrame), [4])
        XCTAssertEqual(try XCTUnwrap(delayedMicrophoneOutput.first).left[0], 0.48, accuracy: 0.001)
        XCTAssertEqual(mixer.timelineDiscontinuityCount, 0)
        XCTAssertEqual(mixer.pendingFrameCount, 4)
    }

    func testRejectsUnsupportedSampleRate() {
        XCTAssertThrowsError(try TimestampedAudioMixer(sampleRate: 44_100, blockFrames: 4)) { error in
            XCTAssertEqual(error as? TimestampedAudioMixerError, .unsupportedSampleRate(44_100))
        }
    }

    func testDisconnectedSystemLetsMicrophoneContinueWithSystemSilence() throws {
        var mixer = try makeMixer()
        mixer.setSystemSourceConnected(false)

        let first = try mixer.push(stereo(.microphone, startFrame: 0, samples: [1, 1, 1, 1]))
        let second = try mixer.push(stereo(.microphone, startFrame: 4, samples: [1, 1, 1, 1]))
        let output = first + second

        XCTAssertEqual(output.map(\.startFrame), [0, 4])
        XCTAssertEqual(output.map(\.left.first), [0.48, 0.48])
    }

    func testSystemDisconnectDropsAlreadyPendingSystemSamples() throws {
        var mixer = try makeMixer()
        _ = try mixer.push(stereo(.system, startFrame: 0, samples: [1, 1, 1, 1]))
        _ = try mixer.push(stereo(.microphone, startFrame: 0, samples: [0, 0, 0, 0]))
        _ = try mixer.push(stereo(.system, startFrame: 4, samples: [1, 1, 1, 1]))

        mixer.setSystemSourceConnected(false)
        let output = try mixer.push(stereo(.microphone, startFrame: 4, samples: [1, 1, 1, 1]))

        XCTAssertEqual(try XCTUnwrap(output.first).startFrame, 4)
        XCTAssertEqual(try XCTUnwrap(output.first).left[0], 0.48, accuracy: 0.001)
    }

    func testSystemReconnectWaitsForNewSystemFramesThenMixesAgain() throws {
        var mixer = try makeMixer()
        mixer.setSystemSourceConnected(false)
        _ = try mixer.push(stereo(.microphone, startFrame: 0, samples: [1, 1, 1, 1]))

        mixer.setSystemSourceConnected(true)
        let waiting = try mixer.push(stereo(.microphone, startFrame: 4, samples: [1, 1, 1, 1]))
        let output = try mixer.push(stereo(.system, startFrame: 4, samples: [0.5, 0.5, 0.5, 0.5]))

        XCTAssertTrue(waiting.isEmpty)
        XCTAssertEqual(try XCTUnwrap(output.first).startFrame, 4)
        XCTAssertEqual(try XCTUnwrap(output.first).left[0], 0.72, accuracy: 0.001)
    }

    func testRejectsMismatchedChannelLengths() {
        XCTAssertThrowsError(try AudioFrameBlock.stereo(
            source: .system,
            startFrame: 0,
            left: [1, 1, 1, 1],
            right: [1, 1, 1]
        )) { error in
            XCTAssertEqual(
                error as? AudioFrameBlockError,
                .mismatchedChannelFrameCounts(left: 4, right: 3)
            )
        }
    }

    private func makeMixer(maximumPendingFrames: Int? = nil) throws -> TimestampedAudioMixer {
        try TimestampedAudioMixer(
            sampleRate: 48_000,
            blockFrames: 4,
            maximumPendingFrames: maximumPendingFrames
        )
    }

    private func stereo(
        _ source: AudioSourceKind,
        startFrame: Int64,
        samples: [Float]
    ) throws -> AudioFrameBlock {
        try stereo(source, startFrame: startFrame, left: samples, right: samples)
    }

    private func stereo(
        _ source: AudioSourceKind,
        startFrame: Int64,
        left: [Float],
        right: [Float]
    ) throws -> AudioFrameBlock {
        try AudioFrameBlock.stereo(
            source: source,
            startFrame: startFrame,
            left: left,
            right: right
        )
    }

    private func isStrictlyMonotonic(_ frames: [Int64]) -> Bool {
        zip(frames, frames.dropFirst()).allSatisfy { $0 < $1 }
    }
}
