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

enum CaptureConnectionState: Equatable {
    case connected
    case selectedApplicationDisconnected(
        sourceSessionID: UUID,
        bundleIdentifier: String
    )
    case terminal
}

enum CaptureConnectionProjection {
    static func observeSystemConnection(
        current: CaptureConnectionState,
        snapshot: CaptureConnectionSnapshot,
        selection: CaptureSelection
    ) -> CaptureConnectionState {
        guard let sourceSessionID = snapshot.sourceSessionID else {
            return .connected
        }
        guard activeSelectionMatchesIntent(
            snapshot.activeSelection,
            intent: selection
        ) else {
            return current
        }
        guard snapshot.isMonitoring else {
            return snapshot.isSystemCaptureConnected ? .connected : .terminal
        }
        guard !snapshot.isSystemCaptureConnected else {
            return .connected
        }
        guard case let .application(application) = snapshot.activeSelection else {
            return current
        }
        return .selectedApplicationDisconnected(
            sourceSessionID: sourceSessionID,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    static func resolveAfterRefresh(
        selection: CaptureSelection,
        applications: [CaptureApplication],
        connectionState: CaptureConnectionState
    ) -> ResolvedCaptureSelection {
        if case let .selectedApplicationDisconnected(_, bundleIdentifier) = connectionState,
           selection.mode == .selectedApplication,
           selection.selectedBundleIdentifier == bundleIdentifier {
            return .disconnected(bundleIdentifier)
        }
        return CaptureSelectionResolver.resolve(
            selection: selection,
            availableApplications: applications
        )
    }

    static func canReconnect(
        systemPermission: CapturePermissionState,
        selection: CaptureSelection,
        connectionState: CaptureConnectionState,
        connectionSnapshot: CaptureConnectionSnapshot,
        isLifecycleWorking: Bool
    ) -> Bool {
        guard systemPermission == .granted,
              selection.mode == .selectedApplication,
              !isLifecycleWorking,
              let bundleIdentifier = selection.selectedBundleIdentifier,
              !bundleIdentifier.isEmpty,
              case let .selectedApplicationDisconnected(
                  disconnectedSessionID,
                  disconnectedBundleIdentifier
              ) = connectionState,
              disconnectedBundleIdentifier == bundleIdentifier,
              connectionSnapshot.sourceSessionID == disconnectedSessionID,
              connectionSnapshot.isMonitoring,
              !connectionSnapshot.isSystemCaptureConnected,
              case let .application(activeApplication) = connectionSnapshot.activeSelection,
              activeApplication.bundleIdentifier == bundleIdentifier else {
            return false
        }
        return true
    }

    private static func activeSelectionMatchesIntent(
        _ activeSelection: ResolvedCaptureSelection?,
        intent: CaptureSelection
    ) -> Bool {
        switch (activeSelection, intent.mode) {
        case (.allSystemAudio?, .allSystemAudio):
            return true
        case let (.application(application)?, .selectedApplication):
            return application.bundleIdentifier == intent.selectedBundleIdentifier
        default:
            return false
        }
    }
}

enum CaptureLifecycleOperation: Equatable {
    case refresh
    case permission
    case start
    case test
    case reconnect
    case stop
}

struct CaptureLifecycleToken: Equatable {
    let generation: UInt64
    let operation: CaptureLifecycleOperation
}

struct CaptureLifecycleGate {
    private var generation: UInt64 = 0
    private var activeToken: CaptureLifecycleToken?

    var isWorking: Bool { activeToken != nil }

    mutating func begin(
        _ operation: CaptureLifecycleOperation
    ) -> CaptureLifecycleToken? {
        guard activeToken == nil else { return nil }
        return install(operation)
    }

    mutating func cancelAndBeginStop() -> CaptureLifecycleToken? {
        if activeToken?.operation == .stop {
            return nil
        }
        return install(.stop)
    }

    func accepts(_ token: CaptureLifecycleToken) -> Bool {
        activeToken == token
    }

    mutating func finish(_ token: CaptureLifecycleToken) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }

    private mutating func install(
        _ operation: CaptureLifecycleOperation
    ) -> CaptureLifecycleToken {
        generation &+= 1
        let token = CaptureLifecycleToken(
            generation: generation,
            operation: operation
        )
        activeToken = token
        return token
    }
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
            return .init(title: "Screen & System Audio Recording", message: "Permission denied. Open System Settings, then restart or retry.", action: .openSettings)
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
        saveSelection(selection)
        saveMicrophoneUID(microphoneUID)
    }

    func saveSelection(_ selection: CaptureSelection) {
        defaults.set(selection.mode.rawValue, forKey: Self.modeKey)
        defaults.set(selection.selectedBundleIdentifier, forKey: Self.selectedBundleIdentifierKey)
    }

    func saveMicrophoneUID(_ microphoneUID: String?) {
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
