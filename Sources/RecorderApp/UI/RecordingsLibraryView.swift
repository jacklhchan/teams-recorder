import AppKit
import SwiftUI

struct RecordingsLibraryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject private var libraryFeature: LibraryFeatureModel
    @ObservedObject private var transcriptionFeature: TranscriptionFeatureModel
    @ObservedObject private var meetingIntelligenceFeature: MeetingIntelligenceFeatureModel
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var route: RecordingsPresentationRoute = .list
    @State private var expandedSessionID: RecordingSession.ID?
    @State private var metadataSession: RecordingSession?
    @State private var sessionPendingTrash: RecordingSession?

    init(model: AppModel) {
        self.model = model
        _libraryFeature = ObservedObject(wrappedValue: model.libraryFeature)
        _transcriptionFeature = ObservedObject(
            wrappedValue: model.transcriptionFeature
        )
        _meetingIntelligenceFeature = ObservedObject(
            wrappedValue: model.meetingIntelligenceFeature
        )
    }

    var body: some View {
        let transcription = transcriptionFeature.presentation
        let query = RecordingLibraryQuery(
            text: searchText,
            favoritesOnly: favoritesOnly
        )
        let librarySnapshot = libraryFeature.snapshot
        let librarySessions = librarySnapshot.sessions
        let visibleSessions = query.filter(librarySessions)
        // Capture exactly one immutable projection for this body evaluation.
        // The UI never reconstructs meeting-intelligence state in AppModel.
        let meetingIntelligenceSnapshot = meetingIntelligenceFeature.snapshot
        let toolbarPresentation = RecordingsToolbarPresentation.make(
            isTranscribing: transcription.transcribingSessionID != nil
        )

        SessionListView(
            sessions: visibleSessions,
            allSessions: librarySessions,
            libraryRevision: librarySnapshot.revision,
            query: query,
            transcribingSessionID: transcription.transcribingSessionID,
            transcriptionStatus: transcription.transcriptionStatus,
            lastTranscriptionSessionID: transcription.lastTranscriptionSessionID,
            lastTranscriptionStatus: transcription.lastTranscriptionStatus,
            lastTranscriptionDidFail: transcription.lastTranscriptionDidFail,
            hasSavedProviderProfile: model.aiProviderSettingsModel.hasSavedProfile,
            transcriptionStatesBySessionID: transcription.transcriptionStatesBySessionID,
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
            meetingIntelligencePresentation: { session in
                meetingIntelligenceSnapshot.presentation(for: session)?.presentation ?? .empty
            },
            meetingIntelligenceObservedSnapshot: { session in
                guard let sessionPresentation = meetingIntelligenceSnapshot.presentation(for: session) else {
                    return nil
                }
                return MeetingIntelligenceObservedSnapshotAdapter.make(
                    featureRevision: meetingIntelligenceSnapshot.revision,
                    sessionPresentation: sessionPresentation,
                    canonicalSession: session,
                    titleIsProtected: session.metadata.titleOrigin == .manual
                )
            },
            checkMeetingIntelligenceAvailability: model.checkMeetingIntelligenceAvailability,
            generateMeetingIntelligence: model.generateMeetingIntelligence,
            regenerateMeetingIntelligence: model.regenerateMeetingIntelligence,
            retryMeetingIntelligenceGeneration: model.retryMeetingIntelligenceGeneration,
            cancelMeetingIntelligence: model.cancelMeetingIntelligence,
            applyMeetingIntelligenceSuggestedTitle: model.applyMeetingIntelligenceSuggestedTitle,
            saveMetadata: model.saveMetadata,
            moveToTrash: model.moveSessionToTrash,
            route: $route,
            expandedSessionID: $expandedSessionID,
            metadataSession: $metadataSession,
            sessionPendingTrash: $sessionPendingTrash,
            canonicalSessions: { libraryFeature.snapshot.sessions },
            systemColorScheme: systemColorScheme
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
        .background(RecorderVisualStyle.recordingsCanvas)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: RecorderSurfaceAppearance.recordingsDark.accessibilityIdentifier
            )
        )
        .accessibilityIdentifier("recorder.destination.recordings")
        .environment(\.colorScheme, .dark)
    }
}

