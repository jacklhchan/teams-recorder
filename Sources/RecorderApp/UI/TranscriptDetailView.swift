import SwiftUI

/// Stateless content for the transcript sheet. The sheet item remains the
/// stable opened session, while every render resolves presentation and command
/// routing from the latest library projection for that recording ID.
struct TranscriptDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    let openedSession: RecordingSession
    let allSessions: [RecordingSession]
    let close: () -> Void
    let load: () -> String
    let save: (String) async -> LibrarySaveOutcome
    let openFolder: () -> Void
    let play: () -> Void
    let export: () -> Void
    let copy: () -> Void
    let editDetails: (RecordingSession) -> Void
    let meetingIntelligencePresentation: (RecordingSession) -> MeetingIntelligencePresentation
    let meetingIntelligenceObservedSnapshot: (RecordingSession) -> RecorderObservedSnapshot?
    let checkMeetingIntelligenceAvailability: (RecordingSession) -> Void
    let generateMeetingIntelligence: (RecordingSession) -> Void
    let regenerateMeetingIntelligence: (RecordingSession) -> Void
    let retryMeetingIntelligenceGeneration: (RecordingSession) -> Void
    let cancelMeetingIntelligence: (RecordingSession) -> Void
    let applyMeetingIntelligenceSuggestedTitle: (RecordingSession) -> Void

    var body: some View {
        let palette = TranscriptDetailPalette(colorScheme: colorScheme)
        let appearance = RecorderVisualStyle.transcriptAppearance(for: colorScheme)
        let currentSession = TranscriptDetailActionProjection.current(
            opened: openedSession,
            allSessions: allSessions
        )
        let actions = TranscriptDetailActionProjection.meetingIntelligenceActions(
            for: currentSession,
            checkAgain: checkMeetingIntelligenceAvailability,
            generate: generateMeetingIntelligence,
            regenerate: regenerateMeetingIntelligence,
            retryGeneration: retryMeetingIntelligenceGeneration,
            cancel: cancelMeetingIntelligence,
            applySuggestedTitle: applyMeetingIntelligenceSuggestedTitle
        )
        let effectivePresentation = TranscriptDetailActionProjection.effectiveMeetingIntelligencePresentation(
            meetingIntelligencePresentation(currentSession),
            canonicalSession: currentSession
        )

        return TranscriptEditorView(
            session: openedSession,
            resolvedSession: currentSession,
            close: close,
            load: load,
            save: save,
            openFolder: openFolder,
            play: play,
            export: export,
            copy: copy,
            editDetails: editDetails,
            meetingIntelligencePresentation: { _ in effectivePresentation },
            meetingIntelligenceObservedSnapshot: meetingIntelligenceObservedSnapshot,
            meetingIntelligenceActions: { _ in actions },
            palette: palette
        )
        .id(openedSession.id)
        .background(palette.canvas)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: appearance.accessibilityIdentifier
            )
        )
    }
}

/// Opaque, system-appearance-derived colors for the transcript detail. This
/// is a presentation value, passed from the detail boundary to its sections;
/// it is not a user preference or a second source of state.
struct TranscriptDetailPalette {
    let canvas: Color
    let card: Color
    let editor: Color
    let text: Color
    let secondary: Color
    let hairline: Color

    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            canvas = RecorderVisualStyle.transcriptDarkCanvas
            card = RecorderVisualStyle.transcriptDarkCard
            editor = RecorderVisualStyle.transcriptDarkEditor
            text = RecorderVisualStyle.transcriptDarkText
            secondary = RecorderVisualStyle.transcriptDarkSecondary
            hairline = RecorderVisualStyle.transcriptDarkHairline
        default:
            canvas = RecorderVisualStyle.transcriptLightCanvas
            card = RecorderVisualStyle.transcriptLightCard
            editor = RecorderVisualStyle.transcriptLightEditor
            text = RecorderVisualStyle.transcriptLightText
            secondary = RecorderVisualStyle.transcriptLightSecondary
            hairline = RecorderVisualStyle.transcriptLightHairline
        }
    }

    static let light = TranscriptDetailPalette(colorScheme: .light)
}
enum TranscriptEditorDraft {
    /// The sheet owns its in-progress text. A model publication may rerender
    /// the surrounding view but must not replace that text while still open.
    static func loadedText(existing: String, hasLoaded: Bool, load: () -> String) -> String {
        hasLoaded ? existing : load()
    }
}

