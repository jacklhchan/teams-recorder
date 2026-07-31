import AppKit
import SwiftUI

struct RecorderSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Capture") {
                PermissionStatusView(
                    systemPermission: model.systemAudioPermission,
                    microphonePermission: model.microphonePermission,
                    requestSystem: model.requestSystemAudioPermission,
                    requestMicrophone: model.requestMicrophonePermission,
                    openSystemSettings: model.openScreenCaptureSettings,
                    openMicrophoneSettings: model.openMicrophoneSettings
                )
                CaptureSourceControlsView(model: model)
            }
            .accessibilityIdentifier("recorder.settings.capture-section")
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.settings.capture-section"
                )
            )

            Section("Teams") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    if model.showsTeamsScreenCaptureControls {
                        TeamsScreenCaptureControlsView(model: model)
                    }
                    GridRow {
                        Label("Teams Auto Recording", systemImage: "record.circle")
                            .font(.headline)
                        TeamsAutoMeetingDetailView(
                            presentation: autoMeetingPresentation,
                            isEnabled: Binding(
                                get: { model.teamsAutoMeetingEnabled },
                                set: { model.setTeamsAutoMeetingEnabled($0) }
                            )
                        )
                        TeamsAutoMeetingStateView(
                            presentation: autoMeetingPresentation,
                            cancel: model.cancelTeamsAutoMeetingCountdown
                        )
                    }
                    GridRow {
                        Label("Teams Mute Sync", systemImage: "person.2.wave.2")
                            .font(.headline)
                        TeamsMuteSyncDetailView(
                            status: model.teamsMuteSyncStatus,
                            isEnabled: Binding(
                                get: { model.teamsMuteSyncEnabled },
                                set: { model.setTeamsMuteSyncEnabled($0) }
                            )
                        )
                        TeamsMuteSyncStateView(
                            status: model.teamsMuteSyncStatus,
                            retry: model.retryTeamsMuteSync,
                            requestPairing: model.requestTeamsPairing
                        )
                    }
                }
            }

            Section("Audio Integration") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Label("Virtual Mic", systemImage: "person.wave.2").font(.headline)
                        VirtualMicIdentityView(
                            recorder: model.recorder,
                            installationState: model.virtualMicInstallationState,
                            inputMuteControlAvailable: model.inputMuteControlAvailable
                        )
                        VirtualMicStateView(
                            recorder: model.recorder,
                            installationState: model.virtualMicInstallationState,
                            inputMuteControlAvailable: model.inputMuteControlAvailable
                        )
                    }
                }
            }
            .accessibilityIdentifier("recorder.settings.audio-integration-section")
            .background(
                RecorderSettingsAccessibilityMarker(
                    identifier: "recorder.settings.audio-integration-section"
                )
            )

            Section("Transcription") {
                AIProviderSettingsView(model: model.aiProviderSettingsModel)
            }
            .accessibilityIdentifier("recorder.settings.transcription-section")
            .background(
                RecorderSettingsAccessibilityMarker(
                    identifier: "recorder.settings.transcription-section"
                )
            )
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.destination.settings"
            )
        )
        .accessibilityIdentifier("recorder.destination.settings")
    }

    private var autoMeetingPresentation: TeamsAutoMeetingPresentation {
        .make(
            state: model.teamsAutoMeetingState,
            connectionStatus: model.teamsConnectionStatus
        )
    }
}

