import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject private var model: AppModel
    @State private var autoMeetingPanel:
        any TeamsAutoMeetingCountdownPresenting

    @MainActor
    init(
        model: AppModel,
        autoMeetingPanelFactory:
            any TeamsAutoMeetingCountdownPresenterFactory =
                TeamsAutoMeetingCountdownPanelFactory()
    ) {
        self.model = model
        _autoMeetingPanel = State(
            initialValue: autoMeetingPanelFactory.makePresenter()
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(recorder: model.recorder, statusMessage: model.statusMessage) {
                model.refreshAllCaptureState()
            }
            .environment(\.isEnabled, model.sourceControlsEnabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    permissionRow
                    deviceSection
                    MeterSectionView(
                        recorder: model.recorder,
                        systemDeviceName: model.systemAudioSubtitle,
                        micDeviceName: model.selectedMicDevice?.name
                    )
                    LiveAudioHealthView(recorder: model.recorder)
                    ControlsView(
                        recorder: model.recorder,
                        startOrStop: model.startOrStop,
                        runTestRecording: model.runTestRecording,
                        toggleRecorderMicMute: {
                            model.toggleRecorderMicMute()
                        },
                        chooseAudioFileForTranscription: model.chooseAudioFileForTranscription,
                        chooseOutputFolder: model.chooseOutputFolder,
                        openRecordingFolder: model.openRecordingFolder,
                        isRunningTestRecording: model.isRunningTestRecording,
                        isTranscribing: model.transcribingSessionID != nil,
                        isCaptureLifecycleWorking: model.isCaptureLifecycleWorking,
                        localMicMuted: model.localMicMuted,
                        nativeInputMicMuted: model.nativeInputMicMuted,
                        teamsMicMuted: model.teamsMicMuted
                    )
                    if let report = model.lastHealthReport {
                        HealthSummaryView(report: report)
                    }
                    ASRModelView(
                        isPreparing: model.isPreparingASRModel,
                        isReady: model.asrModelReady,
                        status: model.asrModelStatus,
                        hasLog: model.asrModelLogURL != nil,
                        prepare: model.prepareASRModelIfNeeded,
                        openLog: model.openASRModelLog
                    )
                    SessionListView(
                        sessions: model.sessions,
                        playingSessionID: model.playingSessionID,
                        playbackProgress: model.playbackProgress,
                        playbackDuration: model.playbackDuration,
                        isPlaybackActive: model.isPlaybackActive,
                        playbackPlayer: model.playbackPlayer,
                        transcribingSessionID: model.transcribingSessionID,
                        transcriptionStatus: model.transcriptionStatus,
                        lastTranscriptionSessionID: model.lastTranscriptionSessionID,
                        lastTranscriptionStatus: model.lastTranscriptionStatus,
                        lastTranscriptionDidFail: model.lastTranscriptionDidFail,
                        asrModelReady: model.asrModelReady,
                        transcriptURLsBySessionID: model.transcriptURLsBySessionID,
                        transcriptLogURLsBySessionID: model.transcriptLogURLsBySessionID,
                        transcriptionStatesBySessionID: model.transcriptionStatesBySessionID,
                        refresh: model.refreshSessions,
                        play: model.play,
                        open: model.open,
                        stopPlayback: {
                            model.stopPlayback()
                        },
                        togglePlayback: model.playbackToggle,
                        seekPlayback: model.seekPlayback,
                        transcribe: model.transcribe,
                        cancelTranscription: model.cancelTranscription,
                        openTranscript: model.openTranscript,
                        openTranscriptLog: model.openTranscriptLog,
                        transcriptText: model.transcriptText,
                        saveTranscript: model.saveTranscript,
                        exportTranscript: model.exportTranscript,
                        copyTranscript: model.copyTranscript,
                        saveMetadata: model.saveMetadata,
                        moveToTrash: model.moveSessionToTrash
                    )
                    FooterView(
                        recorder: model.recorder,
                        outputFolder: model.outputFolder,
                        lastRecordingSavedAsM4A: model.lastRecordingSavedAsM4A
                    )
                }
                .padding(20)
            }
        }
        .frame(minWidth: 860, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(
            of: model.teamsAutoMeetingState,
            initial: true
        ) { _, state in
            if case let .startCountdown(secondsRemaining) = state {
                autoMeetingPanel.present(
                    seconds: secondsRemaining,
                    cancel: model.cancelTeamsAutoMeetingCountdown
                )
            } else {
                autoMeetingPanel.dismiss()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            autoMeetingPanel.dismiss()
        }
        .onDisappear {
            autoMeetingPanel.dismiss()
        }
    }

    private var permissionRow: some View {
        PermissionStatusView(
            systemPermission: model.systemAudioPermission,
            microphonePermission: model.microphonePermission,
            requestSystem: model.requestSystemAudioPermission,
            requestMicrophone: model.requestMicrophonePermission,
            openSystemSettings: model.openScreenCaptureSettings,
            openMicrophoneSettings: model.openMicrophoneSettings
        )
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var deviceSection: some View {
        CaptureControlsView(model: model)
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
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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

private struct CaptureControlsView: View {
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
                    .disabled(!model.sourceControlsEnabled)
                    Button { model.refreshCaptureApplications() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered).help("Refresh applications")
                        .disabled(!model.sourceControlsEnabled)
                        .accessibilityLabel("Refresh capture applications")
                    if model.showsReconnect {
                        Button { model.reconnectSelectedApplication() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.bordered).help("Reconnect selected application")
                            .disabled(!model.canReconnect)
                            .accessibilityLabel("Reconnect selected application audio")
                            .accessibilityIdentifier("reconnect-selected-application")
                    }
                }
            }

            if model.showsTeamsScreenCaptureControls {
                TeamsScreenCaptureControlsView(model: model)
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
                .disabled(!model.sourceControlsEnabled)
                Text(model.selectedMicDevice?.channelText ?? "Unavailable").foregroundStyle(.secondary)
            }

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

    private var autoMeetingPresentation: TeamsAutoMeetingPresentation {
        .make(
            state: model.teamsAutoMeetingState,
            connectionStatus: model.teamsConnectionStatus
        )
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
        }
        .frame(minWidth: 380, alignment: .leading)
    }
}