private struct SessionListView: View {
    let sessions: [RecordingSession]
    let allSessions: [RecordingSession]
    let libraryRevision: UInt64
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
    let saveTranscript: (String, RecordingSession) async -> LibrarySaveOutcome
    let exportTranscript: (RecordingSession) -> Void
    let copyTranscript: (RecordingSession) -> Void
    let meetingIntelligencePresentation: (RecordingSession) -> MeetingIntelligencePresentation
    let meetingIntelligenceObservedSnapshot: (RecordingSession) -> RecorderObservedSnapshot?
    let checkMeetingIntelligenceAvailability: (RecordingSession) -> Void
    let generateMeetingIntelligence: (RecordingSession) -> Void
    let regenerateMeetingIntelligence: (RecordingSession) -> Void
    let retryMeetingIntelligenceGeneration: (RecordingSession) -> Void
    let cancelMeetingIntelligence: (RecordingSession) -> Void
    let applyMeetingIntelligenceSuggestedTitle: (RecordingSession) -> Void
    let saveMetadata: (String, String, Bool, RecordingSession) async -> LibrarySaveOutcome
    let moveToTrash: (RecordingSession) async -> Void
    @Binding var route: RecordingsPresentationRoute
    @Binding var expandedSessionID: RecordingSession.ID?
    @Binding var metadataSession: RecordingSession?
    @Binding var sessionPendingTrash: RecordingSession?
    let canonicalSessions: () -> [RecordingSession]
    let systemColorScheme: ColorScheme

    private var admission: RecordingsCanonicalActionAdmission {
        .init(currentSessions: canonicalSessions)
    }

    private func expansionBinding(for sessionID: RecordingSession.ID) -> Binding<Bool> {
        Binding(
            get: { expandedSessionID == sessionID },
            set: { expandedSessionID = $0 ? sessionID : nil }
        )
    }

