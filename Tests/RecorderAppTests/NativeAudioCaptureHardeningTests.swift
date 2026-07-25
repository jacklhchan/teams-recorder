import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest
@testable import RecorderApp

final class NativeAudioCaptureHardeningTests: XCTestCase {
    func testStoppingSessionRejectsReplacementUntilCleanupFinishes() throws {
        var lifecycle = CaptureLifecycleCoordinator()
        let streamA = NSObject()
        let tokenA = CaptureSessionToken(
            generation: 1,
            streamIdentity: ObjectIdentifier(streamA)
        )
        let reservationA = try lifecycle.reserveStart()

        XCTAssertTrue(lifecycle.activate(reservation: reservationA, token: tokenA))
        XCTAssertEqual(lifecycle.beginStop(expected: tokenA), tokenA)
        XCTAssertThrowsError(try lifecycle.reserveStart()) { error in
            XCTAssertEqual(error as? CaptureSourceError, .streamAlreadyRunning)
        }

        lifecycle.finishStop(tokenA)

        let reservationB = try lifecycle.reserveStart()
        XCTAssertNotEqual(reservationA, reservationB)
    }

    func testReplacementWaitsForInFlightCallbackDrain() throws {
        var lifecycle = CaptureLifecycleCoordinator()
        let gate = CaptureSessionGate()
        let streamA = NSObject()
        let tokenA = gate.activate(streamIdentity: ObjectIdentifier(streamA))
        let reservationA = try lifecycle.reserveStart()
        XCTAssertTrue(lifecycle.activate(reservation: reservationA, token: tokenA))

        let delivery = SerialCaptureDelivery(
            token: tokenA,
            gate: gate,
            label: "test.lifecycle.drain"
        )
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        delivery.enqueue(streamIdentity: ObjectIdentifier(streamA)) {
            callbackStarted.signal()
            _ = releaseCallback.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(lifecycle.beginStop(expected: tokenA), tokenA)
        gate.deactivate(tokenA)
        XCTAssertThrowsError(try lifecycle.reserveStart()) { error in
            XCTAssertEqual(error as? CaptureSourceError, .streamAlreadyRunning)
        }

        releaseCallback.signal()
        delivery.drain()
        lifecycle.finishStop(tokenA)
        _ = try lifecycle.reserveStart()
    }

    func testSuspendedStartContinuationCannotStopReplacementSession() throws {
        var lifecycle = CaptureLifecycleCoordinator()
        let streamA = NSObject()
        let streamB = NSObject()
        let tokenA = CaptureSessionToken(
            generation: 1,
            streamIdentity: ObjectIdentifier(streamA)
        )
        let tokenB = CaptureSessionToken(
            generation: 2,
            streamIdentity: ObjectIdentifier(streamB)
        )
        let reservationA = try lifecycle.reserveStart()
        XCTAssertTrue(lifecycle.activate(reservation: reservationA, token: tokenA))

        XCTAssertEqual(lifecycle.beginStop(expected: tokenA), tokenA)
        lifecycle.finishStop(tokenA)
        let reservationB = try lifecycle.reserveStart()
        XCTAssertTrue(lifecycle.activate(reservation: reservationB, token: tokenB))

        XCTAssertNil(lifecycle.beginStop(expected: tokenA))
        XCTAssertTrue(lifecycle.isActive(tokenB))
    }

    func testCancelledStartingReservationCannotReplaceNewActiveSession() throws {
        var lifecycle = CaptureLifecycleCoordinator()
        let streamA = NSObject()
        let streamB = NSObject()
        let tokenA = CaptureSessionToken(
            generation: 1,
            streamIdentity: ObjectIdentifier(streamA)
        )
        let tokenB = CaptureSessionToken(
            generation: 2,
            streamIdentity: ObjectIdentifier(streamB)
        )
        let reservationA = try lifecycle.reserveStart()
        lifecycle.cancelStart(reservationA)

        let reservationB = try lifecycle.reserveStart()
        XCTAssertTrue(lifecycle.activate(reservation: reservationB, token: tokenB))
        XCTAssertFalse(lifecycle.activate(reservation: reservationA, token: tokenA))
        XCTAssertTrue(lifecycle.isActive(tokenB))
    }

    func testCancelledStartBlocksReplacementUntilItsCleanupFinishes() throws {
        var lifecycle = CaptureLifecycleCoordinator()
        let reservationA = try lifecycle.reserveStart()

        lifecycle.cancelCurrentStart()

        XCTAssertThrowsError(try lifecycle.reserveStart()) { error in
            XCTAssertEqual(error as? CaptureSourceError, .streamAlreadyRunning)
        }

        lifecycle.cancelStart(reservationA)
        _ = try lifecycle.reserveStart()
    }

    func testSelectedApplicationDisconnectIsLatchedPerSession() {
        var events = CaptureSessionEventState()

        XCTAssertTrue(events.markSelectedApplicationDisconnected())
        XCTAssertFalse(events.markSelectedApplicationDisconnected())
    }

    func testSuccessfulFilterUpdateMayResetSelectedApplicationDisconnectLatch() {
        var events = CaptureSessionEventState()
        XCTAssertTrue(events.markSelectedApplicationDisconnected())

        events.clearSelectedApplicationDisconnect()

        XCTAssertTrue(events.markSelectedApplicationDisconnected())
    }

    func testSelectedApplicationFilterKeepsOnlyTargetAndRecorderProcesses() throws {
        let selected = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let recorder = CaptureApplication(
            processID: 7,
            bundleIdentifier: "com.example.recorder",
            name: "Local Meeting Recorder"
        )
        let unrelated = CaptureApplication(
            processID: 88,
            bundleIdentifier: "com.apple.Music",
            name: "Music"
        )

        XCTAssertEqual(
            try SelectedApplicationFilterPlan.includedProcessIDs(
                selected: selected,
                applications: [selected, recorder, unrelated],
                recorderProcessID: recorder.processID
            ),
            [selected.processID, recorder.processID]
        )
    }

    func testStaleLivenessSnapshotCannotDisconnectSuccessfulReconnect() throws {
        let original = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        var state = SelectedApplicationSessionState(application: original)
        let staleSnapshot = try XCTUnwrap(state.livenessSnapshot)
        XCTAssertNotNil(state.markDisconnected(for: staleSnapshot))
        let update = try XCTUnwrap(state.beginReconnect(to: restarted))

        XCTAssertTrue(state.completeReconnect(update))
        XCTAssertNil(state.markDisconnected(for: staleSnapshot))
        XCTAssertEqual(state.application, restarted)
        XCTAssertFalse(state.isDisconnected)
    }

    func testFailedReconnectKeepsDisconnectLatchAndOriginalTarget() throws {
        let original = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        var state = SelectedApplicationSessionState(application: original)
        let snapshot = try XCTUnwrap(state.livenessSnapshot)
        XCTAssertNotNil(state.markDisconnected(for: snapshot))
        let update = try XCTUnwrap(state.beginReconnect(to: restarted))

        state.failReconnect(update)

        XCTAssertEqual(state.application, original)
        XCTAssertTrue(state.isDisconnected)
    }

    func testSelectedApplicationContextDelegateStopIsTerminal() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedNoMatchingApplicationContext.rawValue
        )

