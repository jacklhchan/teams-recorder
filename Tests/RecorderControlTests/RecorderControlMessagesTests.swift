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
            autoMeetingCountdownSeconds: 5,
            meetingDetectionState: "detected",
            selectedMicrophoneName: "Built-in Microphone",
            selectedMicrophoneUID: "builtin-mic",
            localMicMuted: false,
            nativeInputMicMuted: false,
            teamsMicState: "unmuted",
            effectiveMicMuted: false,
            virtualMicState: "available",
            virtualMicPublisherState: "ready",
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

        let decoded = try roundTrip(response)

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.status?.autoMeetingCountdownSeconds, 5)
        XCTAssertEqual(decoded.status?.virtualMicPublisherState, "ready")
    }

    func testLegacyProtocolOneStatusWithoutNewKeysDecodes() throws {
        let legacyJSON = Data(#"""
        {
          "protocolVersion": 1,
          "requestID": "legacy-status",
          "ok": true,
          "status": {
            "appRunning": true,
            "appVersion": "1.2.3",
            "recordingState": "idle",
            "lifecycleOperation": "none",
            "statusMessage": "Ready",
            "autoModeEnabled": false,
            "autoMeetingState": "waitingForMeeting",
            "meetingDetectionState": "waiting",
            "localMicMuted": false,
            "nativeInputMicMuted": false,
            "teamsMicState": "unknown",
            "effectiveMicMuted": false,
            "virtualMicState": "ready",
            "systemAudioPermission": "granted",
            "microphonePermission": "granted",
            "outputFolder": "/tmp/output"
          },
          "error": null
        }
        """#.utf8)

        let response = try JSONDecoder().decode(
            RecorderControlResponse.self,
            from: legacyJSON
        )
        let status = try XCTUnwrap(response.status)

        XCTAssertEqual(response.protocolVersion, 1)
        XCTAssertEqual(status.autoMeetingState, "waitingForMeeting")
        XCTAssertNil(status.autoMeetingCountdownSeconds)
        XCTAssertNil(status.virtualMicPublisherState)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
