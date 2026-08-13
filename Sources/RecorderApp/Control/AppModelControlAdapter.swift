import Foundation
import RecorderControl

@MainActor
final class AppModelControlAdapter {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ request: RecorderControlRequest) async -> RecorderControlResponse {
        guard request.protocolVersion == RecorderControlRequest.currentProtocolVersion else {
            return response(request: request, ok: false, error: .init(
                code: "unsupported_protocol",
                message: "Unsupported protocol version."
            ))
        }

        switch request.command {
        case .status:
            guard request.argument == nil else {
                return invalidArgumentResponse(request)
            }
            return response(request: request, ok: true)
        case .start:
            guard request.argument == nil else {
                return invalidArgumentResponse(request)
            }
            return response(for: model.startRecordingFromControl(), request: request)
        case .stop:
            guard request.argument == nil else {
                return invalidArgumentResponse(request)
            }
            return response(for: model.stopRecordingFromControl(), request: request)
        case .setAuto:
            guard let enabled = autoArgument(request.argument) else {
                return invalidArgumentResponse(request)
            }
            model.setTeamsAutoMeetingEnabled(enabled)
            return response(request: request, ok: true)
        case .setMic:
            guard let muted = micArgument(request.argument) else {
                return invalidArgumentResponse(request)
            }
            model.setRecorderMicMuted(muted)
            return response(request: request, ok: true)
        }
    }

    private func response(
        for outcome: RecorderControlActionOutcome,
        request: RecorderControlRequest
    ) -> RecorderControlResponse {
        switch outcome {
        case .accepted, .noOp:
            response(request: request, ok: true)
        case let .rejected(code, message):
            response(request: request, ok: false, error: .init(code: code, message: message))
        }
    }

    private func invalidArgumentResponse(_ request: RecorderControlRequest) -> RecorderControlResponse {
        response(request: request, ok: false, error: .init(
            code: "invalid_argument",
            message: "Invalid command argument."
        ))
    }

    private func response(
        request: RecorderControlRequest,
        ok: Bool,
        error: RecorderControlErrorPayload? = nil
    ) -> RecorderControlResponse {
        .init(
            protocolVersion: RecorderControlRequest.currentProtocolVersion,
            requestID: request.requestID,
            ok: ok,
            status: status(),
            error: error
        )
    }

    private func autoArgument(_ argument: String?) -> Bool? {
        switch argument {
        case "on": true
        case "off": false
        default: nil
        }
    }

    private func micArgument(_ argument: String?) -> Bool? {
        switch argument {
        case "mute": true
        case "unmute": false
        default: nil
        }
    }

    private func status() -> RecorderControlStatus {
        let snapshot = model.recorderMicMuteSnapshot
        return .init(
            appRunning: true,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            recordingState: recordingState(),
            lifecycleOperation: lifecycleOperation(),
            recordingOwnership: recordingOwnership(),
            elapsedSeconds: elapsedSeconds(),
            activeRecordingStorageState: model.recorder.outputFolder == nil ? "inactive" : "active",
            operationStatusCode: operationStatusCode(),
            autoModeEnabled: model.teamsAutoMeetingEnabled,
            autoMeetingState: autoMeetingState(),
            autoMeetingCountdownSeconds: autoMeetingCountdownSeconds(),
            meetingDetectionState: meetingDetectionState(),
            selectedMicrophoneName: model.selectedMicDevice?.name,
            localMicMuted: snapshot.localMuted,
            nativeInputMicMuted: snapshot.nativeInputMuted,
            teamsMicState: "notMonitored",
            effectiveMicMuted: snapshot.effectiveMuted,
            virtualMicState: virtualMicState(),
            virtualMicPublisherState: virtualMicPublisherState(),
            systemAudioPermission: permission(model.systemAudioPermission),
            microphonePermission: permission(model.microphonePermission),
            outputStorageState: outputStorageState()
        )
    }

    private func recordingState() -> String {
        if model.recorder.isRecording { return "recording" }
        if model.recorder.isMonitoring { return "monitoring" }
        return "idle"
    }

    private func operationStatusCode() -> String {
        if model.recorder.isRecording { return "recording" }
        switch model.recordingLifecycleOperation {
        case .start: return "starting"
        case .stop: return "stopping"
        default: break
        }
        switch model.teamsAutoMeetingState {
        case .startBlocked, .startFailed: return "attention"
        default: return "idle"
        }
    }

    private func outputStorageState() -> String {
        let path = model.outputFolder.path
        guard FileManager.default.fileExists(atPath: path) else { return "unavailable" }
        return FileManager.default.isWritableFile(atPath: path) ? "configured" : "needsFolderAccess"
    }

    private func lifecycleOperation() -> String {
        switch model.recordingLifecycleOperation {
        case .none: "none"
        case .refresh: "refresh"
        case .permission: "permission"
        case .start: "start"
        case .test: "test"
        case .reconnect: "reconnect"
        case .stop: "stop"
        }
    }

    private func recordingOwnership() -> String? {
        switch model.recordingOwnership {
        case .none: nil
        case .manual: "manual"
        case .teamsAutomatic: "teamsAutomatic"
        }
    }

    private func elapsedSeconds() -> Int? {
        guard let startedAt = model.recorder.startedAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    private func autoMeetingState() -> String {
        switch model.teamsAutoMeetingState {
        case .disabled: "disabled"
        case .waitingForMeeting: "waitingForMeeting"
        case .startCountdown: "startCountdown"
        case .starting: "starting"
        case .automaticRecording: "automaticRecording"
        case .stopCountdown: "stopCountdown"
        case .suppressedUntilMeetingEnd: "suppressedUntilMeetingEnd"
        case .startBlocked: "startBlocked"
        case .startFailed: "startFailed"
        }
    }

    private func autoMeetingCountdownSeconds() -> Int? {
        switch model.teamsAutoMeetingState {
        case let .startCountdown(secondsRemaining),
             let .stopCountdown(secondsRemaining):
            secondsRemaining
        default:
            nil
        }
    }

    private func meetingDetectionState() -> String {
        switch model.teamsLocalMeetingDetectionState {
        case .waiting: "waiting"
        case .confirming: "confirming"
        case .detected: "detected"
        case .ending: "ending"
        case .ambiguous: "ambiguous"
        }
    }

    private func virtualMicState() -> String {
        switch model.virtualMicInstallationState {
        case .absent: "absent"
        case .installedNeedsReboot: "installedNeedsReboot"
        case .ready: "ready"
        case .removalNeedsReboot: "removalNeedsReboot"
        }
    }

    private func virtualMicPublisherState() -> String {
        switch model.recorder.virtualMicPublisherState {
        case .stopped: "stopped"
        case .ready: "ready"
        case .unavailable: "unavailable"
        }
    }

    private func permission(_ state: CapturePermissionState) -> String {
        switch state {
        case .notDetermined: "notDetermined"
        case .granted: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        }
    }
}
