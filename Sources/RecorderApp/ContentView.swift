import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(recorder: model.recorder, statusMessage: model.statusMessage) {
                model.refreshDevices()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    permissionRow
                    deviceSection
                    MeterSectionView(
                        recorder: model.recorder,
                        systemDeviceName: model.selectedSystemDevice?.name,
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
                        isTranscribing: model.transcribingSessionID != nil
                    )
                    if let report = model.lastHealthReport {
                        HealthSummaryView(report: report)
                    }
                    RoutingAssistantView(
                        checks: model.routingChecks,
                        refresh: model.refreshRoutingChecks,
                        openAudioMIDISetup: model.openAudioMIDISetup
                    )
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
                    FooterView(recorder: model.recorder, outputFolder: model.outputFolder)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 860, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.permissionMessage.isEmpty {
                Label(model.permissionMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Microphone permission ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var deviceSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Label("System audio", systemImage: "waveform")
                    .font(.headline)
                Picker("System audio", selection: $model.selectedSystemDevice) {
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(Optional(device))
                    }
                }
                .onChange(of: model.selectedSystemDevice) { _, _ in
                    model.refreshMonitoring()
                }
                .labelsHidden()
                .frame(minWidth: 380)
                Text(model.selectedSystemDevice?.channelText ?? "No input")
                    .foregroundStyle(.secondary)
            }

            GridRow {
                Label("Microphone", systemImage: "mic")
                    .font(.headline)
                Picker("Microphone", selection: $model.selectedMicDevice) {
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(Optional(device))
                    }
                }
                .onChange(of: model.selectedMicDevice) { _, _ in
                    model.refreshMonitoring()
                }
                .labelsHidden()
                .frame(minWidth: 380)
                Text(model.selectedMicDevice?.channelText ?? "No input")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.recorder.isRecording)
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
                subtitle: systemDeviceName ?? "Select BlackHole 2ch",
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

            Button {
                runTestRecording()
            } label: {
                Label(isRunningTestRecording ? "Testing..." : "Test 10s", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(recorder.isRecording || isRunningTestRecording)

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
                Label(recorder.micMuted ? "Unmute Recorder Mic" : "Mute Recorder Mic", systemImage: recorder.micMuted ? "mic.fill" : "mic.slash.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

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

private struct RoutingAssistantView: View {
    let checks: [RoutingCheck]
    let refresh: () -> Void
    let openAudioMIDISetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Routing Assistant", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button {
                    openAudioMIDISetup()
                } label: {
                    Label("Audio MIDI", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 8) {
                ForEach(checks) { check in
                    HStack(spacing: 10) {
                        Image(systemName: check.status.iconName)
                            .foregroundStyle(check.status.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                                .font(.callout.weight(.medium))
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
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
                                    play(session)
                                } label: {
                                    Image(systemName: playingSessionID == session.id && isPlaybackActive ? "play.fill" : "play.fill")
                                }
                                .buttonStyle(.bordered)
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
                                PlaybackBarView(
                                    progress: playbackProgress,
                                    duration: playbackDuration,
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

private struct PlaybackBarView: View {
    let progress: TimeInterval
    let duration: TimeInterval
    let stopPlayback: () -> Void
    let seekPlayback: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.timeText(progress))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { progress },
                    set: { seekPlayback($0) }
                ),
                in: 0...max(duration, 1)
            )

            Text(Self.timeText(duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Button {
                stopPlayback()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .help("Stop playback")
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func timeText(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "00:00" }
        let seconds = max(0, Int(time.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct FooterView: View {
    @ObservedObject var recorder: RecordingEngine
    let outputFolder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output: \(recorder.outputFolder?.path ?? outputFolder.path)")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Label("Writes one combined recording.m4a file", systemImage: "doc.badge.gearshape")
                Spacer()
                Label("BlackHole Multi-Output Device recommended", systemImage: "speaker.wave.2")
            }
            .foregroundStyle(.secondary)
        }
    }
}

private extension AudioDevice {
    var channelText: String {
        "\(channelCount) channel\(channelCount == 1 ? "" : "s")"
    }
}