private struct PermissionStatusView: View {
    let systemPermission: CapturePermissionState
    let microphonePermission: CapturePermissionState
    let requestSystem: () -> Void
    let requestMicrophone: () -> Void
    let openSystemSettings: () -> Void
    let openMicrophoneSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(
                CaptureStatusRowMapper.row(for: systemPermission),
                icon: "rectangle.inset.filled.badge.record",
                action: systemPermission == .denied || systemPermission == .restricted ? openSystemSettings : requestSystem
            )
            row(
                microphoneRow,
                icon: "mic",
                action: microphonePermission == .denied || microphonePermission == .restricted ? openMicrophoneSettings : requestMicrophone
            )
        }
    }

    private var microphoneRow: CaptureStatusRow {
        switch microphonePermission {
        case .granted: .init(title: "Microphone", message: "Permission ready", action: .none)
        case .notDetermined: .init(title: "Microphone", message: "Permission is required to record microphone audio.", action: .grant)
        case .denied, .restricted: .init(title: "Microphone", message: "Permission denied. Open System Settings, then retry.", action: .openSettings)
        }
    }

    private func row(_ row: CaptureStatusRow, icon: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.callout.weight(.medium))
                Text(row.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if row.action != .none {
                Button(row.action == .openSettings ? "Open System Settings" : "Grant Access", action: action)
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct CaptureSourceControlsView: View {
    @ObservedObject var model: AppModel
    @State private var applicationSearch = ""

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Label("Capture", systemImage: "waveform")
                    .font(.headline)
                Picker("Capture", selection: Binding(
                    get: { model.captureSelection.mode },
                    set: { model.selectCaptureMode($0) }
                )) {
                    Text("All System Audio").tag(CaptureMode.allSystemAudio)
                    Text("Selected App").tag(CaptureMode.selectedApplication)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("capture-mode-picker")
                .frame(minWidth: 380)
                .background(
                    RecorderSettingsAccessibilityMarker(
                        identifier: "capture-mode-picker"
                    )
                )
                .disabled(!model.sourceControlsEnabled)
            }

            if model.captureSelection.mode == .selectedApplication {
                GridRow {
                    Label("Application", systemImage: "app")
                        .font(.headline)
                    Menu {
                        TextField("Search applications", text: $applicationSearch)
                        Divider()
                        ForEach(filteredApplications) { application in
                            Button(application.name) {
                                model.selectCaptureApplication(bundleIdentifier: application.bundleIdentifier)
                            }
                        }
                    } label: {
                        Text(selectedApplicationName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(minWidth: 330, alignment: .leading)
                    .accessibilityIdentifier("recorder.settings.capture-application-picker")
                    .background(
                        RecorderSettingsAccessibilityMarker(
                            identifier: "recorder.settings.capture-application-picker"
                        )
                    )
                    .disabled(!model.sourceControlsEnabled)
                    Button { model.refreshCaptureApplications() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered).help("Refresh applications")
                        .accessibilityLabel("Refresh capture applications")
                        .accessibilityIdentifier("recorder.settings.capture-refresh")
                        .background(
                            RecorderSettingsAccessibilityMarker(
                                identifier: "recorder.settings.capture-refresh"
                            )
                        )
                        .disabled(!model.sourceControlsEnabled)
                    if model.showsReconnect {
                        Button { model.reconnectSelectedApplication() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.bordered).help("Reconnect selected application")
                            .disabled(!model.canReconnect)
                            .accessibilityLabel("Reconnect selected application audio")
                            .accessibilityIdentifier("reconnect-selected-application")
                    }
                }
            }

            GridRow {
                Label("Microphone", systemImage: "mic").font(.headline)
                Picker("Microphone", selection: Binding(
                    get: { model.selectedMicDevice },
                    set: { model.selectMicrophone($0) }
                )) {
                    Text("Choose microphone").tag(Optional<AudioDevice>.none)
                    ForEach(model.devices) { device in Text(device.displayName).tag(Optional(device)) }
                }
                .labelsHidden().frame(minWidth: 380)
                .accessibilityIdentifier("recorder.settings.microphone-picker")
                .background(
                    RecorderSettingsAccessibilityMarker(
                        identifier: "recorder.settings.microphone-picker"
                    )
                )
                .disabled(!model.sourceControlsEnabled)
                Text(model.selectedMicDevice?.channelText ?? "Unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private var filteredApplications: [CaptureApplication] {
        let query = applicationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.availableCaptureApplications : model.availableCaptureApplications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedApplicationName: String {
        if case .application(let application) = model.resolvedCaptureSelection { return application.name }
        return "Choose an application"
    }
}

private struct TeamsAutoMeetingDetailView: View {
    let presentation: TeamsAutoMeetingPresentation
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Toggle("Teams Auto Recording", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Start recording automatically for Teams meetings")
                .accessibilityIdentifier("teams-auto-recording-toggle")
                .background(
                    RecorderSettingsAccessibilityMarker(
                        identifier: "teams-auto-recording-toggle"
                    )
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TeamsAutoMeetingStateView: View {
    let presentation: TeamsAutoMeetingPresentation
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(presentation.title, systemImage: presentation.systemImage)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .accessibilityIdentifier("teams-auto-recording-status")
            if presentation.showsCancel {
                Button(action: cancel) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .help("Cancel automatic recording")
                    .accessibilityLabel("Cancel automatic recording")
                    .accessibilityIdentifier("teams-auto-recording-cancel")
            }
        }
    }

    private var statusColor: Color {
        switch presentation.systemImage {
        case "record.circle.fill": .red
        case "exclamationmark.triangle.fill": .orange
        default: .secondary
        }
    }
}

private struct TeamsMuteSyncDetailView: View {
    let status: TeamsMuteSyncStatus
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Toggle("Teams mute sync", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Follow Microsoft Teams microphone mute state")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detail: String {
        switch status {
        case .disabled: "Recorder mute is local only"
        case .connecting: "Connecting to Microsoft Teams"
        case .waitingForTeamsAPI: "Enable Third-party app API in Teams"
        case .waitingForMeeting: "Join a Teams call to complete pairing"
        case .waitingForPairingApproval: "Approve Local Meeting Recorder in Teams"
        case .ready: "Paired with Microsoft Teams"
        case .inMeeting: "AirPods mute sync is active"
        case .failed(let message): message
        }
    }
}

private struct TeamsMuteSyncStateView: View {
    let status: TeamsMuteSyncStatus
    let retry: () -> Void
    let requestPairing: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: iconName)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .accessibilityIdentifier("teams-mute-sync-status")
                .background(
                    RecorderSettingsAccessibilityMarker(
                        identifier: "teams-mute-sync-status"
                    )
                )
            if status == .waitingForPairingApproval {
                Button(action: requestPairing) { Image(systemName: "link.badge.plus") }
                    .buttonStyle(.bordered)
                    .help("Request Teams pairing again")
                    .accessibilityLabel("Request Teams pairing again")
            } else if needsRetry {
                Button(action: retry) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .help("Retry Teams mute sync")
                    .accessibilityLabel("Retry Teams mute sync")
            }
        }
    }

    private var title: String {
        if status == .pairingResetRequired { return "Reset pairing" }
        return switch status {
        case .disabled: "Off"
        case .connecting: "Connecting"
        case .waitingForTeamsAPI: "Teams API unavailable"
        case .waitingForMeeting: "Ready to pair"
        case .waitingForPairingApproval: "Waiting for Allow"
        case .ready: "Connected"
        case .inMeeting(let muted): muted ? "Teams muted" : "Teams active"
        case .failed: "Sync error"
        }
    }

    private var iconName: String {
        switch status {
        case .ready, .inMeeting(muted: false): "checkmark.circle.fill"
        case .inMeeting(muted: true): "mic.slash.circle.fill"
        case .waitingForTeamsAPI, .waitingForPairingApproval, .failed: "exclamationmark.triangle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disabled, .waitingForMeeting: "circle.dashed"
        }
    }

    private var statusColor: Color {
        if status == .pairingResetRequired { return .orange }
        return switch status {
        case .ready, .inMeeting(muted: false): .green
        case .waitingForTeamsAPI, .waitingForPairingApproval, .inMeeting(muted: true): .orange
        case .failed: .red
        case .disabled, .connecting, .waitingForMeeting: .secondary
        }
    }

    private var needsRetry: Bool {
        switch status {
        case .waitingForTeamsAPI, .failed: true
        default: false
        }
    }
}

private struct VirtualMicIdentityView: View {
    @ObservedObject var recorder: RecordingEngine
    let installationState: VirtualMicInstallationState
    let inputMuteControlAvailable: Bool

    private var presentation: VirtualMicStatusPresentation {
        .make(installation: installationState, publisher: recorder.virtualMicPublisherState, inputMuteControlAvailable: inputMuteControlAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Local Recorder Virtual Mic").lineLimit(1)
            Text(presentation.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 380, alignment: .leading)
    }
}

private struct VirtualMicStateView: View {
    @ObservedObject var recorder: RecordingEngine
    let installationState: VirtualMicInstallationState
    let inputMuteControlAvailable: Bool

    private var presentation: VirtualMicStatusPresentation {
        .make(installation: installationState, publisher: recorder.virtualMicPublisherState, inputMuteControlAvailable: inputMuteControlAvailable)
    }

    var body: some View {
        Label(presentation.title, systemImage: iconName)
            .foregroundStyle(statusColor)
            .lineLimit(1)
    }

    private var iconName: String {
        switch presentation.tone {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .ready: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

extension AudioDevice {
    var channelText: String {
        "\(channelCount) channel\(channelCount == 1 ? "" : "s")"
    }
}

struct RecorderSettingsAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context _: Context) -> RecorderSettingsAccessibilityMarkerView {
        let view = RecorderSettingsAccessibilityMarkerView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.markerEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: RecorderSettingsAccessibilityMarkerView, context _: Context) {
        nsView.setAccessibilityIdentifier(identifier)
        nsView.markerEnabled = isEnabled
    }
}

final class RecorderSettingsAccessibilityMarkerView: NSView {
    var markerEnabled = true

    override func isAccessibilityEnabled() -> Bool {
        markerEnabled
    }
}
