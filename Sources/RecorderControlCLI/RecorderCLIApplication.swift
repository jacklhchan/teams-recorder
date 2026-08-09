import Foundation
import RecorderControl

protocol RecorderCLIClient {
    func send(
        command: RecorderControlCommand,
        argument: String?
    ) async throws -> RecorderControlResponse
}

protocol RecorderAppLaunching {
    func launchInBackground() async throws
}

protocol RecorderCLIClock {
    var now: TimeInterval { get }
    func sleep(for interval: TimeInterval) async throws
}

struct RecorderCLIApplication {
    static let usage = """
    Usage: recorderctl status [--json] | watch [--json] | start | stop | auto on|off | mic mute|unmute
    """

    private let client: RecorderCLIClient
    private let launcher: RecorderAppLaunching
    private let clock: RecorderCLIClock
    private let writeLine: (String) -> Void

    init(
        client: RecorderCLIClient,
        launcher: RecorderAppLaunching,
        clock: RecorderCLIClock,
        writeLine: @escaping (String) -> Void
    ) {
        self.client = client
        self.launcher = launcher
        self.clock = clock
        self.writeLine = writeLine
    }

    func run(arguments: [String]) async -> Int32 {
        let command: RecorderCLICommand
        do {
            command = try RecorderCLICommand(arguments: arguments)
        } catch {
            writeLine(Self.usage)
            return 2
        }

        return await run(command: command)
    }

    func run(command: RecorderCLICommand) async -> Int32 {
        do {
            switch command {
            case let .status(json):
                return try await requestOnce(command: .status, argument: nil, json: json)
            case let .watch(json):
                return try await watch(json: json)
            case let .request(request, argument):
                return try await requestOnce(command: request, argument: argument, json: false)
            }
        } catch is CancellationError {
            return 0
        } catch RecorderCLIApplicationError.startupTimedOut {
            writeLine("error: Recorder app did not become ready within 5 seconds.")
            return 3
        } catch let error as RecorderCLIApplicationError {
            writeLine("error: \(error.message)")
            return 3
        } catch {
            writeLine("error: \(error.localizedDescription)")
            return 3
        }
    }

    private func requestOnce(
        command: RecorderControlCommand,
        argument: String?,
        json: Bool
    ) async throws -> Int32 {
        let response = try await sendWithBackgroundLaunch(command: command, argument: argument)
        guard response.ok else {
            let error = response.error ?? RecorderControlErrorPayload(
                code: "unknown",
                message: "Recorder rejected the operation."
            )
            writeLine("error [\(error.code)]: \(error.message)")
            return 4
        }
        guard let status = response.status else {
            throw RecorderCLIApplicationError.missingStatus
        }
        try render(status, json: json)
        return 0
    }

    private func watch(json: Bool) async throws -> Int32 {
        var previousStatus: RecorderControlStatus?

        while true {
            if previousStatus != nil {
                try await clock.sleep(for: 1)
            }
            let response = try await sendWithBackgroundLaunch(command: .status, argument: nil)
            guard response.ok else {
                let error = response.error ?? RecorderControlErrorPayload(
                    code: "unknown",
                    message: "Recorder rejected the operation."
                )
                writeLine("error [\(error.code)]: \(error.message)")
                return 4
            }
            guard let status = response.status else {
                throw RecorderCLIApplicationError.missingStatus
            }
            if status != previousStatus {
                try render(status, json: json)
                previousStatus = status
            }
        }
    }

    private func sendWithBackgroundLaunch(
        command: RecorderControlCommand,
        argument: String?
    ) async throws -> RecorderControlResponse {
        do {
            let response = try await client.send(command: command, argument: argument)
            try Task.checkCancellation()
            return response
        } catch {
            try Task.checkCancellation()
            guard Self.isUnavailableTransport(error) else {
                throw RecorderCLIApplicationError.transportFailed(
                    Self.transportFailureDescription(error)
                )
            }
        }

        do {
            try await launcher.launchInBackground()
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            throw RecorderCLIApplicationError.launchFailed(error.localizedDescription)
        }

        let deadline = clock.now + 5
        while true {
            let remaining = deadline - clock.now
            guard remaining > 0 else {
                throw RecorderCLIApplicationError.startupTimedOut
            }
            try await clock.sleep(for: min(0.1, remaining))
            do {
                let response = try await client.send(command: command, argument: argument)
                try Task.checkCancellation()
                return response
            } catch {
                try Task.checkCancellation()
                guard Self.isUnavailableTransport(error) else {
                    throw RecorderCLIApplicationError.transportFailed(
                        Self.transportFailureDescription(error)
                    )
                }
            }
        }
    }