    @ViewBuilder
    private func sessionActionStrip(
        session: RecordingSession,
        compact: Bool
    ) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            actionButton(
                "Play", symbol: "play.fill", marker: "play",
                accessibilityLabel: "Play \(session.displayName)",
                help: "Play recording in a separate window",
                session: session, compact: compact
            ) {
                _ = admission.perform(sessionID: session.id, action: play)
            }
            actionButton(
                "Open", symbol: "folder", marker: "open",
                accessibilityLabel: "Open \(session.displayName)",
                session: session, compact: compact
            ) {
                _ = admission.perform(sessionID: session.id, action: open)
            }
            actionButton(
                "Edit", symbol: session.isFavorite ? "star.fill" : "slider.horizontal.3",
                marker: "edit",
                accessibilityLabel: "Edit details for \(session.displayName)",
                help: "Edit recording details",
                session: session, compact: compact
            ) {
                _ = admission.perform(sessionID: session.id) { metadataSession = $0 }
            }
            actionButton(
                "Transcribe",
                symbol: transcribingSessionID == session.id ? "waveform" : "text.badge.plus",
                marker: "transcribe",
                accessibilityLabel: "Transcribe \(session.displayName)",
                help: hasSavedProviderProfile
                    ? "Transcribe with the configured AI provider"
                    : "Configure an AI provider first",
                session: session, compact: compact,
                disabled: transcribingSessionID != nil || !hasSavedProviderProfile
            ) {
                _ = admission.perform(sessionID: session.id, action: transcribe)
            }
            actionButton(
                "Transcript", symbol: "doc.text.fill", marker: "transcript",
                accessibilityLabel: "Open Transcript for \(session.displayName)",
                actionIdentifier: RecorderActionID.openTranscript,
                help: "View and edit transcript",
                session: session, compact: compact,
                disabled: !hasTranscript(for: session)
            ) {
                _ = admission.perform(sessionID: session.id) { route = .transcript($0.id) }
            }
            actionButton(
                "Trash", symbol: "trash", marker: "trash",
                accessibilityLabel: "Move \(session.displayName) to Trash",
                help: "Move recording to Trash",
                session: session, compact: compact
            ) {
                _ = admission.perform(sessionID: session.id) { sessionPendingTrash = $0 }
            }
            actionButton(
                "ASR Log", symbol: "terminal", marker: "log",
                accessibilityLabel: "Open ASR log for \(session.displayName)",
                help: "Open ASR log",
                session: session, compact: compact,
                disabled: !hasTranscriptLog(for: session)
            ) {
                _ = admission.perform(sessionID: session.id, action: openTranscriptLog)
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        symbol: String,
        marker: String,
        accessibilityLabel: String,
        actionIdentifier: String? = nil,
        help: String? = nil,
        session: RecordingSession,
        compact: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        RecordingSessionActionButton(
            title: title,
            symbol: symbol,
            identifier: actionIdentifier
                ?? "recorder.row.\(marker).\(session.id.lastPathComponent)",
            accessibilityLabel: accessibilityLabel,
            help: help,
            compact: compact,
            disabled: disabled,
            action: action
        )
        .fixedSize()
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.row.\(marker).\(session.id.lastPathComponent).marker",
                label: accessibilityLabel
            )
        )
    }

    var body: some View {
        Group {
        if let session = route.resolvedSession(in: allSessions) {
            TranscriptDetailView(
                openedSession: session, allSessions: allSessions,
                close: { route = .list },
                load: { transcriptText(session) },
                save: { text in
                    await admission.save(sessionID: session.id, artifact: .transcript) {
                        await saveTranscript(text, $0)
                    }
                },
                openFolder: { _ = admission.perform(sessionID: session.id, action: open) },
                play: { _ = admission.perform(sessionID: session.id, action: play) },
                export: { _ = admission.perform(sessionID: session.id, action: exportTranscript) },
                copy: { _ = admission.perform(sessionID: session.id, action: copyTranscript) },
                editDetails: { requested in
                    _ = admission.perform(sessionID: requested.id) { metadataSession = $0 }
                },
                meetingIntelligencePresentation: meetingIntelligencePresentation,
                meetingIntelligenceObservedSnapshot: meetingIntelligenceObservedSnapshot,
                checkMeetingIntelligenceAvailability: { requested in
                    _ = admission.perform(sessionID: requested.id, action: checkMeetingIntelligenceAvailability)
                },
                generateMeetingIntelligence: { requested in
                    _ = admission.perform(sessionID: requested.id, action: generateMeetingIntelligence)
                },
                regenerateMeetingIntelligence: { requested in
                    _ = admission.perform(sessionID: requested.id, action: regenerateMeetingIntelligence)
                },
                retryMeetingIntelligenceGeneration: { requested in
                    _ = admission.perform(sessionID: requested.id, action: retryMeetingIntelligenceGeneration)
                },
                cancelMeetingIntelligence: { requested in
                    _ = admission.perform(sessionID: requested.id, action: cancelMeetingIntelligence)
                },
                applyMeetingIntelligenceSuggestedTitle: { requested in
                    _ = admission.perform(sessionID: requested.id, action: applyMeetingIntelligenceSuggestedTitle)
                }
            )
            .environment(\.colorScheme, systemColorScheme)
        } else {
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sessions) { session in
                    RecordingSessionCardView(session: session, isExpanded: expansionBinding(for: session.id)) {
                    VStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 8) {
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
                            ViewThatFits(in: .horizontal) {
                                sessionActionStrip(session: session, compact: false)
                                sessionActionStrip(session: session, compact: true)
                            }
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
                                    Button("Cancel") {
                                        _ = admission.perform(sessionID: session.id) { canonical in
                                            guard transcribingSessionID == canonical.id else { return }
                                            cancelTranscription()
                                        }
                                    }.buttonStyle(.bordered)
                                }
                                Button { _ = admission.perform(sessionID: session.id, action: openTranscriptLog) } label: { Image(systemName: "terminal") }
                                    .buttonStyle(.bordered).help("Open ASR log")
                                    .accessibilityLabel("Open ASR log for \(session.displayName)")
                            }
                            .padding(10)
                            .background(RecorderVisualStyle.recordingsStatusSurface.color, in: RoundedRectangle(cornerRadius: 6))
                            .background(
                                RecorderDestinationAccessibilityMarker(
                                    identifier: "recorder.row.transcription-status.\(session.id.lastPathComponent)",
                                    label: statusText(for: session)
                                )
                            )
                            .background(
                                RecorderDestinationAccessibilityMarker(
                                    identifier: RecorderSurfaceAppearance.recordingsStatusDark.accessibilityIdentifier
                                )
                            )
                        }
                    }
                    }
                    }
                    }
                }
            }
        }
        }
        }
        .background(
            RecorderDestinationAccessibilityMarker(identifier: "recorder.recordings.list")
        )
        .onChange(of: libraryRevision) { _, _ in
            route.invalidateIfMissing(from: allSessions)
            if let expandedSessionID, !allSessions.contains(where: { $0.id == expandedSessionID }) {
                self.expandedSessionID = nil
            }
            if let metadataSession, !allSessions.contains(where: { $0.id == metadataSession.id }) {
                self.metadataSession = nil
            }
            if let sessionPendingTrash, !allSessions.contains(where: { $0.id == sessionPendingTrash.id }) {
                self.sessionPendingTrash = nil
            }
        }
        .sheet(item: $metadataSession) { session in
            RecordingMetadataEditorView(session: session) { title, tags, favorite in
                await admission.save(sessionID: session.id, artifact: .metadata) {
                    await saveMetadata(title, tags, favorite, $0)
                }
            }
            .id(session.id)
        }
        .confirmationDialog(
            "Move recording to Trash?",
            isPresented: Binding(get: { sessionPendingTrash != nil }, set: { if !$0 { sessionPendingTrash = nil } }),
            presenting: sessionPendingTrash
        ) { session in
            Button("Move to Trash", role: .destructive) {
                Task { _ = await admission.performAsync(sessionID: session.id, action: moveToTrash) }
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

/// Uses native controls so each recording action has a stable AppKit
/// accessibility action and geometry at both ViewThatFits alternatives.
private struct RecordingSessionActionButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let identifier: String
    let accessibilityLabel: String
    let help: String?
    let compact: Bool
    let disabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        NSButton(title: "", target: context.coordinator,
                 action: #selector(Coordinator.performAction))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = compact ? "" : title
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel
        )
        button.imagePosition = compact ? .imageOnly : .imageLeading
        button.isEnabled = !disabled
        button.toolTip = help
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func performAction() { action() }
    }
}

