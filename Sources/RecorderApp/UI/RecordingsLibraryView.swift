import SwiftUI

struct RecordingsLibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Recordings", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.chooseAudioFileForTranscription()
                    } label: {
                        Label("Upload Audio", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.transcribingSessionID != nil)
                    .accessibilityIdentifier(RecorderActionID.uploadAudio)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.uploadAudio
                        )
                    )
                    Button {
                        model.refreshSessions()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(RecorderActionID.refreshRecordings)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.refreshRecordings
                        )
                    )
                }

                SessionListView(
                    sessions: model.sessions,
                    transcribingSessionID: model.transcribingSessionID,
                    transcriptionStatus: model.transcriptionStatus,
                    lastTranscriptionSessionID: model.lastTranscriptionSessionID,
                    lastTranscriptionStatus: model.lastTranscriptionStatus,
                    lastTranscriptionDidFail: model.lastTranscriptionDidFail,
                    hasSavedProviderProfile: model.aiProviderSettingsModel.hasSavedProfile,
                    transcriptionStatesBySessionID: model.transcriptionStatesBySessionID,
                    play: model.play,
                    open: model.open,
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
            }
            .padding(20)
        }
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.destination.recordings"
            )
        )
        .accessibilityIdentifier("recorder.destination.recordings")
    }
}

private struct SessionListView: View {
    let sessions: [RecordingSession]
    let transcribingSessionID: RecordingSession.ID?
    let transcriptionStatus: String
    let lastTranscriptionSessionID: RecordingSession.ID?
    let lastTranscriptionStatus: String
    let lastTranscriptionDidFail: Bool
    let hasSavedProviderProfile: Bool
    let transcriptionStatesBySessionID: [RecordingSession.ID: TranscriptionState]
    let play: (RecordingSession) -> Void
    let open: (RecordingSession) -> Void
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
        let query = RecordingLibraryQuery(text: searchText, favoritesOnly: favoritesOnly)
        let visibleSessions = query.filter(sessions)
        let lastVisibleSessionID = visibleSessions.last?.id

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search recordings", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: $favoritesOnly) {
                    Image(systemName: "star.fill")
                }
                .toggleStyle(.button)
                .help("Show favorites only")
            }

            if visibleSessions.isEmpty {
                Text("No recordings in the selected folder yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleSessions) { session in
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayName).font(.callout.weight(.medium))
                                    Text("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.durationText) · \(session.fileSizeText)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !session.tags.isEmpty {
                                        Text(session.tags.map { "#\($0)" }.joined(separator: "  "))
                                            .font(.caption).foregroundStyle(.tint).lineLimit(1)
                                    }
                                    if let snippet = query.transcriptSnippet(for: session) {
                                        Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                Button { play(session) } label: { Image(systemName: "play.fill") }
                                    .buttonStyle(.bordered)
                                    .help("Play recording in a separate window")
                                    .accessibilityLabel("Play \(session.displayName)")
                                    .background(
                                        RecorderDestinationAccessibilityMarker(
                                            identifier: "recorder.row.play.\(session.id.lastPathComponent)",
                                            label: "Play \(session.displayName)"
                                        )
                                    )
                                Button { open(session) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel("Open \(session.displayName)")
                                Button { metadataSession = session } label: {
                                    Image(systemName: session.isFavorite ? "star.fill" : "slider.horizontal.3")
                                }
                                .buttonStyle(.bordered)
                                .help("Edit recording details")
                                .accessibilityLabel("Edit details for \(session.displayName)")
                                .background(
                                    RecorderDestinationAccessibilityMarker(
                                        identifier: "recorder.row.edit.\(session.id.lastPathComponent)",
                                        label: "Edit details for \(session.displayName)"
                                    )
                                )
                                Button { transcribe(session) } label: {
                                    Image(systemName: transcribingSessionID == session.id ? "waveform" : "text.badge.plus")
                                }
                                .buttonStyle(.bordered)
                                .disabled(transcribingSessionID != nil || !hasSavedProviderProfile)
                                .help(hasSavedProviderProfile ? "Transcribe with the configured AI provider" : "Configure an AI provider first")
                                .accessibilityLabel("Transcribe \(session.displayName)")
                                Button { transcriptSession = session } label: { Image(systemName: "doc.text.fill") }
                                    .buttonStyle(.bordered)
                                    .disabled(!hasTranscript(for: session))
                                    .help("View and edit transcript")
                                    .accessibilityIdentifier(RecorderActionID.openTranscript)
                                    .accessibilityLabel("Open Transcript for \(session.displayName)")
                                Button(role: .destructive) { sessionPendingTrash = session } label: { Image(systemName: "trash") }
                                    .buttonStyle(.bordered)
                                    .help("Move recording to Trash")
                                    .accessibilityLabel("Move \(session.displayName) to Trash")
                                Button { openTranscriptLog(session) } label: { Image(systemName: "terminal") }
                                    .buttonStyle(.bordered)
                                    .disabled(!hasTranscriptLog(for: session))
                                    .help("Open ASR log")
                                    .accessibilityLabel("Open ASR log for \(session.displayName)")
                            }

                            if transcribingSessionID == session.id || lastTranscriptionSessionID == session.id || transcriptionStatesBySessionID[session.id] != nil {
                                HStack(spacing: 8) {
                                    if transcribingSessionID == session.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: statusIcon(for: session)).foregroundStyle(statusColor(for: session))
                                    }
                                    Text(statusText(for: session)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer()
                                    if transcribingSessionID == session.id {
                                        Button("Cancel", action: cancelTranscription).buttonStyle(.bordered)
                                    }
                                    Button { openTranscriptLog(session) } label: { Image(systemName: "terminal") }
                                        .buttonStyle(.bordered).help("Open ASR log")
                                        .accessibilityLabel("Open ASR log for \(session.displayName)")
                                }
                                .padding(10)
                                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.vertical, 8)
                        if session.id != lastVisibleSessionID { Divider() }
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.55), lineWidth: 1))
        .sheet(item: $transcriptSession) { session in
            TranscriptEditorView(session: session, load: { transcriptText(session) }, save: { saveTranscript($0, session) }, export: { exportTranscript(session) }, copy: { copyTranscript(session) })
        }
        .sheet(item: $metadataSession) { session in
            RecordingMetadataEditorView(session: session) { title, tags, favorite in
                saveMetadata(title, tags, favorite, session)
            }
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

    private func hasTranscript(for session: RecordingSession) -> Bool {
        TranscriptDocumentStore.resolvedURL(in: session.folderURL) != nil
    }

    private func hasTranscriptLog(for session: RecordingSession) -> Bool {
        TranscriptDocumentStore.logURL(in: session.folderURL) != nil
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
            TextEditor(text: $text).font(.body).frame(minHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(text); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(RecorderActionID.saveTranscript)
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
                Button("Save") { save(title, tags, isFavorite); dismiss() }.buttonStyle(.borderedProminent)
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
