import Foundation

enum VirtualMicInstallationState: Equatable {
    case absent
    case installedNeedsReboot
    case ready
    case removalNeedsReboot
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
