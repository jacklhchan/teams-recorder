public enum RecorderControlCommand: String, Codable, Sendable {
    case status
    case start
    case stop
    case setAuto = "set-auto"
    case setMic = "set-mic"
}

public struct RecorderControlRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let command: RecorderControlCommand
    public let argument: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        command: RecorderControlCommand,
        argument: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.command = command
        self.argument = argument
    }
}

public struct RecorderControlErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RecorderControlStatus: Codable, Equatable, Sendable {
    public let appRunning: Bool
    public let appVersion: String
    public let recordingState: String
    public let lifecycleOperation: String
    public let recordingOwnership: String?
    public let elapsedSeconds: Int?
    public let activeRecordingStorageState: String
    public let operationStatusCode: String
    public let autoModeEnabled: Bool
    public let autoMeetingState: String
    public let autoMeetingCountdownSeconds: Int?
    public let meetingDetectionState: String
    public let selectedMicrophoneName: String?
    public let localMicMuted: Bool
    public let nativeInputMicMuted: Bool
    public let teamsMicState: String
    public let effectiveMicMuted: Bool
    public let virtualMicState: String
    public let virtualMicPublisherState: String?
    public let systemAudioPermission: String
    public let microphonePermission: String
    public let outputStorageState: String

    public init(
        appRunning: Bool,
        appVersion: String,
        recordingState: String,
        lifecycleOperation: String,
        recordingOwnership: String?,
        elapsedSeconds: Int?,
        activeRecordingStorageState: String,
        operationStatusCode: String,
        autoModeEnabled: Bool,
        autoMeetingState: String,
        autoMeetingCountdownSeconds: Int? = nil,
        meetingDetectionState: String,
        selectedMicrophoneName: String?,
        localMicMuted: Bool,
        nativeInputMicMuted: Bool,
        teamsMicState: String,
        effectiveMicMuted: Bool,
        virtualMicState: String,
        virtualMicPublisherState: String? = nil,
        systemAudioPermission: String,
        microphonePermission: String,
        outputStorageState: String
    ) {
        self.appRunning = appRunning
        self.appVersion = appVersion
        self.recordingState = recordingState
        self.lifecycleOperation = lifecycleOperation
        self.recordingOwnership = recordingOwnership
        self.elapsedSeconds = elapsedSeconds
        self.activeRecordingStorageState = Self.activeRecordingStorageState(activeRecordingStorageState)
        self.operationStatusCode = Self.operationStatusCode(operationStatusCode)
        self.autoModeEnabled = autoModeEnabled
        self.autoMeetingState = autoMeetingState
        self.autoMeetingCountdownSeconds = autoMeetingCountdownSeconds
        self.meetingDetectionState = meetingDetectionState
        self.selectedMicrophoneName = selectedMicrophoneName
        self.localMicMuted = localMicMuted
        self.nativeInputMicMuted = nativeInputMicMuted
        self.teamsMicState = teamsMicState
        self.effectiveMicMuted = effectiveMicMuted
        self.virtualMicState = virtualMicState
        self.virtualMicPublisherState = virtualMicPublisherState
        self.systemAudioPermission = systemAudioPermission
        self.microphonePermission = microphonePermission
        self.outputStorageState = Self.outputStorageState(outputStorageState)
    }

    private enum CodingKeys: String, CodingKey {
        case appRunning, appVersion, recordingState, lifecycleOperation, recordingOwnership
        case elapsedSeconds, activeRecordingStorageState, operationStatusCode
        case autoModeEnabled, autoMeetingState, autoMeetingCountdownSeconds
        case meetingDetectionState, selectedMicrophoneName, localMicMuted
        case nativeInputMicMuted, teamsMicState, effectiveMicMuted, virtualMicState
        case virtualMicPublisherState, systemAudioPermission, microphonePermission
        case outputStorageState
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appRunning = try values.decode(Bool.self, forKey: .appRunning)
        appVersion = try values.decode(String.self, forKey: .appVersion)
        recordingState = try values.decode(String.self, forKey: .recordingState)
        lifecycleOperation = try values.decode(String.self, forKey: .lifecycleOperation)
        recordingOwnership = try values.decodeIfPresent(String.self, forKey: .recordingOwnership)
        elapsedSeconds = try values.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
        activeRecordingStorageState = Self.activeRecordingStorageState(try values.decodeIfPresent(String.self, forKey: .activeRecordingStorageState) ?? "inactive")
        operationStatusCode = Self.operationStatusCode(try values.decodeIfPresent(String.self, forKey: .operationStatusCode) ?? Self.legacyOperationStatusCode(recordingState: recordingState, lifecycleOperation: lifecycleOperation))
        autoModeEnabled = try values.decode(Bool.self, forKey: .autoModeEnabled)
        autoMeetingState = try values.decode(String.self, forKey: .autoMeetingState)
        autoMeetingCountdownSeconds = try values.decodeIfPresent(Int.self, forKey: .autoMeetingCountdownSeconds)
        meetingDetectionState = try values.decode(String.self, forKey: .meetingDetectionState)
        selectedMicrophoneName = try values.decodeIfPresent(String.self, forKey: .selectedMicrophoneName)
        localMicMuted = try values.decode(Bool.self, forKey: .localMicMuted)
        nativeInputMicMuted = try values.decode(Bool.self, forKey: .nativeInputMicMuted)
        teamsMicState = try values.decode(String.self, forKey: .teamsMicState)
        effectiveMicMuted = try values.decode(Bool.self, forKey: .effectiveMicMuted)
        virtualMicState = try values.decode(String.self, forKey: .virtualMicState)
        virtualMicPublisherState = try values.decodeIfPresent(String.self, forKey: .virtualMicPublisherState)
        systemAudioPermission = try values.decode(String.self, forKey: .systemAudioPermission)
        microphonePermission = try values.decode(String.self, forKey: .microphonePermission)
        outputStorageState = Self.outputStorageState(try values.decodeIfPresent(String.self, forKey: .outputStorageState) ?? "unavailable")
    }

    private static func legacyOperationStatusCode(
        recordingState: String,
        lifecycleOperation: String
    ) -> String {
        if recordingState == "recording" { return "recording" }
        if lifecycleOperation == "start" { return "starting" }
        if lifecycleOperation == "stop" { return "stopping" }
        return "idle"
    }

    private static func activeRecordingStorageState(_ value: String) -> String { value == "active" ? "active" : "inactive" }
    private static func outputStorageState(_ value: String) -> String { ["configured", "needsFolderAccess", "unavailable"].contains(value) ? value : "unavailable" }
    private static func operationStatusCode(_ value: String) -> String { ["idle", "recording", "starting", "stopping", "saved", "attention"].contains(value) ? value : "attention" }

}

public struct RecorderControlResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let ok: Bool
    public let status: RecorderControlStatus?
    public let error: RecorderControlErrorPayload?

    public init(
        protocolVersion: Int,
        requestID: String,
        ok: Bool,
        status: RecorderControlStatus?,
        error: RecorderControlErrorPayload?
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.ok = ok
        self.status = status
        self.error = error
    }
}
