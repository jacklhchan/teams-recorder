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
            activeRecordingStorageState: "active",
            operationStatusCode: "recording",
            autoModeEnabled: true,
            autoMeetingState: "inMeeting",
            autoMeetingCountdownSeconds: 5,
            meetingDetectionState: "detected",
            selectedMicrophoneName: "Built-in Microphone",
            localMicMuted: false,
            nativeInputMicMuted: false,
            teamsMicState: "notMonitored",
            effectiveMicMuted: false,
            virtualMicState: "available",
            virtualMicPublisherState: "ready",
            systemAudioPermission: "granted",
            microphonePermission: "granted",
            outputStorageState: "configured"
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

    func testLegacyProtocolOneStatusWithSensitiveFieldsDecodesToSafeProjection() throws {
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
            "activeRecordingFolder": "/Users/private/meeting",
            "statusMessage": "provider=https://private.example prompt=secret token=abc",
            "autoModeEnabled": false,
            "autoMeetingState": "waitingForMeeting",
            "meetingDetectionState": "waiting",
            "selectedMicrophoneUID": "mic-secret-uid",
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
        XCTAssertEqual(status.activeRecordingStorageState, "inactive")
        XCTAssertEqual(status.operationStatusCode, "idle")
        XCTAssertEqual(status.outputStorageState, "unavailable")

        let rendered = try String(decoding: JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(rendered.contains("/Users/private/meeting"))
        XCTAssertFalse(rendered.contains("mic-secret-uid"))
        XCTAssertFalse(rendered.contains("private.example"))
    }

    func testInvalidNewProjectionValuesDecodeToSafeFiniteValues() throws {
        let data = Data(#"""
        {"appRunning":true,"appVersion":"1","recordingState":"idle","lifecycleOperation":"none","activeRecordingStorageState":"/Users/private/meeting token=abc","operationStatusCode":"secret prompt=abc","autoModeEnabled":false,"autoMeetingState":"waiting","meetingDetectionState":"waiting","localMicMuted":false,"nativeInputMicMuted":false,"teamsMicState":"unknown","effectiveMicMuted":false,"virtualMicState":"ready","systemAudioPermission":"granted","microphonePermission":"granted","outputStorageState":"mic-secret-uid"}
        """#.utf8)

        let status = try JSONDecoder().decode(RecorderControlStatus.self, from: data)

        XCTAssertEqual(status.activeRecordingStorageState, "inactive")
        XCTAssertEqual(status.operationStatusCode, "attention")
        XCTAssertEqual(status.outputStorageState, "unavailable")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(status), as: UTF8.self).contains("secret"))
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