private struct TeamsAutoMeetingStateView: View {
    let presentation: TeamsAutoMeetingPresentation
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(
                presentation.title,
                systemImage: presentation.systemImage
            )
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .accessibilityIdentifier("teams-auto-recording-status")

            if presentation.showsCancel {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .help("Cancel automatic recording")
                .accessibilityLabel("Cancel automatic recording")
                .accessibilityIdentifier("teams-auto-recording-cancel")
            }
        }
    }

    private var statusColor: Color {
        switch presentation.systemImage {
        case "record.circle.fill":
            .red
        case "exclamationmark.triangle.fill":
            .orange
        default:
            .secondary
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
        .frame(minWidth: 380, alignment: .leading)
    }

    private var detail: String {
        switch status {
        case .disabled:
            "Recorder mute is local only"
        case .connecting:
            "Connecting to Microsoft Teams"
        case .waitingForTeamsAPI:
            "Enable Third-party app API in Teams"
        case .waitingForMeeting:
            "Join a Teams call to complete pairing"
        case .waitingForPairingApproval:
            "Approve Local Meeting Recorder in Teams"
        case .ready:
            "Paired with Microsoft Teams"
        case .inMeeting:
            "AirPods mute sync is active"
        case .failed(let message):
            message
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

            if status == .waitingForPairingApproval {
                Button(action: requestPairing) {
                    Image(systemName: "link.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("Request Teams pairing again")
                .accessibilityLabel("Request Teams pairing again")
            } else if needsRetry {
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Retry Teams mute sync")
                .accessibilityLabel("Retry Teams mute sync")
            }
        }
    }

    private var title: String {
        if status == .pairingResetRequired {
            return "Reset pairing"
        }
        return switch status {
        case .disabled:
            "Off"
        case .connecting:
            "Connecting"
        case .waitingForTeamsAPI:
            "Teams API unavailable"
        case .waitingForMeeting:
            "Ready to pair"
        case .waitingForPairingApproval:
            "Waiting for Allow"
        case .ready:
            "Connected"
        case .inMeeting(let muted):
            muted ? "Teams muted" : "Teams active"
        case .failed:
            "Sync error"
        }
    }

    private var iconName: String {
        switch status {
        case .ready, .inMeeting(muted: false):
            "checkmark.circle.fill"
        case .inMeeting(muted: true):
            "mic.slash.circle.fill"
        case .waitingForTeamsAPI, .waitingForPairingApproval, .failed:
            "exclamationmark.triangle.fill"
        case .connecting:
            "arrow.triangle.2.circlepath"
        case .disabled, .waitingForMeeting:
            "circle.dashed"
        }
    }

    private var statusColor: Color {
        if status == .pairingResetRequired {
            return .orange
        }
        return switch status {
        case .ready, .inMeeting(muted: false):
            .green
        case .waitingForTeamsAPI, .waitingForPairingApproval, .inMeeting(muted: true):
            .orange
        case .failed:
            .red
        case .disabled, .connecting, .waitingForMeeting:
            .secondary
        }
    }

    private var needsRetry: Bool {
        switch status {
        case .waitingForTeamsAPI, .failed:
            true
        default:
            false
        }
    }
}

private struct VirtualMicIdentityView: View {
    @ObservedObject var recorder: RecordingEngine
    let installationState: VirtualMicInstallationState
    let inputMuteControlAvailable: Bool

    private var presentation: VirtualMicStatusPresentation {
        .make(
            installation: installationState,
            publisher: recorder.virtualMicPublisherState,
            inputMuteControlAvailable: inputMuteControlAvailable
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Local Recorder Virtual Mic")
                .lineLimit(1)
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 380, alignment: .leading)
    }
}

private struct VirtualMicStateView: View {
    @ObservedObject var recorder: RecordingEngine
    let installationState: VirtualMicInstallationState
    let inputMuteControlAvailable: Bool

    private var presentation: VirtualMicStatusPresentation {
        .make(
            installation: installationState,
            publisher: recorder.virtualMicPublisherState,
            inputMuteControlAvailable: inputMuteControlAvailable
        )
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

private struct HeaderView: View {
    @ObservedObject var recorder: RecordingEngine
    let statusMessage: String
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(recorder.isRecording ? Color.red : Color.secondary.opacity(0.45))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Meeting Recorder")
                    .font(.system(size: 22, weight: .semibold))
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            recordingTimer
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var elapsedText: String {
        guard let startedAt = recorder.startedAt else { return "00:00:00" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private var recordingTimer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(elapsedText)
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

private struct MeterSectionView: View {
    @ObservedObject var recorder: RecordingEngine
    let systemDeviceName: String?
    let micDeviceName: String?

    var body: some View {
        VStack(spacing: 14) {
            AudioMeterView(
                title: "System Audio",
                subtitle: systemDeviceName ?? "All System Audio",
                level: recorder.systemLevel,
                tint: .cyan
            )
            AudioMeterView(
                title: "Mic Input",
                subtitle: recorder.micMuted ? "Recorder mic track muted" : (micDeviceName ?? "Select microphone"),
                level: recorder.micLevel,
                tint: recorder.micMuted ? .secondary : .green
            )
        }
    }
}

private struct ControlsView: View {
    @ObservedObject var recorder: RecordingEngine
    let startOrStop: () -> Void
    let runTestRecording: () -> Void
    let toggleRecorderMicMute: () -> Void
    let chooseAudioFileForTranscription: () -> Void
    let chooseOutputFolder: () -> Void
    let openRecordingFolder: () -> Void
    let isRunningTestRecording: Bool
    let isTranscribing: Bool
    let isCaptureLifecycleWorking: Bool
    let localMicMuted: Bool
    let nativeInputMicMuted: Bool
    let teamsMicMuted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                startOrStop()
            } label: {
                Label(recorder.isRecording ? "Stop Recording" : "Start Recording", systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    .frame(minWidth: 156)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(recorder.isRecording ? .red : .accentColor)
            .disabled(!recorder.isRecording && isCaptureLifecycleWorking)

            Button {
                runTestRecording()
            } label: {
                Label(isRunningTestRecording ? "Testing..." : "Test 10s", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(recorder.isRecording || isRunningTestRecording || isCaptureLifecycleWorking)

            Button {
                chooseAudioFileForTranscription()
            } label: {
                Label("Upload Audio", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isTranscribing)

            Button {
                toggleRecorderMicMute()
            } label: {
                Label(micMuteButtonTitle, systemImage: micMuteButtonIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled((teamsMicMuted || nativeInputMicMuted) && !localMicMuted)

            Button {
                toggleRecorderMicMute()
            } label: {
                Label("Option+Shift+M", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(true)

            Spacer()

            Button {
                chooseOutputFolder()
            } label: {
                Label("Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(recorder.isRecording)

            Button {
                openRecordingFolder()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
        }
    }

    private var micMuteButtonTitle: String {
        if localMicMuted {
            return "Unmute Recorder Mic"
        }
        if teamsMicMuted {
            return "Muted by Teams"
        }
        if nativeInputMicMuted {
            return "Muted by Input"
        }
        return "Mute Recorder Mic"
    }

    private var micMuteButtonIcon: String {
        localMicMuted ? "mic.fill" : "mic.slash.fill"
    }
}

private struct HealthSummaryView: View {
    let report: RecordingHealthReport

    var body: some View {
        HStack(spacing: 16) {
            Label(report.systemSignalSeen ? "System audio captured" : "No system audio", systemImage: report.systemSignalSeen ? "checkmark.circle.fill" : "speaker.slash.fill")
                .foregroundStyle(report.systemSignalSeen ? .green : .orange)
            Label(report.micSignalSeen ? "Mic captured" : "No mic signal", systemImage: report.micSignalSeen ? "checkmark.circle.fill" : "mic.slash.fill")
                .foregroundStyle(report.micSignalSeen ? .green : .orange)
            if report.clippingEvents > 0 {
                Label("\(report.clippingEvents) clipping events", systemImage: "waveform.path.badge.exclamationmark")
                    .foregroundStyle(.red)
            }
            if report.droppedBuffers > 0 {
                Label("\(report.droppedBuffers) dropped buffers", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct LiveAudioHealthView: View {
    @ObservedObject var recorder: RecordingEngine

    var body: some View {
        let assessment = AudioHealthAdvisor.assessment(
            systemLevel: recorder.systemLevel,
            micLevel: recorder.micLevel,
            isMicMuted: recorder.micMuted,
            isMonitoring: recorder.isMonitoring,
            isRecording: recorder.isRecording
        )
        return HStack(spacing: 18) {
            input(assessment.system, icon: "speaker.wave.2")
            input(assessment.mic, icon: "mic")
            Spacer()
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.55), lineWidth: 1))
    }

    private func input(_ input: AudioHealthAssessment.Input, icon: String) -> some View {
        Label(input.title, systemImage: icon)
            .foregroundStyle(color(for: input.status))
            .help(input.detail)
    }

    private func color(for status: AudioHealthAssessment.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

private struct ASRModelView: View {
    let isPreparing: Bool
    let isReady: Bool
    let status: String
    let hasLog: Bool
    let prepare: () -> Void
    let openLog: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isReady ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(isReady ? .green : .orange)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("oMLX ASR Server")
                    .font(.callout.weight(.medium))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                prepare()
            } label: {
                Label(isReady ? "Ready" : "Prepare", systemImage: isReady ? "checkmark" : "arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(isPreparing || isReady)

            Button {
                openLog()
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.bordered)
            .disabled(!hasLog)
            .help("Open ASR model log")
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct SessionListView: View {
    let sessions: [RecordingSession]
    let playingSessionID: RecordingSession.ID?
    let playbackProgress: TimeInterval
    let playbackDuration: TimeInterval
    let isPlaybackActive: Bool
    let playbackPlayer: AVPlayer
    let transcribingSessionID: RecordingSession.ID?
    let transcriptionStatus: String
    let lastTranscriptionSessionID: RecordingSession.ID?
    let lastTranscriptionStatus: String
    let lastTranscriptionDidFail: Bool
    let asrModelReady: Bool
    let transcriptURLsBySessionID: [RecordingSession.ID: URL]
    let transcriptLogURLsBySessionID: [RecordingSession.ID: URL]
    let transcriptionStatesBySessionID: [RecordingSession.ID: TranscriptionState]
    let refresh: () -> Void
    let play: (RecordingSession) -> Void
    let open: (RecordingSession) -> Void
    let stopPlayback: () -> Void
    let togglePlayback: () -> Void
    let seekPlayback: (TimeInterval) -> Void
    let transcribe: (RecordingSession) -> Void
    let cancelTranscription: () -> Void
    let openTranscript: (RecordingSession) -> Void
    let openTranscriptLog: (RecordingSession) -> Void
    let transcriptText: (RecordingSession) -> String
    let saveTranscript: (String, RecordingSession) -> Void
    let exportTranscript: (RecordingSession) -> Void
    let copyTranscript: (RecordingSession) -> Void
    let saveMetadata: (String, String, Bool, RecordingSession) -> Void
    let moveToTrash: (RecordingSession) -> Void

    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var transcriptSession: RecordingSession?
    @State private var metadataSession: RecordingSession?
    @State private var sessionPendingTrash: RecordingSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recordings", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Toggle(isOn: $favoritesOnly) {
                    Image(systemName: "star.fill")
                }
                .toggleStyle(.button)
                .help("Show favorites only")
            }

            TextField("Search recordings", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredSessions.isEmpty {
                Text("No recordings in the selected folder yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredSessions.prefix(12)) { session in
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayName)
                                        .font(.callout.weight(.medium))
                                    Text("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.durationText) · \(session.fileSizeText)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !session.tags.isEmpty {
                                        Text(session.tags.map { "#\($0)" }.joined(separator: "  "))
                                            .font(.caption)
                                            .foregroundStyle(.tint)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button {
                                    if playingSessionID == session.id {
                                        togglePlayback()
                                    } else {
                                        play(session)
                                    }
                                } label: {
                                    Image(systemName: playingSessionID == session.id && isPlaybackActive ? "pause.fill" : "play.fill")
                                }
                                .buttonStyle(.bordered)
                                .help(playingSessionID == session.id && isPlaybackActive ? "Pause playback" : "Play recording")
                                Button {
                                    open(session)
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.bordered)
                                Button {
                                    metadataSession = session
                                } label: {
                                    Image(systemName: session.isFavorite ? "star.fill" : "slider.horizontal.3")
                                }
                                .buttonStyle(.bordered)
                                .help("Edit recording details")
                                Button {
                                    transcribe(session)
                                } label: {
                                    Image(systemName: transcribingSessionID == session.id ? "waveform" : "text.badge.plus")
                                }
                                .buttonStyle(.bordered)
                                .disabled(transcribingSessionID != nil || !asrModelReady)
                                .help(asrModelReady ? "Transcribe with oMLX Qwen ASR" : "Wait for the oMLX ASR server check")
                                Button {
                                    transcriptSession = session
                                } label: {
                                    Image(systemName: "doc.text.fill")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!hasTranscript(for: session))
                                .help("View and edit transcript")
                                Button(role: .destructive) {
                                    sessionPendingTrash = session
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .help("Move recording to Trash")
                                Button {
                                    openTranscriptLog(session)
                                } label: {
                                    Image(systemName: "terminal")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!hasTranscriptLog(for: session))
                                .help("Open ASR log")
                            }

                            if playingSessionID == session.id {
                                RecordingPlaybackView(
                                    session: session,
                                    player: playbackPlayer,
                                    progress: playbackProgress,
                                    duration: playbackDuration,
                                    isPlaying: isPlaybackActive,
                                    togglePlayback: togglePlayback,
                                    stopPlayback: stopPlayback,
                                    seekPlayback: seekPlayback
                                )
                            }

                            if transcribingSessionID == session.id || lastTranscriptionSessionID == session.id || transcriptionStatesBySessionID[session.id] != nil {
                                HStack(spacing: 8) {
                                    if transcribingSessionID == session.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: statusIcon(for: session))
                                            .foregroundStyle(statusColor(for: session))
                                    }
                                    Text(statusText(for: session))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Spacer()
                                    if transcribingSessionID == session.id {
                                        Button("Cancel") {
                                            cancelTranscription()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    Button {
                                        openTranscriptLog(session)
                                    } label: {
                                        Image(systemName: "terminal")
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Open ASR log")
                                }
                                .padding(10)
                                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.vertical, 8)
                        if session.id != filteredSessions.prefix(12).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
        .sheet(item: $transcriptSession) { session in
            TranscriptEditorView(
                session: session,
                load: { transcriptText(session) },
                save: { saveTranscript($0, session) },
                export: { exportTranscript(session) },
                copy: { copyTranscript(session) }
            )
        }
        .sheet(item: $metadataSession) { session in
            RecordingMetadataEditorView(
                session: session,
                save: { title, tags, favorite in saveMetadata(title, tags, favorite, session) }
            )
        }
        .confirmationDialog(
            "Move recording to Trash?",
            isPresented: Binding(get: { sessionPendingTrash != nil }, set: { if !$0 { sessionPendingTrash = nil } }),
            presenting: sessionPendingTrash
        ) { session in
            Button("Move to Trash", role: .destructive) {
                moveToTrash(session)
                sessionPendingTrash = nil
            }
        } message: { session in
            Text(session.displayName)
        }
    }

    private var filteredSessions: [RecordingSession] {
        sessions.filter { session in
            guard !favoritesOnly || session.isFavorite else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return session.displayName.localizedCaseInsensitiveContains(query)
                || session.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func hasTranscript(for session: RecordingSession) -> Bool {
        if transcriptURLsBySessionID[session.id] != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: TranscriptDocumentStore.editableURL(in: session.folderURL).path)
            || FileManager.default.fileExists(atPath: TranscriptDocumentStore.qwenURL(in: session.folderURL).path)
    }

    private func hasTranscriptLog(for session: RecordingSession) -> Bool {
        if transcriptLogURLsBySessionID[session.id] != nil {
            return true
        }
        let expected = session.folderURL.appendingPathComponent("transcription_qwen_asr.log")
        return FileManager.default.fileExists(atPath: expected.path)
    }

    private func statusText(for session: RecordingSession) -> String {
        if transcribingSessionID == session.id {
            return transcriptionStatus.isEmpty ? "Transcribing..." : transcriptionStatus
        }
        return transcriptionStatesBySessionID[session.id]?.message ?? (lastTranscriptionStatus.isEmpty ? "Transcription finished" : lastTranscriptionStatus)
    }

    private func statusIcon(for session: RecordingSession) -> String {
        switch transcriptionStatesBySessionID[session.id]?.phase {
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled, .interrupted: "pause.circle.fill"
        default: lastTranscriptionDidFail ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        }
    }

    private func statusColor(for session: RecordingSession) -> Color {
        switch transcriptionStatesBySessionID[session.id]?.phase {
        case .failed: .orange
        case .cancelled, .interrupted: .secondary
        default: lastTranscriptionDidFail ? .orange : .green
        }
    }
}

private struct TranscriptEditorView: View {
    let session: RecordingSession
    let load: () -> String
    let save: (String) -> Void
    let export: () -> Void
    let copy: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(session.displayName).font(.headline)
                Spacer()
                Button { copy() } label: { Image(systemName: "doc.on.doc") }.help("Copy transcript")
                Button { export() } label: { Image(systemName: "square.and.arrow.up") }.help("Export transcript")
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(text); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 480)
        .onAppear { text = load() }
    }
}

private struct RecordingMetadataEditorView: View {
    let session: RecordingSession
    let save: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var tags = ""
    @State private var isFavorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recording Details").font(.headline)
            TextField("Title", text: $title)
            TextField("Tags, separated by commas", text: $tags)
            Toggle("Favorite", isOn: $isFavorite)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(title, tags, isFavorite); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            title = session.metadata.title ?? ""
            tags = session.tags.joined(separator: ", ")
            isFavorite = session.isFavorite
        }
    }
}

private struct FooterView: View {
    @ObservedObject var recorder: RecordingEngine
    let outputFolder: URL
    let lastRecordingSavedAsM4A: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output: \(recorder.outputFolder?.path ?? outputFolder.path)")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Label("Writes one combined recording.mp4 file", systemImage: "doc.badge.gearshape")
                Spacer()
                Label("Captures without changing Mac output", systemImage: "speaker.wave.2")
            }
            .foregroundStyle(.secondary)
            if lastRecordingSavedAsM4A {
                Label(
                    "Last recording recovered as recording.m4a",
                    systemImage: "waveform.badge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            }
        }
    }
}

private extension AudioDevice {
    var channelText: String {
        "\(channelCount) channel\(channelCount == 1 ? "" : "s")"
    }
}
