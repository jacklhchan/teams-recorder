import CoreMedia
import XCTest
@testable import RecorderApp

final class CaptureStatusTests: XCTestCase {
    func testDeniedSystemAudioPermissionBlocksStart() {
        let state = CaptureReadiness.evaluate(
            permission: .denied,
            selection: .init(mode: .allSystemAudio),
            resolvedSelection: .allSystemAudio,
            microphoneAvailable: true
        )

        XCTAssertEqual(
            state,
            .blocked("Screen & System Audio Recording permission is required.")
        )
    }

    func testDisconnectedSelectedAppShowsReconnectWithoutChangingMode() {
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.microsoft.teams2"
        )
        let state = CaptureReadiness.evaluate(
            permission: .granted,
            selection: selection,
            resolvedSelection: .disconnected("com.microsoft.teams2"),
            microphoneAvailable: true
        )

        XCTAssertEqual(state, .reconnectRequired)
        XCTAssertEqual(selection.mode, .selectedApplication)
        XCTAssertEqual(selection.selectedBundleIdentifier, "com.microsoft.teams2")
    }

    func testSelectedAppWithoutBundleIDIsBlockedInsteadOfCapturingAllAudio() {
        XCTAssertEqual(
            CaptureReadiness.evaluate(
                permission: .granted,
                selection: .init(mode: .selectedApplication),
                resolvedSelection: .disconnected(""),
                microphoneAvailable: true
            ),
            .blocked("Choose an application to capture.")
        )
    }

    func testMissingMicrophoneBlocksStart() {
        XCTAssertEqual(
            CaptureReadiness.evaluate(
                permission: .granted,
                selection: .init(mode: .allSystemAudio),
                resolvedSelection: .allSystemAudio,
                microphoneAvailable: false
            ),
            .blocked("Microphone permission and an available microphone are required.")
        )
    }

    func testPermissionAndDisconnectedStatesExposeActions() {
        XCTAssertEqual(
            CaptureStatusRowMapper.row(for: .denied),
            .init(
                title: "Screen & System Audio Recording",
                message: "Permission denied. Open System Settings, then retry.",
                action: .openSettings
            )
        )
        XCTAssertEqual(
            CaptureStatusRowMapper.row(for: .reconnectRequired),
            .init(
                title: "System Audio",
                message: "App audio disconnected",
                action: .reconnect
            )
        )
    }

    func testCaptureSelectionPersistenceRoundTripUsesOnlyApprovedKeys() {
        let defaults = UserDefaults(suiteName: "CaptureStatusTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let persistence = CaptureSelectionPersistence(defaults: defaults)
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.microsoft.teams2"
        )

        persistence.save(selection: selection, microphoneUID: "BuiltInMicrophoneDevice")

        XCTAssertEqual(persistence.loadSelection(), selection)
        XCTAssertEqual(persistence.loadMicrophoneUID(), "BuiltInMicrophoneDevice")
        XCTAssertEqual(
            Set(defaults.dictionaryRepresentation().keys).intersection(CaptureSelectionPersistence.keys),
            Set(CaptureSelectionPersistence.keys)
        )
    }
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

    func testPersistentConverterNormalizesMonoPCMToStereoAtFortyEightK() throws {
        let packet = OwnedAudioPacket(
            pcm: OwnedPCMBuffer(sampleRate: 48_000, channels: [[0.25, -0.5]]),
            presentationTime: CMTime(value: 2, timescale: 1)
        )
        let converter = PersistentAudioResampler(source: .microphone)

        let block = try XCTUnwrap(converter.process(packet))

        XCTAssertEqual(block.startFrame, 96_000)
        XCTAssertEqual(block.left, [0.25, -0.5])
        XCTAssertEqual(block.right, [0.25, -0.5])
    }

    func testLateBufferFromStoppedGenerationIsDiscarded() {
        let gate = CaptureSessionGate()
        let stream = NSObject()
        let token = gate.activate(streamIdentity: ObjectIdentifier(stream))

        XCTAssertTrue(gate.accepts(token, streamIdentity: ObjectIdentifier(stream)))
        gate.deactivate(token)

        XCTAssertFalse(gate.accepts(token, streamIdentity: ObjectIdentifier(stream)))
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

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.volatileDomainNames.first(where: { $0.hasPrefix("CaptureStatusTests.") })
            ?? "CaptureStatusTests"
    }
}