struct RecordingMetadataEditorView: View {
    let session: RecordingSession
    let save: (String, String, Bool) async -> LibrarySaveOutcome
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var tags = ""
    @State private var isFavorite = false
    @State private var hasLoadedDraft = false
    @StateObject private var saveState = LibraryEditorSaveState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recording Details").font(.headline)
            TextField("Title", text: $title)
                .accessibilityIdentifier(RecorderActionID.metadataTitle)
            TextField("Tags, separated by commas", text: $tags)
                .accessibilityIdentifier(RecorderActionID.metadataTags)
            Toggle("Favorite", isOn: $isFavorite)
                .accessibilityIdentifier(RecorderActionID.metadataFavorite)
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: RecorderActionID.metadataFavorite
                    )
                )
            LibraryEditorSaveFeedback(
                state: saveState.state,
                inFlightIdentifier: RecorderActionID.metadataSaveInFlight,
                errorIdentifier: RecorderActionID.metadataSaveError
            )
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
                    .accessibilityIdentifier(RecorderActionID.metadataCancel)
                LibraryEditorSaveButton(
                    identifier: RecorderActionID.saveMetadata,
                    isSaving: isSaving
                ) {
                    guard let attempt = saveState.begin(sessionID: session.id, artifact: .metadata) else {
                        return
                    }
                    let draft = (title, tags, isFavorite)
                    Task {
                        let outcome = await save(draft.0, draft.1, draft.2)
                        if saveState.complete(attempt, outcome: outcome) == .dismiss { dismiss() }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            guard !hasLoadedDraft else { return }
            title = session.metadata.title ?? ""
            tags = session.tags.joined(separator: ", ")
            isFavorite = session.isFavorite
            hasLoadedDraft = true
        }
        .onDisappear { saveState.invalidate() }
    }

    private var isSaving: Bool {
        saveState.state == .saving
    }
}

struct LibraryEditorSaveButton: View {
    let identifier: String
    let isSaving: Bool
    let action: () -> Void

    var body: some View {
        NativeLibraryEditorSaveButton(
            identifier: identifier,
            isEnabled: !isSaving,
            action: action
        )
        .frame(minWidth: 72, minHeight: 28)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: identifier + ".marker",
                label: "Save"
            )
        )
    }
}

private struct NativeLibraryEditorSaveButton: NSViewRepresentable {
    let identifier: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "Save",
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .rounded
        button.bezelColor = .controlAccentColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel("Save")
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func performAction() { action() }
    }
}

struct LibraryEditorSaveFeedback: View {
    let state: LibraryEditorSaveStateValue
    let inFlightIdentifier: String
    let errorIdentifier: String

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .saving:
            Text("Saving…")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(inFlightIdentifier)
                .background(RecorderDestinationAccessibilityMarker(identifier: inFlightIdentifier))
        case let .failed(failure):
            Text(failure.userMessage)
                .foregroundStyle(.red)
                .accessibilityIdentifier(errorIdentifier)
                .accessibilityLabel(failure.userMessage)
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: errorIdentifier,
                        label: failure.userMessage
                    )
                )
        }
    }
}