enum TranscriptDetailActionProjection {
    static func effectiveMeetingIntelligencePresentation(
        _ presentation: MeetingIntelligencePresentation,
        canonicalSession: RecordingSession
    ) -> MeetingIntelligencePresentation {
        .init(
            phase: presentation.phase,
            summary: presentation.summary,
            suggestedTitle: presentation.suggestedTitle,
            statusMessage: presentation.statusMessage,
            model: presentation.model,
            titleIsProtected: canonicalSession.metadata.titleOrigin == .manual,
            unavailableReason: presentation.unavailableReason
        )
    }

    static func current(
        opened: RecordingSession,
        allSessions: [RecordingSession]
    ) -> RecordingSession {
        current(
            opened: opened,
            resolved: allSessions.first(where: { $0.id == opened.id })
        )
    }

    static func current(
        opened: RecordingSession,
        resolved: RecordingSession?
    ) -> RecordingSession {
        resolved ?? opened
    }

    static func meetingIntelligenceActions(
        for session: RecordingSession,
        checkAgain: @escaping (RecordingSession) -> Void,
        generate: @escaping (RecordingSession) -> Void,
        regenerate: @escaping (RecordingSession) -> Void,
        retryGeneration: @escaping (RecordingSession) -> Void,
        cancel: @escaping (RecordingSession) -> Void,
        applySuggestedTitle: @escaping (RecordingSession) -> Void
    ) -> MeetingIntelligenceActions {
        .init(
            generate: { generate(session) },
            regenerate: { regenerate(session) },
            checkAgain: { checkAgain(session) },
            retryGeneration: { retryGeneration(session) },
            cancel: { cancel(session) },
            applySuggestedTitle: { applySuggestedTitle(session) }
        )
    }
}

struct TranscriptEditorView: View {
    let session: RecordingSession
    /// The list projection may be refreshed while this sheet is open (for
    /// example after applying a generated title). Keep the stable session ID
    /// and the editor draft, but render the current metadata projection.
    let resolvedSession: RecordingSession?
    let load: () -> String
    let save: (String) async -> LibrarySaveOutcome
    let openFolder: () -> Void
    /// Requests playback through the existing external presenter. This sheet
    /// never owns the playback view or player lifetime.
    let play: () -> Void
    let export: () -> Void
    let copy: () -> Void
    let editDetails: (RecordingSession) -> Void
    private let close: (() -> Void)?
    private let meetingIntelligencePresentationForSession: (RecordingSession) -> MeetingIntelligencePresentation
    private let meetingIntelligenceObservedSnapshotForSession: (RecordingSession) -> RecorderObservedSnapshot?
    private let meetingIntelligenceActionsForSession: (RecordingSession) -> MeetingIntelligenceActions
    private let palette: TranscriptDetailPalette
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hasLoadedDraft = false
    @StateObject private var saveState = LibraryEditorSaveState()

    init(
        session: RecordingSession,
        resolvedSession: RecordingSession? = nil,
        close: (() -> Void)? = nil,
        load: @escaping () -> String,
        save: @escaping (String) -> Void,
        openFolder: @escaping () -> Void = {},
        play: @escaping () -> Void = {},
        export: @escaping () -> Void,
        copy: @escaping () -> Void,
        editDetails: @escaping (RecordingSession) -> Void = { _ in },
        meetingIntelligencePresentation: MeetingIntelligencePresentation = .empty,
        meetingIntelligenceObservedSnapshot: RecorderObservedSnapshot? = nil,
        meetingIntelligenceActions: MeetingIntelligenceActions = .init(),
        palette: TranscriptDetailPalette = .light
    ) {
        self.session = session
        self.resolvedSession = resolvedSession
        self.close = close
        self.load = load
        self.save = { text in
            save(text)
            return .saved(sessionID: session.id, .transcript)
        }
        self.openFolder = openFolder
        self.play = play
        self.export = export
        self.copy = copy
        self.editDetails = editDetails
        meetingIntelligencePresentationForSession = { _ in meetingIntelligencePresentation }
        meetingIntelligenceObservedSnapshotForSession = { _ in meetingIntelligenceObservedSnapshot }
        meetingIntelligenceActionsForSession = { _ in meetingIntelligenceActions }
        self.palette = palette
    }

