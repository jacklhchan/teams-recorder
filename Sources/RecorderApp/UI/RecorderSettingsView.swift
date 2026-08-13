import AppKit
import SwiftUI

struct RecorderSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedSection: RecorderSettingsSection = .audio

    var body: some View {
        HStack(spacing: 0) {
            settingsRail
            Divider()
            selectedSectionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.destination.settings.marker"
            )
        )
        .overlay(alignment: .topLeading) {
            RecorderSettingsAccessibilityMarker(
                identifier: "recorder.destination.settings"
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
    }

    private var settingsRail: some View {
        List(RecorderSettingsSection.allCases, selection: $selectedSection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
                .contentShape(Rectangle())
                .accessibilityIdentifier(
                    "recorder.settings.navigation.\(section.rawValue)"
                )
                .background(RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.settings.navigation.\(section.rawValue).marker"
                ).allowsHitTesting(false))
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: "recorder.settings.navigation.\(section.rawValue)"
                ).allowsHitTesting(false))
        }
        .listStyle(.sidebar)
        .frame(minWidth: 176, idealWidth: 210, maxWidth: 240)
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .audio:
            sectionSurface(.audio) { audioSectionContent }
        case .recording:
            sectionSurface(.recording) { recordingSectionContent }
        case .transcription:
            sectionSurface(.transcription) { transcriptionSectionContent }
        case .aiProvider:
            sectionSurface(.aiProvider) {
                AIProviderSettingsView(model: model.aiProviderSettingsModel)
                    .accessibilityIdentifier("recorder.settings.transcription-section")
                    .background(RecorderSettingsAccessibilityMarker(
                        identifier: "recorder.settings.transcription-section"
                    ))
            }
        case .storageShortcuts:
            sectionSurface(.storageShortcuts) { storageAndShortcutsSectionContent }
        }
    }

    private func sectionSurface<Content: View>(
        _ section: RecorderSettingsSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
        }
        .background(RecorderDestinationAccessibilityMarker(
            identifier: "recorder.settings.section.\(section.rawValue)"
        ))
        .background(RecorderSettingsAccessibilityMarker(
            identifier: "recorder.settings.section.\(section.rawValue)"
        ))
        .accessibilityIdentifier("recorder.settings.section.\(section.rawValue)")
    }

    private var audioSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Section("Capture") {
                PermissionStatusView(
                    systemPermission: model.systemAudioPermission,
                    microphonePermission: model.microphonePermission,
                    requestSystem: model.requestSystemAudioPermission,
                    requestMicrophone: model.requestMicrophonePermission,
                    openSystemSettings: model.openScreenCaptureSettings,
                    openMicrophoneSettings: model.openMicrophoneSettings
                )
                CaptureSourceControlsView(model: model, content: .audio)
            }
            .accessibilityIdentifier("recorder.settings.capture-section")
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.settings.capture-section"
                )
            )

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
                Text(
                    "Recorder and native input mute silence the mic track and Local Recorder Virtual Mic. The Teams mute icon may differ."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("virtual-mic-privacy-mute-detail")
                .background(
                    RecorderSettingsAccessibilityMarker(
                        identifier: "virtual-mic-privacy-mute-detail"
                    )
                )
            }
            .accessibilityIdentifier("recorder.settings.audio-integration-section")
            .background(
                RecorderSettingsAccessibilityMarker(
                    identifier: "recorder.settings.audio-integration-section"
                )
            )
        }
    }

    private var recordingSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Section("Capture") {
                CaptureSourceControlsView(model: model, content: .recording)
            }

            Section("Teams") {
                VStack(alignment: .leading, spacing: 16) {
                    if model.showsTeamsScreenCaptureControls {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            TeamsScreenCaptureControlsView(model: model)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Teams Window Auto Mode (Beta)", systemImage: "record.circle")
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
                            cancel: model.cancelTeamsAutoMeetingCountdown,
                            rearm: { _ = model.rearmTeamsAutoMeeting() }
                        )
                    }
                }
            }
        }
    }

    private var transcriptionSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Section("Privacy") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Privacy Mode (Local Only)",
                        isOn: Binding(
                            get: { model.privacyModeEnabled },
                            set: { model.setPrivacyModeEnabled($0) }
                        )
                    )
                    .accessibilityIdentifier(RecorderActionID.privacyModeToggle)
                    .background(RecorderSettingsAccessibilityMarker(
                        identifier: RecorderActionID.privacyModeToggle,
                        label: "Privacy Mode (Local Only)",
                        onPress: {
                            model.setPrivacyModeEnabled(!model.privacyModeEnabled)
                        }
                    ))
                    Text(privacyModeStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(RecorderActionID.privacyModeStatus)
                        .background(RecorderSettingsAccessibilityMarker(
                            identifier: RecorderActionID.privacyModeStatus,
                            label: privacyModeStatusText
                        ))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Transcription Profile", systemImage: "text.bubble")
                    .font(.headline)
                Text("Transcription uses the provider selected in AI Provider.")
                    .foregroundStyle(.secondary)
                Text(model.aiProviderSettingsModel.selectedProviderKind == .hktGenAI
                     ? "HKT GenAI Platform is selected."
                     : "OpenAI-compatible API is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("recorder.settings.transcription-profile-status")
            .background(RecorderSettingsAccessibilityMarker(
                identifier: "recorder.settings.transcription-profile-status"
            ))
        }
    }

    private var privacyModeStatusText: String {
        if model.privacyModeEnabled {
            return "Recording and local files continue normally. Transcription and meeting intelligence will not contact an AI provider."
        }
        return "AI provider actions can use your saved provider settings."
    }

    private var storageAndShortcutsSectionContent: some View {
        let publication = model.recordingPublicationPresentation
        return VStack(alignment: .leading, spacing: 12) {
            Section("Local Control") {
                Toggle(
                    "Allow local recorder control",
                    isOn: Binding(
                        get: { model.localRecorderControlEnabled },
                        set: { model.setLocalRecorderControlEnabled($0) }
                    )
                )
                .accessibilityIdentifier(RecorderActionID.localRecorderControlToggle)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.localRecorderControlToggle,
                    label: "Allow local recorder control",
                    onPress: {
                        model.setLocalRecorderControlEnabled(
                            !model.localRecorderControlEnabled
                        )
                    }
                ))
                Text(localRecorderControlStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(RecorderActionID.localRecorderControlStatus)
                    .background(RecorderSettingsAccessibilityMarker(
                        identifier: RecorderActionID.localRecorderControlStatus,
                        label: localRecorderControlStatusText
                    ))
            }
            Section("Local Artifact Safety") {
                Toggle(
                    "Use owner-only permissions for new local artifacts",
                    isOn: Binding(
                        get: { model.recordingDataLifecyclePolicy.ownerOnlyForNewLocalArtifacts },
                        set: { model.setOwnerOnlyForNewLocalArtifacts($0) }
                    )
                )
                .accessibilityIdentifier(RecorderActionID.lifecycleOwnerOnlyToggle)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.lifecycleOwnerOnlyToggle,
                    label: "Use owner-only permissions for new local artifacts",
                    onPress: {
                        model.setOwnerOnlyForNewLocalArtifacts(
                            !model.recordingDataLifecyclePolicy.ownerOnlyForNewLocalArtifacts
                        )
                    }
                ))
                Text("New app-owned local artifacts use owner-only permissions when supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(RecorderActionID.lifecycleOwnerOnlyStatus)
                    .background(RecorderSettingsAccessibilityMarker(
                        identifier: RecorderActionID.lifecycleOwnerOnlyStatus,
                        label: "New app-owned local artifacts use owner-only permissions when supported."
                    ))
                Toggle(
                    "Redact generated diagnostics",
                    isOn: Binding(
                        get: { model.recordingDataLifecyclePolicy.redactGeneratedDiagnostics },
                        set: { model.setRedactGeneratedDiagnostics($0) }
                    )
                )
                .accessibilityIdentifier(RecorderActionID.lifecycleRedactionToggle)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.lifecycleRedactionToggle,
                    label: "Redact generated diagnostics",
                    onPress: {
                        model.setRedactGeneratedDiagnostics(
                            !model.recordingDataLifecyclePolicy.redactGeneratedDiagnostics
                        )
                    }
                ))
                Text(
                    model.recordingDataLifecyclePolicy.redactGeneratedDiagnostics
                        ? "Generated transcription and meeting-intelligence diagnostic messages use a fixed safe record."
                        : "Generated transcription and meeting-intelligence diagnostic content is not persisted; empty compatibility files may remain."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(RecorderActionID.lifecycleRedactionStatus)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.lifecycleRedactionStatus,
                    label: model.recordingDataLifecyclePolicy.redactGeneratedDiagnostics
                        ? "Generated transcription and meeting-intelligence diagnostic messages use a fixed safe record."
                        : "Generated transcription and meeting-intelligence diagnostic content is not persisted; empty compatibility files may remain."
                ))
            }
            Section("Data Retention") {
                Toggle(
                    "Automatically clean diagnostic files and old backups",
                    isOn: Binding(
                        get: { retentionEnabled },
                        set: { enabled in
                            if enabled {
                                model.requestRetentionEnableConfirmation()
                            } else {
                                model.setRetentionEnabled(false)
                            }
                        }
                    )
                )
                .accessibilityIdentifier(RecorderActionID.retentionToggle)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.retentionToggle,
                    label: "Automatically clean diagnostic files and old backups",
                    onPress: {
                        if retentionEnabled {
                            model.setRetentionEnabled(false)
                        } else {
                            model.requestRetentionEnableConfirmation()
                        }
                    }
                ))
                Text(retentionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(RecorderActionID.retentionStatus)
                    .background(RecorderSettingsAccessibilityMarker(
                        identifier: RecorderActionID.retentionStatus,
                        label: retentionStatusText
                    ))
                if retentionEnabled {
                    Text("Scope: transcription logs, failure diagnostics, and old diagnostic backups after 30 days. Legacy-run folders remain owned by the transcription publisher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let aggregate = model.retentionScanAggregate
                    Text("Eligible: \(aggregate.eligible)  Skipped: \(aggregate.skipped)  Deleted: \(aggregate.deleted)  Errors: \(aggregate.errors)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .alert(
                "Enable automatic diagnostic cleanup?",
                isPresented: Binding(
                    get: { model.retentionEnableConfirmationRequired },
                    set: { visible in
                        if !visible { model.cancelRetentionEnableConfirmation() }
                    }
                )
            ) {
                Button("Enable", role: .destructive, action: model.confirmRetentionEnabled)
                Button("Cancel", role: .cancel, action: model.cancelRetentionEnableConfirmation)
            } message: {
                Text("Only listed diagnostic files and old backups are eligible. Recordings, transcripts, and recovery or publication data are never automatically deleted.")
            }
            Label("Recording Storage", systemImage: "internaldrive")
                .font(.headline)
            Text(destinationStatusText)
                .font(.callout.weight(.medium))
                .accessibilityIdentifier(RecorderActionID.storageDestinationStatus)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.storageDestinationStatus
                ))
                .background(RecorderDestinationAccessibilityMarker(
                    identifier: "\(RecorderActionID.storageDestinationStatus).text",
                    label: destinationStatusText
                ))
            Text(model.outputFolder.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text("Local pending copies")
                    .font(.callout.weight(.medium))
                Text(model.pendingRecordingsFolderURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(publication.stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("Publishing / Pending: \(publication.pendingCount)")
                    Text("Waiting: \(publication.waitingCount)")
                    Text("Needs attention: \(publication.needsAttentionCount)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
                .accessibilityIdentifier(RecorderActionID.storagePendingStatus)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.storagePendingStatus
                ))
                .background(RecorderDestinationAccessibilityMarker(
                    identifier: "\(RecorderActionID.storagePendingStatus).text",
                    label: pendingStatusAccessibilityLabel(publication)
                ))
            Button(
                model.recordingDestinationState == .needsFolderAccess
                    ? "Restore Folder Access"
                    : "Choose Output Folder",
                action: model.chooseOutputFolder
            )
                .accessibilityIdentifier(RecorderActionID.chooseOutputFolder)
                .background(RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.chooseOutputFolder
                ))
            if publication.retainedLocalCount > 0 {
                HStack {
                    if publication.pendingCount + publication.waitingCount > 0 {
                        Button("Retry Now", action: model.retryPendingRecordings)
                            .accessibilityIdentifier(RecorderActionID.storageRetry)
                            .background(RecorderSettingsAccessibilityMarker(
                                identifier: RecorderActionID.storageRetry
                            ))
                    }
                    Button("Open Local Copies", action: model.openPendingRecordingsFolder)
                        .accessibilityIdentifier(RecorderActionID.storageOpenLocal)
                        .background(RecorderSettingsAccessibilityMarker(
                            identifier: RecorderActionID.storageOpenLocal
                        ))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var localRecorderControlStatusText: String {
        model.localRecorderControlEnabled
            ? "Local command-line control is enabled for this Mac."
            : "Local command-line control is off. Recording and microphone settings are unchanged."
    }

    private var retentionEnabled: Bool {
        if case .enabled = model.recordingDataLifecyclePolicy.retention { return true }
        return false
    }

    private var retentionStatusText: String {
        retentionEnabled
            ? "Retention is on for diagnostic files and old backups only. Recordings, transcripts, and recovery or publication data are not automatically deleted."
            : "Off by default. No files are scanned or deleted."
    }

    private var destinationStatusText: String {
        switch model.recordingDestinationState {
        case .ready: "Ready"
        case .needsFolderAccess: "Needs folder access"
        case .unavailable: "Unavailable"
        }
    }

    private func pendingStatusAccessibilityLabel(
        _ publication: RecordingPublicationPresentation
    ) -> String {
        "Local pending copies: \(model.pendingRecordingsFolderURL.path). "
            + "\(publication.stateText). "
            + "Publishing / Pending: \(publication.pendingCount). "
            + "Waiting: \(publication.waitingCount). "
            + "Needs attention: \(publication.needsAttentionCount)."
    }

    private var autoMeetingPresentation: TeamsAutoMeetingPresentation {
        .make(state: model.teamsAutoMeetingState)
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
    enum Content: Equatable {
        case audio
        case recording
    }

    @ObservedObject var model: AppModel
    let content: Content
    @State private var applicationSearch = ""

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            if content == .recording {
                captureModeControls
            }

            if content == .audio {
                microphoneControls
            }
        }
    }

    @ViewBuilder
    private var captureModeControls: some View {
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
    }

    @ViewBuilder
    private var microphoneControls: some View {
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
            .accessibilityIdentifier(RecorderActionID.microphonePicker)
            .background(
                RecorderSettingsAccessibilityMarker(
                    identifier: RecorderActionID.microphonePicker,
                    label: model.selectedMicDevice?.displayName ?? "Choose microphone"
                )
            )
            .disabled(!model.microphoneSelectionEnabled)
            Button { model.refreshDevices() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Refresh microphones")
            .accessibilityLabel("Refresh microphones")
            .accessibilityIdentifier("recorder.settings.microphone-refresh")
            .background(
                RecorderSettingsAccessibilityMarker(
                    identifier: "recorder.settings.microphone-refresh",
                    label: "Refresh microphones"
                )
            )
            Text(microphoneStatusText)
                .foregroundStyle(.secondary)
                .accessibilityLabel(microphoneStatusText)
                .accessibilityIdentifier(RecorderActionID.microphoneSwitchStatus)
                .background(
                    RecorderSettingsAccessibilityMarker(
                        identifier: RecorderActionID.microphoneSwitchStatus,
                        label: microphoneStatusText
                    )
                )
        }
    }

    private var microphoneStatusText: String {
        model.isMicrophoneSwitchPending
            ? "Switching microphone…"
            : (model.selectedMicDevice?.channelText ?? "Unavailable")
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
            Toggle("Teams Window Auto Mode (Beta)", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Detect Teams meeting windows locally and start recording automatically")
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
    let rearm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(presentation.title, systemImage: presentation.systemImage)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .accessibilityIdentifier("teams-auto-recording-status")
                .background(
                    RecorderSettingsAccessibilityMarker(
                        identifier: "teams-auto-recording-status"
                    )
                )
            if presentation.showsCancel {
                Button(action: cancel) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .help("Cancel automatic recording")
                    .accessibilityLabel("Cancel automatic recording")
                    .accessibilityIdentifier("teams-auto-recording-cancel")
            }
            if presentation.showsRearmNow {
                Button("Re-arm Now", action: rearm)
                    .buttonStyle(.bordered)
                    .help("Re-arm Now")
                    .accessibilityLabel("Re-arm Now")
                    .accessibilityIdentifier("teams-auto-recording-rearm-now")
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var label: String? = nil
    var onPress: (() -> Void)? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context _: Context) -> RecorderSettingsAccessibilityMarkerView {
        let view = RecorderSettingsAccessibilityMarkerView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.markerEnabled = isEnabled
        view.onPress = onPress
        return view
    }

    func updateNSView(_ nsView: RecorderSettingsAccessibilityMarkerView, context _: Context) {
        nsView.setAccessibilityIdentifier(identifier)
        nsView.setAccessibilityLabel(label)
        nsView.markerEnabled = isEnabled
        nsView.onPress = onPress
    }
}

final class RecorderSettingsAccessibilityMarkerView: NSView {
    var markerEnabled = true
    var onPress: (() -> Void)?

    override func isAccessibilityEnabled() -> Bool {
        markerEnabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard markerEnabled, let onPress else { return false }
        onPress()
        return true
    }
}
