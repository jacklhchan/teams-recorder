import AVFoundation
import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import RecorderApp

final class NativeAudioCaptureHardeningTests: XCTestCase {
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
