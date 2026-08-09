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
    public let activeRecordingFolder: String?
    public let statusMessage: String
    public let autoModeEnabled: Bool
    public let autoMeetingState: String
    public let autoMeetingCountdownSeconds: Int?
    public let meetingDetectionState: String
    public let selectedMicrophoneName: String?
    public let selectedMicrophoneUID: String?
    public let localMicMuted: Bool
    public let nativeInputMicMuted: Bool
    public let teamsMicState: String
    public let effectiveMicMuted: Bool
    public let virtualMicState: String
    public let virtualMicPublisherState: String?
    public let systemAudioPermission: String
    public let microphonePermission: String
    public let outputFolder: String

    public init(
        appRunning: Bool,
        appVersion: String,
        recordingState: String,
        lifecycleOperation: String,
        recordingOwnership: String?,
        elapsedSeconds: Int?,
        activeRecordingFolder: String?,
        statusMessage: String,
        autoModeEnabled: Bool,
        autoMeetingState: String,
        autoMeetingCountdownSeconds: Int? = nil,
        meetingDetectionState: String,
        selectedMicrophoneName: String?,
        selectedMicrophoneUID: String?,
        localMicMuted: Bool,
        nativeInputMicMuted: Bool,
        teamsMicState: String,
        effectiveMicMuted: Bool,
        virtualMicState: String,
        virtualMicPublisherState: String? = nil,
        systemAudioPermission: String,
        microphonePermission: String,
        outputFolder: String
    ) {
        self.appRunning = appRunning
        self.appVersion = appVersion
        self.recordingState = recordingState
        self.lifecycleOperation = lifecycleOperation
        self.recordingOwnership = recordingOwnership
        self.elapsedSeconds = elapsedSeconds
        self.activeRecordingFolder = activeRecordingFolder
        self.statusMessage = statusMessage
        self.autoModeEnabled = autoModeEnabled
        self.autoMeetingState = autoMeetingState
        self.autoMeetingCountdownSeconds = autoMeetingCountdownSeconds
        self.meetingDetectionState = meetingDetectionState
        self.selectedMicrophoneName = selectedMicrophoneName
        self.selectedMicrophoneUID = selectedMicrophoneUID
        self.localMicMuted = localMicMuted
        self.nativeInputMicMuted = nativeInputMicMuted
        self.teamsMicState = teamsMicState
        self.effectiveMicMuted = effectiveMicMuted
        self.virtualMicState = virtualMicState
        self.virtualMicPublisherState = virtualMicPublisherState
        self.systemAudioPermission = systemAudioPermission
        self.microphonePermission = microphonePermission
        self.outputFolder = outputFolder
    }
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
