import SwiftUI

struct RecordingsLibraryView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var favoritesOnly = false

    var body: some View {
        let query = RecordingLibraryQuery(
            text: searchText,
            favoritesOnly: favoritesOnly
        )
        let visibleSessions = query.filter(model.sessions)
        let toolbarPresentation = RecordingsToolbarPresentation.make(
            isTranscribing: model.transcribingSessionID != nil
        )

        SessionListView(
            sessions: visibleSessions,
            query: query,
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
            meetingIntelligencePresentation: model.meetingIntelligencePresentation,
            checkMeetingIntelligenceAvailability: model.checkMeetingIntelligenceAvailability,
            generateMeetingIntelligence: model.generateMeetingIntelligence,
            regenerateMeetingIntelligence: model.regenerateMeetingIntelligence,
            retryMeetingIntelligenceGeneration: model.retryMeetingIntelligenceGeneration,
            cancelMeetingIntelligence: model.cancelMeetingIntelligence,
            applyMeetingIntelligenceSuggestedTitle: model.applyMeetingIntelligenceSuggestedTitle,
            saveMetadata: model.saveMetadata,
            moveToTrash: model.moveSessionToTrash
        )
        .navigationTitle("Recordings")
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search recordings"
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.chooseAudioFileForTranscription()
                } label: {
                    Label("Upload Audio", systemImage: "square.and.arrow.up")
                }
                .disabled(toolbarPresentation.uploadDisabled)
                .accessibilityIdentifier(RecorderActionID.uploadAudio)

                Button {
                    model.refreshSessions()
                } label: {
                    Label("Refresh Recordings", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(RecorderActionID.refreshRecordings)
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $favoritesOnly) {
                    Label("Favorites", systemImage: "star.fill")
                }
                .toggleStyle(.button)
                .help("Show favorites only")
                .accessibilityIdentifier(RecorderActionID.filterFavorites)
            }
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
    let query: RecordingLibraryQuery
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
    let meetingIntelligencePresentation: (RecordingSession) -> MeetingIntelligencePresentation
    let checkMeetingIntelligenceAvailability: (RecordingSession) -> Void
    let generateMeetingIntelligence: (RecordingSession) -> Void
    let regenerateMeetingIntelligence: (RecordingSession) -> Void
    let retryMeetingIntelligenceGeneration: (RecordingSession) -> Void
    let cancelMeetingIntelligence: (RecordingSession) -> Void
    let applyMeetingIntelligenceSuggestedTitle: (RecordingSession) -> Void
    let saveMetadata: (String, String, Bool, RecordingSession) -> Void
    let moveToTrash: (RecordingSession) -> Void

    @State private var transcriptSession: RecordingSession?
    @State private var metadataSession: RecordingSession?
    @State private var sessionPendingTrash: RecordingSession?

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "list.bullet.rectangle",
                    description: Text(
                        "No recordings match the current folder and filters."
                    )
                )
            } else {
                List(sessions) { session in
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
                                .background(
                                    RecorderDestinationAccessibilityMarker(
                                        identifier: "recorder.row.open.\(session.id.lastPathComponent)",
                                        label: "Open \(session.displayName)"
                                    )
                                )
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
                            .background(
                                RecorderDestinationAccessibilityMarker(
                                    identifier: "recorder.row.transcribe.\(session.id.lastPathComponent)",
                                    label: "Transcribe \(session.displayName)"
                                )
                            )
                            Button { transcriptSession = session } label: { Image(systemName: "doc.text.fill") }
                                .buttonStyle(.bordered)
                                .disabled(!hasTranscript(for: session))
                                .help("View and edit transcript")
                                .accessibilityIdentifier(RecorderActionID.openTranscript)
                                .accessibilityLabel("Open Transcript for \(session.displayName)")
                                .background(
                                    RecorderDestinationAccessibilityMarker(
                                        identifier: "recorder.row.transcript.\(session.id.lastPathComponent)",
                                        label: "Open Transcript for \(session.displayName)"
                                    )
                                )
                            Button(role: .destructive) { sessionPendingTrash = session } label: { Image(systemName: "trash") }
                                .buttonStyle(.bordered)
                                .help("Move recording to Trash")
                                .accessibilityLabel("Move \(session.displayName) to Trash")
                                .background(
                                    RecorderDestinationAccessibilityMarker(
                                        identifier: "recorder.row.trash.\(session.id.lastPathComponent)",
                                        label: "Move \(session.displayName) to Trash"
                                    )
                                )
                            Button { openTranscriptLog(session) } label: { Image(systemName: "terminal") }
                                .buttonStyle(.bordered)
                                .disabled(!hasTranscriptLog(for: session))
                                .help("Open ASR log")
                                .accessibilityLabel("Open ASR log for \(session.displayName)")
                                .background(
                                    RecorderDestinationAccessibilityMarker(
                                        identifier: "recorder.row.log.\(session.id.lastPathComponent)",
                                        label: "Open ASR log for \(session.displayName)"
                                    )
                                )
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
                            .background(RecorderVisualStyle.cardSurface, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $transcriptSession) { session in
            TranscriptEditorView(
                session: session,
                load: { transcriptText(session) },
                save: { saveTranscript($0, session) },
                openFolder: { open(session) },
                play: { play(session) },
                export: { exportTranscript(session) },
                copy: { copyTranscript(session) },
                editDetails: { metadataSession = session },
                meetingIntelligencePresentation: meetingIntelligencePresentation(session),
                meetingIntelligenceActions: .init(
                    generate: { generateMeetingIntelligence(session) },
                    regenerate: { regenerateMeetingIntelligence(session) },
                    checkAgain: { checkMeetingIntelligenceAvailability(session) },
                    retryGeneration: { retryMeetingIntelligenceGeneration(session) },
                    cancel: { cancelMeetingIntelligence(session) },
                    applySuggestedTitle: { applyMeetingIntelligenceSuggestedTitle(session) }
                )
            )
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

struct TranscriptEditorView: View {
    let session: RecordingSession
    let load: () -> String
    let save: (String) -> Void
    let openFolder: () -> Void
    /// Requests playback through the existing external presenter. This sheet
    /// never creates an AVPlayerView or owns player lifetime.
    let play: () -> Void
    let export: () -> Void
    let copy: () -> Void
    let editDetails: () -> Void
    let meetingIntelligencePresentation: MeetingIntelligencePresentation
    let meetingIntelligenceActions: MeetingIntelligenceActions
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    init(
        session: RecordingSession,
        load: @escaping () -> String,
        save: @escaping (String) -> Void,
        openFolder: @escaping () -> Void = {},
        play: @escaping () -> Void = {},
        export: @escaping () -> Void,
        copy: @escaping () -> Void,
        editDetails: @escaping () -> Void = {},
        meetingIntelligencePresentation: MeetingIntelligencePresentation = .empty,
        meetingIntelligenceActions: MeetingIntelligenceActions = .init()
    ) {
        self.session = session
        self.load = load
        self.save = save
        self.openFolder = openFolder
        self.play = play
        self.export = export
        self.copy = copy
        self.editDetails = editDetails
        self.meetingIntelligencePresentation = meetingIntelligencePresentation
        self.meetingIntelligenceActions = meetingIntelligenceActions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    playbackControls
                    MeetingIntelligenceSectionView(
                        presentation: meetingIntelligencePresentation,
                        actions: meetingIntelligenceActions
                    )
                    transcriptEditor
                    details
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 680)
        .onAppear { text = load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back")
            Text(session.displayName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button(action: editDetails) {
                Image(systemName: session.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help("Edit recording details")
            Button(action: editDetails) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit recording details")
            Button("Open Folder", action: openFolder).buttonStyle(.bordered)
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.bordered)
                .help("Copy transcript")
            Button(action: export) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.bordered)
                .help("Export transcript")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
            Text("Recording playback")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Play in separate window", action: play)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(RecorderVisualStyle.cardSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 260)
                .accessibilityIdentifier("recorder.transcript.editor")
        }
    }

    private var details: some View {
        HStack {
            Label(session.durationText, systemImage: "clock")
            Spacer()
            Label(session.fileSizeText, systemImage: "internaldrive")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") { save(text); dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(RecorderActionID.saveTranscript)
                .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.saveTranscript))
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
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
