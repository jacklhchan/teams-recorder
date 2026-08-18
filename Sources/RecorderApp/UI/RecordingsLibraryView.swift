import AppKit
import SwiftUI

struct RecordingsLibraryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject private var libraryFeature: LibraryFeatureModel
    @ObservedObject private var transcriptionFeature: TranscriptionFeatureModel
    @ObservedObject private var meetingIntelligenceFeature: MeetingIntelligenceFeatureModel
    @State private var searchText = ""
    @State private var libraryFilter: RecordingLibraryFilter = .all
    @State private var librarySort: RecordingLibrarySort = .newestFirst
    @State private var route: RecordingsPresentationRoute = .list
    @State private var selectedSessionID: RecordingSession.ID?
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
        let query = RecordingLibraryQuery(text: searchText)
        let librarySnapshot = libraryFeature.snapshot
        let librarySessions = librarySnapshot.sessions
        // Capture exactly one immutable projection for this body evaluation.
        // The UI never reconstructs meeting-intelligence state in AppModel.
        let meetingIntelligenceSnapshot = meetingIntelligenceFeature.snapshot
        let toolbarPresentation = RecordingsToolbarPresentation.make(
            isTranscribing: transcription.transcribingSessionID != nil
        )
        let palette = RecordingsPalette(colorScheme: systemColorScheme)
        let presentation = RecordingsLibraryPresentation.make(
            sessions: librarySessions,
            query: query,
            filter: libraryFilter,
            sort: librarySort,
            now: Date(),
            calendar: .current,
            hasTranscript: {
                TranscriptDocumentStore.resolvedURL(in: $0.folderURL) != nil
            },
            transcriptionPhase: {
                transcription.transcriptionStatesBySessionID[$0.id]?.phase
            }
        )

        SessionListView(
            palette: palette,
            presentation: presentation,
            allSessions: librarySessions,
            outputFolder: model.outputFolder,
            libraryRevision: librarySnapshot.revision,
            query: query,
            transcribingSessionID: transcription.transcribingSessionID,
            transcriptionStatus: transcription.transcriptionStatus,
            lastTranscriptionSessionID: transcription.lastTranscriptionSessionID,
            lastTranscriptionStatus: transcription.lastTranscriptionStatus,
            lastTranscriptionDidFail: transcription.lastTranscriptionDidFail,
            hasSavedProviderProfile: model.aiProviderSettingsModel.hasSavedProfile,
            currentHasSavedProviderProfile: {
                model.aiProviderSettingsModel.hasSavedProfile
            },
            currentTranscribingSessionID: {
                transcriptionFeature.presentation.transcribingSessionID
            },
            transcriptionStatesBySessionID: transcription.transcriptionStatesBySessionID,
            play: model.play,
            open: model.open,
            revealRecording: model.revealRecording,
            transcribe: { sessionID, options in
                model.transcribe(sessionID: sessionID, options: options)
            },
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
            saveMeetingIntelligenceEdit: model.saveMeetingIntelligenceEdit,
            saveMetadata: model.saveMetadata,
            moveToTrash: model.moveSessionToTrash,
            transcriptionDraft: $model.transcriptionRequestDraft,
            route: $route,
            selectedSessionID: $selectedSessionID,
            libraryFilter: $libraryFilter,
            librarySort: $librarySort,
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
        }
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.destination.recordings"
            )
        )
        .background(palette.canvas)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: palette.appearance.accessibilityIdentifier
            )
        )
        .accessibilityIdentifier("recorder.destination.recordings")
        .sheet(item: $model.transcriptionRequestDraft) { draft in
            TranscriptionRequestSheet(
                draft: draft,
                cancel: model.cancelTranscriptionRequest,
                submit: { options in
                    model.submitTranscriptionRequest(options: options)
                }
            )
        }
    }
}

