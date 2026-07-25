@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation

enum CapturePermissionState: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
}

enum CaptureReadiness: Equatable {
    case ready
    case reconnectRequired
    case blocked(String)

    static func evaluate(
        permission: CapturePermissionState,
        selection: CaptureSelection,
        resolvedSelection: ResolvedCaptureSelection,
        microphoneAvailable: Bool
    ) -> CaptureReadiness {
        guard permission == .granted else {
            return .blocked("Screen & System Audio Recording permission is required.")
        }
        guard microphoneAvailable else {
            return .blocked("Microphone permission and an available microphone are required.")
        }
        guard selection.mode == .selectedApplication else { return .ready }
        guard let bundleIdentifier = selection.selectedBundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return .blocked("Choose an application to capture.")
        }
        if case .application = resolvedSelection { return .ready }
        return .reconnectRequired
    }
}

enum CaptureStatusAction: Equatable {
    case grant
    case openSettings
    case reconnect
    case none
}

struct CaptureStatusRow: Equatable {
    let title: String
    let message: String
    let action: CaptureStatusAction
}

enum CaptureStatusRowMapper {
    static func row(for permission: CapturePermissionState) -> CaptureStatusRow {
        switch permission {
        case .granted:
            return .init(title: "Screen & System Audio Recording", message: "Permission ready", action: .none)
        case .notDetermined:
            return .init(title: "Screen & System Audio Recording", message: "Permission is required to capture audio.", action: .grant)
        case .denied, .restricted:
            return .init(title: "Screen & System Audio Recording", message: "Permission denied. Open System Settings, then retry.", action: .openSettings)
        }
    }

    static func row(for readiness: CaptureReadiness) -> CaptureStatusRow {
        guard readiness == .reconnectRequired else {
            return .init(title: "System Audio", message: "System audio ready", action: .none)
        }
        return .init(title: "System Audio", message: "App audio disconnected", action: .reconnect)
    }
}

struct CaptureSelectionPersistence {
    static let modeKey = "capture.mode"
    static let selectedBundleIdentifierKey = "capture.selectedBundleIdentifier"
    static let microphoneUIDKey = "capture.microphoneUID"
    static let keys = [modeKey, selectedBundleIdentifierKey, microphoneUIDKey]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSelection() -> CaptureSelection {
        let mode = defaults.string(forKey: Self.modeKey)
            .flatMap(CaptureMode.init(rawValue:)) ?? .allSystemAudio
        return CaptureSelection(
            mode: mode,
            selectedBundleIdentifier: defaults.string(forKey: Self.selectedBundleIdentifierKey)
        )
    }

    func loadMicrophoneUID() -> String? {
        defaults.string(forKey: Self.microphoneUIDKey)
    }

    func save(selection: CaptureSelection, microphoneUID: String?) {
        defaults.set(selection.mode.rawValue, forKey: Self.modeKey)
        defaults.set(selection.selectedBundleIdentifier, forKey: Self.selectedBundleIdentifierKey)
        defaults.set(microphoneUID, forKey: Self.microphoneUIDKey)
    }
}

enum CapturePermission {
    static func screenCapturePreflight() -> CapturePermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    static func microphonePreflight() -> CapturePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    static func requestScreenCaptureAccess() -> CapturePermissionState {
        CGRequestScreenCaptureAccess() ? .granted : .denied
    }

    static func requestMicrophoneAccess() async -> CapturePermissionState {
        guard microphonePreflight() == .notDetermined else { return microphonePreflight() }
        return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
    }

    static func openScreenCaptureSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func openSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