    init(
        session: RecordingSession,
        resolvedSession: RecordingSession? = nil,
        close: (() -> Void)? = nil,
        load: @escaping () -> String,
        save: @escaping (String) async -> LibrarySaveOutcome,
        openFolder: @escaping () -> Void = {},
        play: @escaping () -> Void = {},
        export: @escaping () -> Void,
        copy: @escaping () -> Void,
        editDetails: @escaping (RecordingSession) -> Void = { _ in },
        meetingIntelligencePresentation: @escaping (RecordingSession) -> MeetingIntelligencePresentation,
        meetingIntelligenceObservedSnapshot: @escaping (RecordingSession) -> RecorderObservedSnapshot? = { _ in nil },
        meetingIntelligenceActions: @escaping (RecordingSession) -> MeetingIntelligenceActions,
        palette: TranscriptDetailPalette = .light
    ) {
        self.session = session
        self.resolvedSession = resolvedSession
        self.close = close
        self.load = load
        self.save = save
        self.openFolder = openFolder
        self.play = play
        self.export = export
        self.copy = copy
        self.editDetails = editDetails
        meetingIntelligencePresentationForSession = meetingIntelligencePresentation
        meetingIntelligenceObservedSnapshotForSession = meetingIntelligenceObservedSnapshot
        meetingIntelligenceActionsForSession = meetingIntelligenceActions
        self.palette = palette
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    playbackControls
                    MeetingIntelligenceSectionView(
                        presentation: meetingIntelligencePresentationForSession(displayedSession),
                        observedSnapshot: meetingIntelligenceObservedSnapshotForSession(displayedSession),
                        actions: meetingIntelligenceActionsForSession(displayedSession),
                        palette: palette
                    )
                    transcriptEditor
                    details
                }
                .padding(20)
            }
            .background(palette.canvas)
            Divider().overlay(palette.hairline)
            footer
        }
        .frame(
            minWidth: 860,
            idealWidth: 1_000,
            maxWidth: .infinity,
            minHeight: 680,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .foregroundStyle(palette.text)
        .background(palette.canvas)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.transcript.detail.root"
            )
        )
        .onAppear {
            text = TranscriptEditorDraft.loadedText(
                existing: text,
                hasLoaded: hasLoadedDraft,
                load: load
            )
            hasLoadedDraft = true
        }
        .onDisappear { saveState.invalidate() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: closeDetail) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back")
            .disabled(isSaving)
            .accessibilityIdentifier(RecorderActionID.transcriptBack)
            Text(displayedSession.displayName)
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier(RecorderActionID.transcriptDetailTitle)
                .accessibilityLabel(displayedSession.displayName)
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: RecorderActionID.transcriptDetailTitle,
                        label: displayedSession.displayName
                    )
                )
            Spacer()
            Button { editDetails(displayedSession) } label: {
                Image(systemName: displayedSession.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help("Edit recording details")
            .accessibilityIdentifier(RecorderActionID.transcriptDetailFavorite)
            .accessibilityValue(displayedSession.isFavorite ? "favorite" : "not-favorite")
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: RecorderActionID.transcriptDetailFavorite,
                    label: displayedSession.isFavorite ? "favorite" : "not-favorite"
                )
            )
            Button { editDetails(displayedSession) } label: { Image(systemName: "pencil") }
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
        .background(palette.card)
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
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.hairline))
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(palette.editor, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.hairline))
                .accessibilityIdentifier("recorder.transcript.editor")
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: "recorder.transcript.editor.marker"
                    )
                )
        }
    }

    private var details: some View {
        HStack {
            Label(displayedSession.durationText, systemImage: "clock")
            Spacer()
            Label(displayedSession.fileSizeText, systemImage: "internaldrive")
        }
        .font(.caption)
        .foregroundStyle(palette.secondary)
        .padding(.vertical, 4)
    }

    private var displayedSession: RecordingSession {
        TranscriptDetailActionProjection.current(
            opened: session,
            resolved: resolvedSession
        )
    }

    private var footer: some View {
        HStack {
            LibraryEditorSaveFeedback(
                state: saveState.state,
                inFlightIdentifier: RecorderActionID.transcriptSaveInFlight,
                errorIdentifier: RecorderActionID.transcriptSaveError
            )
            Spacer()
            Button("Cancel", action: closeDetail)
                .disabled(isSaving)
                .accessibilityIdentifier(RecorderActionID.transcriptCancel)
            LibraryEditorSaveButton(
                identifier: RecorderActionID.saveTranscript,
                isSaving: isSaving
            ) {
                guard let attempt = saveState.begin(sessionID: session.id, artifact: .transcript) else {
                    return
                }
                let draft = text
                Task {
                    let outcome = await save(draft)
                    if saveState.complete(attempt, outcome: outcome) == .dismiss { closeDetail() }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(palette.card)
    }

    private var isSaving: Bool {
        saveState.state == .saving
    }

    private func closeDetail() {
        if let close { close() } else { dismiss() }
    }
}