    private static func isUnavailableTransport(_ error: Error) -> Bool {
        guard let error = error as? POSIXError else { return false }
        return error.code == .ENOENT || error.code == .ECONNREFUSED
    }

    private static func transportFailureDescription(_ error: Error) -> String {
        if let error = error as? RecorderControlSocketError {
            switch error {
            case .invalidSocketPath:
                return "invalid socket path."
            case .invalidExistingSocket:
                return "invalid socket endpoint."
            case .oversizedFrame:
                return "oversized response."
            case .timedOut:
                return "request timed out."
            case .connectionClosed:
                return "connection closed before a complete response."
            case .malformedFrame:
                return "malformed response."
            case .peerUIDMismatch:
                return "peer identity mismatch."
            }
        }
        if let error = error as? POSIXError {
            return "POSIX error \(error.code.rawValue)."
        }
        return String(describing: error)
    }

    private func render(_ status: RecorderControlStatus, json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(status)
            guard let line = String(data: data, encoding: .utf8) else {
                throw RecorderCLIApplicationError.invalidJSON
            }
            writeLine(line)
            return
        }

        for line in Self.humanLines(for: status) {
            writeLine(line)
        }
    }

    private static func humanLines(for status: RecorderControlStatus) -> [String] {
        let appState = status.appRunning ? "running" : "not running"
        return [
            "App: \(appState) (\(status.appVersion))",
            "Recording: \(status.recordingState)",
            "Lifecycle operation: \(status.lifecycleOperation)",
            "Recording ownership: \(status.recordingOwnership ?? "-")",
            "Elapsed seconds: \(status.elapsedSeconds.map(String.init) ?? "-")",
            "Active recording folder: \(status.activeRecordingFolder ?? "-")",
            "Status message: \(status.statusMessage)",
            "Auto Mode enabled: \(yesNo(status.autoModeEnabled))",
            "Auto meeting state: \(status.autoMeetingState)",
            "Auto meeting countdown seconds: \(status.autoMeetingCountdownSeconds.map(String.init) ?? "-")",
            "Meeting detection: \(status.meetingDetectionState)",
            "Selected microphone: \(status.selectedMicrophoneName ?? "-")",
            "Selected microphone UID: \(status.selectedMicrophoneUID ?? "-")",
            "Recorder mic muted: \(yesNo(status.localMicMuted))",
            "Native input mic muted: \(yesNo(status.nativeInputMicMuted))",
            "Teams mic state: \(status.teamsMicState)",
            "Effective mic muted: \(yesNo(status.effectiveMicMuted))",
            "Virtual Mic: \(status.virtualMicState)",
            "Virtual Mic publisher: \(status.virtualMicPublisherState ?? "unknown")",
            "System Audio permission: \(status.systemAudioPermission)",
            "Microphone permission: \(status.microphonePermission)",
            "Output folder: \(status.outputFolder)"
        ]
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}

enum RecorderCLIEntrypoint {
    static func run(
        arguments: [String],
        writeLine: @escaping (String) -> Void,
        makeApplication: () throws -> RecorderCLIApplication
    ) async -> Int32 {
        let command: RecorderCLICommand
        do {
            command = try RecorderCLICommand(arguments: arguments)
        } catch {
            writeLine(RecorderCLIApplication.usage)
            return 2
        }

        do {
            let application = try makeApplication()
            return await application.run(command: command)
        } catch {
            writeLine("error: \(error.localizedDescription)")
            return 3
        }
    }
}

private enum RecorderCLIApplicationError: Error {
    case startupTimedOut
    case launchFailed(String)
    case transportFailed(String)
    case missingStatus
    case invalidJSON

    var message: String {
        switch self {
        case .startupTimedOut:
            return "Recorder app did not become ready within 5 seconds."
        case let .launchFailed(message):
            return "Unable to launch Recorder app: \(message)"
        case let .transportFailed(message):
            return "Recorder control transport failed: \(message)"
        case .missingStatus:
            return "Recorder app returned no status."
        case .invalidJSON:
            return "Recorder status could not be encoded as JSON."
        }
    }
}

struct SystemRecorderCLIClock: RecorderCLIClock {
    var now: TimeInterval {
        Date.timeIntervalSinceReferenceDate
    }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

struct RecorderCLISocketClient: RecorderCLIClient {
    let socketPath: String
    private let client = RecorderControlSocketClient()

    func send(
        command: RecorderControlCommand,
        argument: String?
    ) async throws -> RecorderControlResponse {
        let request = RecorderControlRequest(
            requestID: UUID().uuidString,
            command: command,
            argument: argument
        )
        return try await client.send(request, to: socketPath, timeout: 5)
    }
}