private struct SessionListView: View {
    let palette: RecordingsPalette
    let presentation: RecordingsLibraryPresentation
    let allSessions: [RecordingSession]
    let outputFolder: URL
    let libraryRevision: UInt64
    let query: RecordingLibraryQuery
    let transcribingSessionID: RecordingSession.ID?
    let transcriptionStatus: String
    let lastTranscriptionSessionID: RecordingSession.ID?
    let lastTranscriptionStatus: String
    let lastTranscriptionDidFail: Bool
    let hasSavedProviderProfile: Bool
    let currentHasSavedProviderProfile: () -> Bool
    let currentTranscribingSessionID: () -> RecordingSession.ID?
    let transcriptionStatesBySessionID: [RecordingSession.ID: TranscriptionState]
    let play: (RecordingSession) -> Void
    let open: (RecordingSession) -> Void
    let revealRecording: (RecordingSession) -> Void
    let transcribe: (RecordingSession.ID, TranscriptionRequestOptions) -> Void
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
    let saveMeetingIntelligenceEdit: (
        RecordingSession,
        MeetingIntelligenceArtifact,
        TranscriptDocumentRevision,
        String,
        String
    ) async -> MeetingIntelligenceEditSaveOutcome
    let saveMetadata: (String, String, Bool, RecordingSession) async -> LibrarySaveOutcome
    let moveToTrash: (RecordingSession) async -> Void
    @Binding var transcriptionDraft: TranscriptionRequestDraft?
    @Binding var route: RecordingsPresentationRoute
    @Binding var selectedSessionID: RecordingSession.ID?
    @Binding var libraryFilter: RecordingLibraryFilter
    @Binding var librarySort: RecordingLibrarySort
    @Binding var metadataSession: RecordingSession?
    @Binding var sessionPendingTrash: RecordingSession?
    let canonicalSessions: () -> [RecordingSession]
    let systemColorScheme: ColorScheme

    private var admission: RecordingsCanonicalActionAdmission {
        .init(currentSessions: canonicalSessions)
    }

    private var locationActions: RecordingsSessionLocationActions {
        .init(
            currentSessions: canonicalSessions,
            openFolder: open,
            revealRecording: revealRecording
        )
    }

    private enum AvailableArtifact {
        case transcript
        case transcriptLog
    }

