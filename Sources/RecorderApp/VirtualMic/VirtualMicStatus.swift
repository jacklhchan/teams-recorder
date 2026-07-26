import Foundation

enum VirtualMicInstallationState: Equatable {
    case absent
    case installedNeedsReboot
    case ready
    case removalNeedsReboot
}

enum VirtualMicStatusTone: Equatable {
    case neutral
    case ready
    case warning
}

struct VirtualMicStatusPresentation: Equatable {
    let title: String
    let detail: String
    let tone: VirtualMicStatusTone

    static func make(
        installation: VirtualMicInstallationState,
        publisher: VirtualMicPublisherState,
        inputMuteControlAvailable: Bool
    ) -> VirtualMicStatusPresentation {
        switch installation {
        case .absent:
            return .init(
                title: "Not installed",
                detail: "Local Recorder Virtual Mic",
                tone: .neutral
            )
        case .installedNeedsReboot:
            return .init(
                title: "Restart required",
                detail: "Virtual microphone installed",
                tone: .warning
            )
        case .removalNeedsReboot:
            return .init(
                title: "Restart required",
                detail: "Virtual microphone removal pending",
                tone: .warning
            )
        case .ready:
            switch publisher {
            case .ready:
                return .init(
                    title: "Virtual mic active",
                    detail: inputMuteControlAvailable
                        ? "Recorder mute controls output"
                        : "App mute controls output",
                    tone: .ready
                )
            case .unavailable:
                return .init(
                    title: "Bridge unavailable",
                    detail: "Local recording continues",
                    tone: .warning
                )
            case .stopped:
                return .init(
                    title: "Driver ready",
                    detail: "Virtual mic idle",
                    tone: .neutral
                )
            }
        }
    }
}

struct VirtualMicInstallation {
    static let driverURL = URL(
        fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/LocalRecorderVirtualMic.driver",
        isDirectory: true
    )
    static let deviceUID = "local.meeting.recorder.virtual-mic.v1"

    static func currentState(
        fileExists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        inputDeviceUIDs: () -> [String] = {
            AudioDeviceManager.inputDevices().map(\.uid)
        }
    ) -> VirtualMicInstallationState {
        state(
            bundleExists: fileExists(driverURL.path),
            enumeratedDeviceUIDs: inputDeviceUIDs()
        )
    }

    static func state(
        bundleExists: Bool,
        enumeratedDeviceUIDs: [String]
    ) -> VirtualMicInstallationState {
        let isEnumerated = enumeratedDeviceUIDs.contains(deviceUID)

        switch (bundleExists, isEnumerated) {
        case (false, false):
            return .absent
        case (true, false):
            return .installedNeedsReboot
        case (true, true):
            return .ready
        case (false, true):
            return .removalNeedsReboot
        }
    }
}
