import XCTest
@testable import RecorderControl

final class RecorderControlMessagesTests: XCTestCase {
    func testRequestDefaultsToCurrentProtocolVersionAndRoundTrips() throws {
        let request = RecorderControlRequest(
            requestID: "request-1",
            command: .setAuto,
            argument: "on"
        )

        XCTAssertEqual(request.protocolVersion, 1)
        XCTAssertEqual(try roundTrip(request), request)
    }

    func testResponseWithStatusRoundTrips() throws {
        let status = RecorderControlStatus(
            appRunning: true,
            appVersion: "1.2.3",
            recordingState: "recording",
            lifecycleOperation: "none",
            recordingOwnership: "app",
            elapsedSeconds: 42,
            activeRecordingFolder: "/tmp/recording",
            statusMessage: "Recording",
            autoModeEnabled: true,
            autoMeetingState: "inMeeting",
            meetingDetectionState: "detected",
            selectedMicrophoneName: "Built-in Microphone",
            selectedMicrophoneUID: "builtin-mic",
            localMicMuted: false,
            nativeInputMicMuted: false,
            teamsMicState: "unmuted",
            effectiveMicMuted: false,
            virtualMicState: "available",
            systemAudioPermission: "granted",
            microphonePermission: "granted",
            outputFolder: "/tmp/output"
        )
        let response = RecorderControlResponse(
            protocolVersion: 1,
            requestID: "request-1",
            ok: true,
            status: status,
            error: nil
        )

        XCTAssertEqual(try roundTrip(response), response)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