    private func performAvailableArtifactAction(
        _ artifact: AvailableArtifact,
        sessionID: RecordingSession.ID,
        action: (RecordingSession) -> Void
    ) {
        _ = admission.perform(sessionID: sessionID) { canonical in
            let resolvedURL: URL? = switch artifact {
            case .transcript:
                TranscriptDocumentStore.resolvedURL(in: canonical.folderURL)
            case .transcriptLog:
                TranscriptDocumentStore.logURL(in: canonical.folderURL)
            }
            guard resolvedURL != nil else { return }
            action(canonical)
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

    private var librarySummaryHeader: some View {
        HStack(spacing: 10) {
            Text(presentation.itemCountText)
                .font(.headline)
            Text(presentation.totalDurationText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.card)
        .accessibilityIdentifier("recorder.library.summary")
    }

    private var filterAndSortBar: some View {
        HStack(spacing: 6) {
            filterButton(.all, title: "All", identifier: "all")
            filterButton(
                .favorites,
                title: "Favorites",
                identifier: "favorites",
                actionIdentifier: RecorderActionID.filterFavorites
            )
            filterButton(
                .hasTranscript,
                title: "Has transcript",
                identifier: "has-transcript"
            )
            filterButton(
                .needsAttention,
                title: "Needs attention",
                identifier: "needs-attention"
            )
            Spacer(minLength: 8)
            Menu {
                Button("Newest first") { librarySort = .newestFirst }
                Button("Oldest first") { librarySort = .oldestFirst }
            } label: {
                Label(sortTitle, systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("recorder.library.sort")
            .accessibilityLabel("Sort recordings")
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.library.sort",
                    label: "Sort recordings"
                )
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.card.opacity(0.7))
    }

    private func filterButton(
        _ filter: RecordingLibraryFilter,
        title: String,
        identifier: String,
        actionIdentifier: String? = nil
    ) -> some View {
        Button(title) { libraryFilter = filter }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                libraryFilter == filter
                    ? RecorderVisualStyle.actionBlue.opacity(0.22)
                    : Color.clear,
                in: Capsule()
            )
            .overlay(Capsule().stroke(palette.hairline))
            .accessibilityIdentifier(
                actionIdentifier ?? "recorder.library.filter.\(identifier)"
            )
            .accessibilityValue(libraryFilter == filter ? "Selected" : "Not selected")
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.library.filter.\(identifier)",
                    label: title
                )
            )
    }

    private var sortTitle: String {
        librarySort == .newestFirst ? "Newest first" : "Oldest first"
    }

    @ViewBuilder
    private func compactLibraryList() -> some View {
        VStack(spacing: 0) {
            librarySummaryHeader
            filterAndSortBar
            if presentation.sections.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "list.bullet.rectangle",
                    description: Text(
                        "No recordings match the current folder and filters."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(presentation.sections) { section in
                            Text(section.title)
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .background(
                                    RecorderDestinationAccessibilityMarker(
                                        identifier: "recorder.library.section.\(section.id)"
                                    )
                                )
                            ForEach(section.sessions) { session in
                                recordingRow(session: session)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            libraryFooter
        }
    }

    private var libraryFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            Text(outputFolder.path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(presentation.itemCountText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.card)
        .accessibilityIdentifier("recorder.library.footer")
    }

    @ViewBuilder
    private func recordingRow(session: RecordingSession) -> some View {
        let rowID = session.id.lastPathComponent
        let selected = selectedSessionID == session.id
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.status)
                        Image(systemName: mediaSymbol(for: session))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 54, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if session.isFavorite {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .accessibilityLabel("Favorite")
                            }
                            Text(session.displayName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                        }
                        Text(
                            "\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.durationText) · \(session.fileSizeText)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        HStack(spacing: 5) {
                            chip(sourceTitle(for: session))
                            chip(mediaTitle(for: session))
                            if session.recoveryState != .none {
                                chip("Needs attention")
                            }
                            if !session.tags.isEmpty {
                                Text(session.tags.map { "#\($0)" }.joined(separator: "  "))
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                                    .lineLimit(1)
                            }
                        }
                        if let snippet = query.transcriptSnippet(for: session) {
                            Text(snippet)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RecordingSessionSelectionButton(
                        identifier: "recorder.row.card.\(rowID)",
                        accessibilityLabel: "Select \(session.displayName)",
                        selected: selected
                    ) {
                        _ = admission.perform(sessionID: session.id) {
                            selectedSessionID = $0.id
                        }
                    }
                )
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.row.\(session.mediaKind == .video ? "video" : "audio").\(rowID)",
                        label: session.displayName
                    )
                )

                actionButton(
                    "Play",
                    symbol: "play.fill",
                    marker: "play",
                    accessibilityLabel: "Play \(session.displayName)",
                    help: "Play recording in a separate window",
                    session: session,
                    compact: true
                ) {
                    _ = admission.perform(sessionID: session.id, action: play)
                }

                recordingActionsMenu(session: session)
            }

            if selected {
                HStack(spacing: 8) {
                    Spacer()
                    if hasTranscript(for: session) {
                        actionButton(
                            "Open Transcript",
                            symbol: "doc.text.fill",
                            marker: "transcript",
                            accessibilityLabel: "Open Transcript for \(session.displayName)",
                            actionIdentifier: RecorderActionID.openTranscript,
                            help: "View and edit transcript",
                            session: session,
                            compact: false
                        ) {
                            performAvailableArtifactAction(
                                .transcript,
                                sessionID: session.id
                            ) {
                                route = .transcript($0.id)
                            }
                        }
                        .background(
                            RecorderDestinationAccessibilityMarker(
                                identifier: RecorderActionID.openTranscript,
                                label: "Open Transcript for \(session.displayName)"
                            )
                        )
                    }
                    actionButton(
                        "Show in Finder",
                        symbol: "folder",
                        marker: "open",
                        accessibilityLabel: "Open \(session.displayName)",
                        help: "Show recording in Finder",
                        session: session,
                        compact: false
                    ) {
                        _ = locationActions.perform(
                            .revealRecording,
                            sessionID: session.id
                        )
                    }
                }
            }

            transcriptionStatusRow(session: session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? RecorderVisualStyle.actionBlue.opacity(0.14) : Color.clear)
        .background(
            selected
                ? RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.row.selected.\(rowID)",
                    label: "Selected \(session.displayName)"
                )
                : nil
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.hairline).frame(height: 1)
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(palette.status, in: Capsule())
    }

    private func recordingActionsMenu(session: RecordingSession) -> some View {
        let rowID = session.id.lastPathComponent
        var items: [RecordingSessionMenuButton.Item] = [
            .init(title: "Open Folder", identifier: "recorder.row.open.\(rowID).menu") {
                _ = locationActions.perform(.openFolder, sessionID: session.id)
            },
            .init(title: "Edit Details", identifier: "recorder.row.edit.\(rowID)") {
                _ = admission.perform(sessionID: session.id) { metadataSession = $0 }
            }
        ]
        if transcribingSessionID == session.id {
            items.append(
                .init(
                    title: "Cancel Transcription",
                    identifier: "recorder.row.transcription-cancel.\(rowID)"
                ) {
                    _ = admission.perform(sessionID: session.id) { canonical in
                        guard currentTranscribingSessionID() == canonical.id else {
                            return
                        }
                        cancelTranscription()
                    }
                }
            )
        } else {
            items.append(
                .init(
                    title: "Transcribe",
                    identifier: "recorder.row.transcribe.\(rowID)",
                    enabled: transcribingSessionID == nil && hasSavedProviderProfile
                ) {
                    _ = admission.perform(sessionID: session.id) { canonical in
                        guard currentHasSavedProviderProfile(),
                              currentTranscribingSessionID() == nil else {
                            return
                        }
                        transcriptionDraft = .init(
                            sessionID: canonical.id,
                            sessionName: canonical.displayName
                        )
                    }
                }
            )
        }
        items.append(contentsOf: [
            .init(
                title: "Open Transcript",
                identifier: "recorder.row.transcript.\(rowID).menu",
                enabled: hasTranscript(for: session)
            ) {
                performAvailableArtifactAction(
                    .transcript,
                    sessionID: session.id
                ) {
                    route = .transcript($0.id)
                }
            },
            .init(
                title: "Open ASR Log",
                identifier: "recorder.row.log.\(rowID)",
                enabled: hasTranscriptLog(for: session)
            ) {
                performAvailableArtifactAction(
                    .transcriptLog,
                    sessionID: session.id,
                    action: openTranscriptLog
                )
            },
            .separator,
            .init(
                title: "Move to Trash",
                identifier: "recorder.row.trash.\(rowID)"
            ) {
                _ = admission.perform(sessionID: session.id) {
                    sessionPendingTrash = $0
                }
            }
        ])
        return RecordingSessionMenuButton(
            identifier: "recorder.row.more.\(rowID)",
            accessibilityLabel: "More Actions for \(session.displayName)",
            items: items
        )
        .frame(width: 28, height: 24)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.row.more.\(rowID).marker",
                label: "More Actions for \(session.displayName)"
            )
        )
    }

    @ViewBuilder
    private func transcriptionStatusRow(session: RecordingSession) -> some View {
        if transcribingSessionID == session.id
            || lastTranscriptionSessionID == session.id
            || transcriptionStatesBySessionID[session.id] != nil {
            HStack(spacing: 7) {
                if transcribingSessionID == session.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusIcon(for: session))
                        .foregroundStyle(statusColor(for: session))
                }
                Text(statusText(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.status, in: RoundedRectangle(cornerRadius: 5))
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: "recorder.row.transcription-status.\(session.id.lastPathComponent)"
                )
            )
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: palette.statusAppearance.accessibilityIdentifier
                )
            )
        }
    }

    private func mediaSymbol(for session: RecordingSession) -> String {
        session.mediaKind == .video ? "video.fill" : "waveform"
    }

    private func mediaTitle(for session: RecordingSession) -> String {
        session.mediaKind == .video ? "Video" : "Audio only"
    }

    private func sourceTitle(for session: RecordingSession) -> String {
        switch session.metadata.source {
        case .teamsAutomatic: "Teams"
        case .manual: "Manual"
        case .imported: "Imported"
        }
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
                },
                saveMeetingIntelligenceEdit: { requested, artifact, transcriptRevision, summary, suggestedTitle in
                    await RecordingsLibraryMeetingIntelligenceRouting.saveEdit(
                        requestedSession: requested,
                        admission: admission,
                        capturedArtifact: artifact,
                        capturedTranscriptRevision: transcriptRevision,
                        summary: summary,
                        suggestedTitle: suggestedTitle,
                        save: saveMeetingIntelligenceEdit
                    )
                }
            )
            .environment(\.colorScheme, systemColorScheme)
        } else {
            compactLibraryList()
        }
        }
        .background(
            RecorderDestinationAccessibilityMarker(identifier: "recorder.recordings.list")
        )
        .onChange(of: libraryRevision) { _, _ in
            route.invalidateIfMissing(from: allSessions)
            if let selectedSessionID, !allSessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
            }
            if let metadataSession, !allSessions.contains(where: { $0.id == metadataSession.id }) {
                self.metadataSession = nil
            }
            if let sessionPendingTrash, !allSessions.contains(where: { $0.id == sessionPendingTrash.id }) {
                self.sessionPendingTrash = nil
            }
            if let transcriptionDraft,
               !allSessions.contains(where: { $0.id == transcriptionDraft.sessionID }) {
                self.transcriptionDraft = nil
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

@MainActor
enum RecordingsLibraryMeetingIntelligenceRouting {
    static func saveEdit(
        requestedSession: RecordingSession,
        admission: RecordingsCanonicalActionAdmission,
        capturedArtifact: MeetingIntelligenceArtifact,
        capturedTranscriptRevision: TranscriptDocumentRevision,
        summary: String,
        suggestedTitle: String,
        save: (
            RecordingSession,
            MeetingIntelligenceArtifact,
            TranscriptDocumentRevision,
            String,
            String
        ) async -> MeetingIntelligenceEditSaveOutcome
    ) async -> MeetingIntelligenceEditSaveOutcome {
        guard let canonicalSession = admission.canonicalSession(for: requestedSession.id) else {
            return .conflict("The recording is no longer available.")
        }
        return await save(
            canonicalSession,
            capturedArtifact,
            capturedTranscriptRevision,
            summary,
            suggestedTitle
        )
    }
}

/// Uses native controls so each recording action has a stable AppKit
/// accessibility action and geometry at both ViewThatFits alternatives.
private struct RecordingSessionActionButton: NSViewRepresentable {
    let title: String
    let symbol: String?
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
        button.image = symbol.flatMap {
            NSImage(
                systemSymbolName: $0,
                accessibilityDescription: accessibilityLabel
            )
        }
        button.imagePosition = symbol == nil
            ? .noImage
            : (compact ? .imageOnly : .imageLeading)
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

private struct RecordingSessionSelectionButton: NSViewRepresentable {
    let identifier: String
    let accessibilityLabel: String
    let selected: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.isBordered = false
        button.imagePosition = .noImage
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(selected ? "Selected" : "Not selected")
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func performAction() { action() }
    }
}

private struct RecordingSessionMenuButton: NSViewRepresentable {
    struct Item {
        let title: String
        let identifier: String
        let enabled: Bool
        let isSeparator: Bool
        let action: () -> Void

        init(
            title: String,
            identifier: String,
            enabled: Bool = true,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.identifier = identifier
            self.enabled = enabled
            isSeparator = false
            self.action = action
        }

        private init(isSeparator: Bool) {
            title = ""
            identifier = ""
            enabled = false
            self.isSeparator = isSeparator
            action = {}
        }

        static let separator = Item(isSeparator: true)
    }

    let identifier: String
    let accessibilityLabel: String
    let items: [Item]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: accessibilityLabel
        )
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(Coordinator.performAction(_:)),
                keyEquivalent: ""
            )
            menuItem.target = context.coordinator
            menuItem.representedObject = ActionToken(action: item.action)
            menuItem.isEnabled = item.enabled
            menuItem.setAccessibilityIdentifier(item.identifier)
            menu.addItem(menuItem)
        }
        context.coordinator.menu = menu
        button.menu = menu
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = "More Actions"
    }

    private final class ActionToken: NSObject {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }
    }

    final class Coordinator: NSObject {
        var menu = NSMenu()

        @objc func showMenu(_ sender: NSButton) {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY),
                in: sender
            )
        }

        @objc func performAction(_ sender: NSMenuItem) {
            guard let token = sender.representedObject as? ActionToken else {
                return
            }
            token.action()
        }
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