        XCTAssertEqual(
            CaptureStreamStopClassifier.event(for: error),
            .streamFailed
        )
    }

    func testStaleMicrophoneHealthEventCannotReachReplacementSession() {
        let gate = CaptureSessionGate()
        let streamA = NSObject()
        let streamB = NSObject()
        let tokenA = gate.activate(streamIdentity: ObjectIdentifier(streamA))
        let deliveryA = SerialCaptureDelivery(
            token: tokenA,
            gate: gate,
            label: "test.stale.health"
        )
        let state = LockedDeliveryState()
        var eventState = CaptureSessionEventState()
        let audioTime = Date(timeIntervalSince1970: 10)
        eventState.recordMicrophoneAudio(at: audioTime)
        let pendingEvent = eventState.microphoneHealthEvent(
            now: audioTime.addingTimeInterval(3),
            silenceThreshold: 2,
            isDeviceAvailable: true
        )

        gate.deactivate(tokenA)
        let tokenB = gate.activate(streamIdentity: ObjectIdentifier(streamB))
        deliveryA.enqueue(streamIdentity: ObjectIdentifier(streamA)) {
            if pendingEvent == .microphoneSilence {
                state.completeOnly()
            }
        }
        deliveryA.drain()

        XCTAssertEqual(state.completed, 0)
        XCTAssertTrue(gate.accepts(tokenB, streamIdentity: ObjectIdentifier(streamB)))
    }

    func testOldGenerationIsRejectedAfterNewStreamActivation() {
        let gate = CaptureSessionGate()
        let streamA = NSObject()
        let streamB = NSObject()
        let tokenA = gate.activate(streamIdentity: ObjectIdentifier(streamA))

        gate.deactivate(tokenA)
        let tokenB = gate.activate(streamIdentity: ObjectIdentifier(streamB))

        XCTAssertFalse(gate.accepts(tokenA, streamIdentity: ObjectIdentifier(streamA)))
        XCTAssertFalse(gate.accepts(tokenA, streamIdentity: ObjectIdentifier(streamB)))
        XCTAssertTrue(gate.accepts(tokenB, streamIdentity: ObjectIdentifier(streamB)))
    }

    func testSessionDeliveryIsSerializedAcrossConcurrentProducers() {
        let gate = CaptureSessionGate()
        let stream = NSObject()
        let token = gate.activate(streamIdentity: ObjectIdentifier(stream))
        let delivery = SerialCaptureDelivery(token: token, gate: gate, label: "test.serial.delivery")
        let state = LockedDeliveryState()

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            delivery.enqueue(streamIdentity: ObjectIdentifier(stream)) {
                state.begin()
                Thread.sleep(forTimeInterval: 0.001)
                state.end()
            }
        }
        delivery.drain()

        XCTAssertEqual(state.completed, 20)
        XCTAssertEqual(state.maximumConcurrent, 1)
    }

    func testQueuedWorkIsDroppedAfterSessionDeactivation() {
        let gate = CaptureSessionGate()
        let stream = NSObject()
        let token = gate.activate(streamIdentity: ObjectIdentifier(stream))
        let delivery = SerialCaptureDelivery(token: token, gate: gate, label: "test.queued.drop")
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let state = LockedDeliveryState()

        delivery.enqueue(streamIdentity: ObjectIdentifier(stream)) {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 2)
            if delivery.isActive(streamIdentity: ObjectIdentifier(stream)) {
                state.completeOnly()
            }
        }
        delivery.enqueue(streamIdentity: ObjectIdentifier(stream)) {
            state.completeOnly()
        }

        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)
        gate.deactivate(token)
        releaseFirst.signal()
        delivery.drain()

        XCTAssertEqual(state.completed, 0)
    }

    func testFortyFourPointOneKOneFrameBuffersRemainContinuous() throws {
        let resampler = PersistentAudioResampler(source: .microphone)
        var previousEnd: Int64?
        var totalFrames = 0

        for inputFrame in 0..<100 {
            let packet = OwnedAudioPacket(
                pcm: OwnedPCMBuffer(sampleRate: 44_100, channels: [[Float(inputFrame) / 100]]),
                presentationTime: CMTime(value: CMTimeValue(inputFrame), timescale: 44_100)
            )
            guard let block = try resampler.process(packet) else { continue }
            if let previousEnd {
                XCTAssertEqual(block.startFrame, previousEnd)
            }
            previousEnd = block.startFrame + Int64(block.frameCount)
            totalFrames += block.frameCount
        }

        let timestampDuration = SampleBufferConverter.startFrame(
            for: CMTime(value: 100, timescale: 44_100)
        )
        XCTAssertLessThanOrEqual(abs(Int64(totalFrames) - timestampDuration), 1)
    }

    func testFortyFourPointOneKChunksHaveNoGapOrOverlap() throws {
        let resampler = PersistentAudioResampler(source: .microphone)
        var previousEnd: Int64?
        var totalFrames = 0

        for chunkIndex in 0..<10 {
            let start = chunkIndex * 1_024
            let samples = (0..<1_024).map { Float(start + $0) / 10_240 }
            let packet = OwnedAudioPacket(
                pcm: OwnedPCMBuffer(sampleRate: 44_100, channels: [samples]),
                presentationTime: CMTime(value: CMTimeValue(start), timescale: 44_100)
            )
            guard let block = try resampler.process(packet) else { continue }
            if let previousEnd {
                XCTAssertEqual(block.startFrame, previousEnd)
            }
            previousEnd = block.startFrame + Int64(block.frameCount)
            totalFrames += block.frameCount
        }

        let timestampDuration = SampleBufferConverter.startFrame(
            for: CMTime(value: 10_240, timescale: 44_100)
        )
        XCTAssertLessThanOrEqual(abs(Int64(totalFrames) - timestampDuration), 1)
    }

    func testFortyFourPointOneKChunkedAndSingleToneShareOutputPrefix() throws {
        let sampleRate = 44_100.0
        let sampleCount = 4_410
        let samples = (0..<sampleCount).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate) * 0.5)
        }
        let singleResampler = PersistentAudioResampler(source: .microphone)
        let single = try XCTUnwrap(singleResampler.process(OwnedAudioPacket(
            pcm: OwnedPCMBuffer(sampleRate: sampleRate, channels: [samples]),
            presentationTime: .zero
        )))

        let chunkedResampler = PersistentAudioResampler(source: .microphone)
        var chunkedSamples: [Float] = []
        var previousEnd: Int64?
        for start in stride(from: 0, to: sampleCount, by: 441) {
            let end = min(start + 441, sampleCount)
            let block = try XCTUnwrap(chunkedResampler.process(OwnedAudioPacket(
                pcm: OwnedPCMBuffer(
                    sampleRate: sampleRate,
                    channels: [Array(samples[start..<end])]
                ),
                presentationTime: CMTime(
                    value: CMTimeValue(start),
                    timescale: CMTimeScale(sampleRate)
                )
            )))
            if let previousEnd {
                XCTAssertEqual(block.startFrame, previousEnd)
            }
            previousEnd = block.startFrame + Int64(block.frameCount)
            chunkedSamples.append(contentsOf: block.left)
        }

        let commonCount = min(single.left.count, chunkedSamples.count)
        // AVAudioConverter retains an unflushed, chunk-size-dependent tail.
        // The emitted common prefix must still be independent of chunking.
        XCTAssertGreaterThan(commonCount, 4_000)
        for index in 0..<commonCount {
            XCTAssertEqual(single.left[index], chunkedSamples[index], accuracy: 0.000_1)
        }
    }

    func testForwardPTSDiscontinuityReanchorsOutputCursor() throws {
        let resampler = PersistentAudioResampler(source: .system)
        let first = try XCTUnwrap(resampler.process(OwnedAudioPacket(
            pcm: OwnedPCMBuffer(sampleRate: 48_000, channels: [[0, 0, 0, 0]]),
            presentationTime: .zero
        )))
        let second = try XCTUnwrap(resampler.process(OwnedAudioPacket(
            pcm: OwnedPCMBuffer(sampleRate: 48_000, channels: [[1, 1]]),
            presentationTime: CMTime(value: 48_000, timescale: 48_000)
        )))

        XCTAssertEqual(first.startFrame, 0)
        XCTAssertEqual(second.startFrame, 48_000)
    }

    func testBackwardPTSDiscontinuityReanchorsOutputCursor() throws {
        let resampler = PersistentAudioResampler(source: .system)
        _ = try XCTUnwrap(resampler.process(OwnedAudioPacket(
            pcm: OwnedPCMBuffer(sampleRate: 48_000, channels: [[0, 0, 0, 0]]),
            presentationTime: CMTime(value: 48_000, timescale: 48_000)
        )))
        let rewound = try XCTUnwrap(resampler.process(OwnedAudioPacket(
            pcm: OwnedPCMBuffer(sampleRate: 48_000, channels: [[1, 1]]),
            presentationTime: CMTime(value: 24_000, timescale: 48_000)
        )))

        XCTAssertEqual(rewound.startFrame, 24_000)
    }

    func testFortyEightKFastPathPreservesSamplesAndFrameCount() throws {
        let resampler = PersistentAudioResampler(source: .system)
        let packet = OwnedAudioPacket(
            pcm: OwnedPCMBuffer(
                sampleRate: 48_000,
                channels: [[-1, -0.25, 0, 0.75], [1, 0.25, 0, -0.75]]
            ),
            presentationTime: CMTime(value: 48_000, timescale: 48_000)
        )

        let block = try XCTUnwrap(resampler.process(packet))

        XCTAssertEqual(block.startFrame, 48_000)
        XCTAssertEqual(block.left, packet.pcm.channels[0])
        XCTAssertEqual(block.right, packet.pcm.channels[1])
    }

    func testCopyDecodesSyntheticInterleavedInt16SampleBuffer() throws {
        let presentationTime = CMTime(value: 96_000, timescale: 48_000)
        let sampleBuffer = try makeInterleavedInt16SampleBuffer(
            samples: [
                -32_768, 32_767,
                16_384, -16_384,
                0, 8_192
            ],
            channelCount: 2,
            sampleRate: 48_000,
            presentationTime: presentationTime
        )

        let packet = try SampleBufferConverter.copy(sampleBuffer)

        XCTAssertEqual(packet.presentationTime, presentationTime)
        XCTAssertEqual(packet.pcm.sampleRate, 48_000)
        XCTAssertEqual(packet.pcm.channels.count, 2)
        XCTAssertEqual(packet.pcm.channels[0].count, 3)
        XCTAssertEqual(packet.pcm.channels[0][0], -1, accuracy: 0.000_001)
        XCTAssertEqual(packet.pcm.channels[0][1], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(packet.pcm.channels[0][2], 0, accuracy: 0.000_001)
        XCTAssertEqual(
            packet.pcm.channels[1][0],
            Float(32_767.0 / 32_768.0),
            accuracy: 0.000_001
        )
        XCTAssertEqual(packet.pcm.channels[1][1], -0.5, accuracy: 0.000_001)
        XCTAssertEqual(packet.pcm.channels[1][2], 0.25, accuracy: 0.000_001)
    }

    func testAlignedHighTwentyFourInThirtyTwoIsRejected() {
        let format = makePCMFormat(
            sampleRate: 48_000,
            channels: 1,
            bitsPerChannel: 24,
            bytesPerFrame: 4,
            flags: UInt32(kAudioFormatFlagIsSignedInteger |
                kAudioFormatFlagIsPacked |
                kAudioFormatFlagIsAlignedHigh)
        )

        XCTAssertThrowsError(try PCMLayoutValidator.validate(format)) { error in
            XCTAssertEqual(error as? SampleBufferConverterError, .unsupportedAlignedHighPCM)
        }
    }

    func testTwentyFourBitPCMInThirtyTwoBitContainerIsRejected() {
        let format = makePCMFormat(
            sampleRate: 48_000,
            channels: 1,
            bitsPerChannel: 24,
            bytesPerFrame: 4,
            flags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        )

        XCTAssertThrowsError(try PCMLayoutValidator.validate(format)) { error in
            XCTAssertEqual(error as? SampleBufferConverterError, .invalidPCMFrameStride)
        }
    }

    func testPacketAndFrameLayoutMustDescribeOnePackedPCMFrame() {
        var multipleFramesPerPacket = makePCMFormat(
            sampleRate: 48_000,
            channels: 1,
            bitsPerChannel: 16,
            bytesPerFrame: 2,
            flags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        )
        multipleFramesPerPacket.mFramesPerPacket = 2
        multipleFramesPerPacket.mBytesPerPacket = 4

        XCTAssertThrowsError(try PCMLayoutValidator.validate(multipleFramesPerPacket)) { error in
            XCTAssertEqual(error as? SampleBufferConverterError, .unsupportedPCMLayout)
        }

        var paddedPacket = makePCMFormat(
            sampleRate: 48_000,
            channels: 1,
            bitsPerChannel: 16,
            bytesPerFrame: 2,
            flags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        )
        paddedPacket.mBytesPerPacket = 4

        XCTAssertThrowsError(try PCMLayoutValidator.validate(paddedPacket)) { error in
            XCTAssertEqual(error as? SampleBufferConverterError, .unsupportedPCMLayout)
        }
    }

    func testBigEndianPackedPCMIsRejected() {
        let format = makePCMFormat(
            sampleRate: 48_000,
            channels: 1,
            bitsPerChannel: 16,
            bytesPerFrame: 2,
            flags: UInt32(
                kAudioFormatFlagIsSignedInteger |
                    kAudioFormatFlagIsPacked |
                    kAudioFormatFlagIsBigEndian
            )
        )

        XCTAssertThrowsError(try PCMLayoutValidator.validate(format)) { error in
            XCTAssertEqual(error as? SampleBufferConverterError, .unsupportedByteOrder)
        }
    }

    func testSupportedPackedLittleEndianLayoutsAreAccepted() throws {
        let floatLayout = try PCMLayoutValidator.validate(makePCMFormat(
            sampleRate: 48_000,
            channels: 2,
            bitsPerChannel: 32,
            bytesPerFrame: 8,
            flags: UInt32(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        ))
        let int16Layout = try PCMLayoutValidator.validate(makePCMFormat(
            sampleRate: 48_000,
            channels: 1,
            bitsPerChannel: 16,
            bytesPerFrame: 2,
            flags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        ))
        let int24Layout = try PCMLayoutValidator.validate(makePCMFormat(
            sampleRate: 48_000,
            channels: 1,
            bitsPerChannel: 24,
            bytesPerFrame: 3,
            flags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        ))
        let int32PlanarLayout = try PCMLayoutValidator.validate(makePCMFormat(
            sampleRate: 48_000,
            channels: 2,
            bitsPerChannel: 32,
            bytesPerFrame: 4,
            flags: UInt32(kAudioFormatFlagIsSignedInteger |
                kAudioFormatFlagIsPacked |
                kAudioFormatFlagIsNonInterleaved)
        ))

        XCTAssertEqual(floatLayout.encoding, .float32)
        XCTAssertEqual(int16Layout.encoding, .signedInt16)
        XCTAssertEqual(int24Layout.encoding, .signedInt24Packed)
        XCTAssertEqual(int32PlanarLayout.encoding, .signedInt32)
        XCTAssertFalse(int32PlanarLayout.isInterleaved)
    }

    func testMoreThanTwoChannelsAreRejected() {
        let format = makePCMFormat(
            sampleRate: 48_000,
            channels: 3,
            bitsPerChannel: 32,
            bytesPerFrame: 12,
            flags: UInt32(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        )

        XCTAssertThrowsError(try PCMLayoutValidator.validate(format)) { error in
            XCTAssertEqual(error as? SampleBufferConverterError, .unsupportedChannelCount(3))
        }
    }

    func testInterleavedFrameStrideMustExactlyFitChannels() {
        let format = makePCMFormat(
            sampleRate: 48_000,
            channels: 2,
            bitsPerChannel: 16,
            bytesPerFrame: 2,
            flags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        )

        XCTAssertThrowsError(try PCMLayoutValidator.validate(format)) { error in
            XCTAssertEqual(error as? SampleBufferConverterError, .invalidPCMFrameStride)
        }
    }

    func testSignedPCMMinimaNormalizeToNegativeOne() throws {
        XCTAssertEqual(
            try PCMByteDecoder.decode([0x00, 0x80], encoding: .signedInt16),
            -1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try PCMByteDecoder.decode([0x00, 0x00, 0x80], encoding: .signedInt24Packed),
            -1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try PCMByteDecoder.decode([0x00, 0x00, 0x00, 0x80], encoding: .signedInt32),
            -1,
            accuracy: 0.000_001
        )
        XCTAssertLessThanOrEqual(
            try PCMByteDecoder.decode([0xFF, 0x7F], encoding: .signedInt16),
            1
        )
        XCTAssertEqual(
            try PCMByteDecoder.decode([0x00, 0x00, 0x00], encoding: .signedInt24Packed),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try PCMByteDecoder.decode([0xFF, 0xFF, 0x7F], encoding: .signedInt24Packed),
            Float(8_388_607.0 / 8_388_608.0),
            accuracy: 0.000_001
        )
    }

    func testTypedStreamErrorMapping() {
        XCTAssertEqual(
            CaptureErrorMapper.event(for: scError(.userDeclined)),
            .screenRecordingPermissionDenied
        )
        XCTAssertEqual(
            CaptureErrorMapper.event(for: scError(.failedToStartAudioCapture)),
            .systemAudioCaptureFailed
        )
        XCTAssertEqual(
            CaptureErrorMapper.event(for: scError(.failedToStartMicrophoneCapture)),
            .microphoneCaptureFailed
        )
        XCTAssertEqual(
            CaptureErrorMapper.event(for: scError(.failedNoMatchingApplicationContext)),
            .selectedApplicationRequiresReconnect
        )
        XCTAssertEqual(
            CaptureErrorMapper.event(for: scError(.userStopped)),
            .streamStoppedByUser
        )
        XCTAssertEqual(
            CaptureErrorMapper.event(for: scError(.systemStoppedStream)),
            .streamStoppedBySystem
        )
        XCTAssertEqual(
            CaptureErrorMapper.event(for: scError(.missingEntitlements)),
            .missingCaptureEntitlements
        )
        XCTAssertEqual(
            CaptureErrorMapper.event(for: NSError(domain: "test", code: 7)),
            .streamFailed
        )
    }

    func testTypedPermissionStatusMapping() {
        XCTAssertEqual(
            CapturePermissionPreflight.error(
                screenCaptureAllowed: false,
                microphoneAuthorization: .authorized
            ),
            .screenRecordingPermissionDenied
        )
        XCTAssertEqual(
            CapturePermissionPreflight.error(
                screenCaptureAllowed: true,
                microphoneAuthorization: .denied
            ),
            .microphonePermissionDenied
        )
        XCTAssertEqual(
            CapturePermissionPreflight.error(
                screenCaptureAllowed: true,
                microphoneAuthorization: .restricted
            ),
            .microphonePermissionDenied
        )
        XCTAssertEqual(
            CapturePermissionPreflight.error(
                screenCaptureAllowed: true,
                microphoneAuthorization: .notDetermined
            ),
            .microphonePermissionDenied
        )
        XCTAssertNil(
            CapturePermissionPreflight.error(
                screenCaptureAllowed: true,
                microphoneAuthorization: .authorized
            )
        )
    }

    func testTypedEventsHaveDistinctUserFacingStatuses() {
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .screenRecordingPermissionDenied),
            .error("Screen & System Audio Recording permission denied")
        )
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .microphonePermissionDenied),
            .error("Microphone permission denied")
        )
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .microphoneUnavailable),
            .error("Microphone unavailable")
        )
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .systemAudioCaptureFailed),
            .error("System audio capture failed")
        )
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .microphoneCaptureFailed),
            .error("Microphone capture failed")
        )
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .streamFailed),
            .error("Audio capture failed")
        )
    }

    private func scError(_ code: SCStreamError.Code) -> NSError {
        NSError(domain: SCStreamErrorDomain, code: code.rawValue)
    }

    private func makePCMFormat(
        sampleRate: Double,
        channels: UInt32,
        bitsPerChannel: UInt32,
        bytesPerFrame: UInt32,
        flags: UInt32
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
    }

    private func makeInterleavedInt16SampleBuffer(
        samples: [Int16],
        channelCount: UInt32,
        sampleRate: Double,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        XCTAssertEqual(samples.count % Int(channelCount), 0)
        var format = makePCMFormat(
            sampleRate: sampleRate,
            channels: channelCount,
            bitsPerChannel: 16,
            bytesPerFrame: channelCount * 2,
            flags: UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &format,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw SyntheticSampleBufferError.creationFailed(formatStatus)
        }

        let bytes = samples.flatMap { sample -> [UInt8] in
            let littleEndian = UInt16(bitPattern: sample).littleEndian
            return [
                UInt8(truncatingIfNeeded: littleEndian),
                UInt8(truncatingIfNeeded: littleEndian >> 8)
            ]
        }
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw SyntheticSampleBufferError.creationFailed(blockStatus)
        }
        let replaceStatus = bytes.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw SyntheticSampleBufferError.creationFailed(replaceStatus)
        }

        let frameCount = samples.count / Int(channelCount)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(format.mBytesPerFrame)
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw SyntheticSampleBufferError.creationFailed(sampleStatus)
        }
        return sampleBuffer
    }
}

private enum SyntheticSampleBufferError: Error {
    case creationFailed(OSStatus)
}

private final class LockedDeliveryState {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var completed = 0

    func begin() {
        lock.lock()
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        completed += 1
        lock.unlock()
    }

    func completeOnly() {
        lock.lock()
        completed += 1
        lock.unlock()
    }
}
