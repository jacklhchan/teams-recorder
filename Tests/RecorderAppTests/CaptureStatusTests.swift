import CoreMedia
import XCTest
@testable import RecorderApp

final class CaptureStatusTests: XCTestCase {
    func testDisconnectedCaptureMapsToWarning() {
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .applicationDisconnected("Teams")),
            .warning("App audio disconnected")
        )
    }

    func testAudioDeviceCarriesStableUID() {
        let device = AudioDevice(
            id: 1,
            uid: "BuiltInMicrophoneDevice",
            name: "MacBook Microphone",
            manufacturer: "Apple",
            channelCount: 1
        )

        XCTAssertEqual(device.uid, "BuiltInMicrophoneDevice")
    }

    func testPTSConvertsToFortyEightKStartFrameUsingRoundTowardZero() {
        let pts = CMTime(value: 1_001, timescale: 1_000)

        XCTAssertEqual(SampleBufferConverter.startFrame(for: pts), 48_048)
    }

    func testNonInterleavedMonoPCMNormalizesToStereoAtFortyEightK() throws {
        let pcm = OwnedPCMBuffer(sampleRate: 48_000, channels: [[0.25, -0.5]])

        let block = try SampleBufferConverter.normalize(
            pcm,
            source: .microphone,
            presentationTime: CMTime(value: 2, timescale: 1)
        )

        XCTAssertEqual(block.startFrame, 96_000)
        XCTAssertEqual(block.left, [0.25, -0.5])
        XCTAssertEqual(block.right, [0.25, -0.5])
    }

    func testLateBufferFromStoppedGenerationIsDiscarded() {
        let gate = CaptureCallbackGate()
        let generation = gate.activate()

        XCTAssertTrue(gate.accepts(generation))
        gate.deactivate()

        XCTAssertFalse(gate.accepts(generation))
    }

    func testSelectedAppResolutionRequiresCurrentPID() {
        let selected = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: selected.bundleIdentifier,
            name: selected.name
        )

        XCTAssertNil(
            CaptureProcessResolver.currentApplication(
                for: .application(selected),
                availableApplications: [restarted]
            )
        )
    }

    func testMicrophoneUIDResolverRequiresExactAVFoundationMatch() throws {
        XCTAssertEqual(
            try MicrophoneDeviceResolver.resolve(
                coreAudioUID: "AirPods-UID",
                availableCaptureDeviceUIDs: ["BuiltIn-UID", "AirPods-UID"]
            ),
            "AirPods-UID"
        )
        XCTAssertThrowsError(
            try MicrophoneDeviceResolver.resolve(
                coreAudioUID: "AirPods-UID",
                availableCaptureDeviceUIDs: ["BuiltIn-UID"]
            )
        )
    }

    func testSystemDefaultMicrophoneMayRemainNilButEmptyUIDFails() throws {
        XCTAssertNil(try MicrophoneDeviceResolver.resolveCurrentCaptureDeviceUID(coreAudioUID: nil))
        XCTAssertThrowsError(
            try MicrophoneDeviceResolver.resolveCurrentCaptureDeviceUID(coreAudioUID: "")
        )
    }
}
