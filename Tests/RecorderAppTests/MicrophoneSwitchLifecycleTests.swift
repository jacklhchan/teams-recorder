import XCTest
@testable import RecorderApp

final class MicrophoneSwitchLifecycleTests: XCTestCase {
    func testMicrophoneSwitchPlanChangesOnlyMicrophoneDeviceIDAndRetainsCaptureConfiguration() {
        let original = LiveMicrophoneConfiguration(
            sampleRate: 48_000, channelCount: 2, capturesAudio: true,
            capturesMicrophone: true, microphoneUID: "A", pixelFormat: 42
        )

        let plan = MicrophoneSwitchPlan(previous: original, requestedUID: "B")

        XCTAssertEqual(plan.configuration.microphoneUID, "B")
        XCTAssertEqual(plan.configuration.sampleRate, original.sampleRate)
        XCTAssertEqual(plan.configuration.channelCount, original.channelCount)
        XCTAssertEqual(plan.configuration.pixelFormat, original.pixelFormat)
        XCTAssertFalse(plan.requiresOutputReattach)
    }

    func testMicrophoneSwitchLifecycleRejectsStaleGenerationAndFirstFrameFromOldToken() {
        var lifecycle = LiveMicrophoneSwitchLifecycle()
        let session = UUID()
        let first = MicrophoneSwitchLifecycleToken(sourceSessionID: session, recordingEpoch: 1, generation: 1)
        let second = MicrophoneSwitchLifecycleToken(sourceSessionID: session, recordingEpoch: 1, generation: 2)

        lifecycle.begin(first, requestedUID: "B")
        lifecycle.begin(second, requestedUID: "C")

        XCTAssertNil(lifecycle.commitFirstFrame(for: first))
        XCTAssertEqual(lifecycle.commitFirstFrame(for: second), "C")
    }

    func testMicrophoneSwitchMissingDeviceReturnsUnavailableWithoutTerminalAction() {
        let result = MicrophoneSwitchAdmission.admit(requestedUID: "missing", availableUIDs: ["A"])
        XCTAssertEqual(result, .unavailable(requestedUID: "missing", reason: .deviceMissing))
    }

    func testMicrophoneSwitchConfigurationErrorRollsBackOldConfigurationAndKeepsDeliveryOpen() {
        let original = LiveMicrophoneConfiguration(sampleRate: 48_000, channelCount: 2, capturesAudio: true, capturesMicrophone: true, microphoneUID: "A", pixelFormat: 42)
        let plan = MicrophoneSwitchPlan(previous: original, requestedUID: "B")
        let updater = FailingMicrophoneConfigurationUpdater()

        let outcome = MicrophoneSwitchConfigurationOperation.apply(plan, updater: updater)

        XCTAssertEqual(outcome, .failed(requestedUID: "B", message: "update failed"))
        XCTAssertEqual(updater.applied, [plan.configuration, original])
    }
}

private final class FailingMicrophoneConfigurationUpdater: MicrophoneConfigurationUpdating {
    private(set) var applied: [LiveMicrophoneConfiguration] = []

    func update(_ configuration: LiveMicrophoneConfiguration) throws {
        applied.append(configuration)
        if applied.count == 1 { throw TestError() }
    }

    private struct TestError: LocalizedError {
        var errorDescription: String? { "update failed" }
    }
}
