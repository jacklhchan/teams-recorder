import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class MeetingIntelligenceSheetRenderTests: XCTestCase {
    func testTranscriptDetailSourceDoesNotDeclareEmbeddedPlaybackViews() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/RecorderApp/UI/RecordingsLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("AVPlayerView"))
        XCTAssertFalse(source.contains("RecordingPlaybackView"))
    }

    func test860By680SheetRendersMeetingIntelligenceAndNeverEmbedsPlaybackView() throws {
        let host = try SheetRenderHost(size: .init(width: 860, height: 680)) {
            TranscriptEditorView(
                session: self.session(),
                load: { "Draft transcript" },
                save: { _ in },
                export: {},
                copy: {},
                meetingIntelligencePresentation: .init(
                    phase: .ready,
                    summary: "A concise meeting summary.",
                    suggestedTitle: "Atlas planning",
                    statusMessage: "Ready.",
                    model: "test-model",
                    titleIsProtected: true,
                    unavailableReason: nil
                )
            )
        }
        defer { host.close() }

        for identifier in [
            RecorderActionID.meetingIntelligenceCard,
            RecorderActionID.meetingIntelligenceStatus,
            RecorderActionID.meetingIntelligenceSummary,
            RecorderActionID.meetingIntelligenceSuggestedTitle,
            RecorderActionID.meetingIntelligenceApplyTitle,
            RecorderActionID.meetingIntelligenceManualTitleProtection,
            RecorderActionID.saveTranscript
        ] {
            XCTAssertTrue(host.contains(identifier), "Missing rendered marker: \(identifier)")
            XCTAssertTrue(
                host.windowContentRect.contains(try XCTUnwrap(host.frame(for: identifier))),
                "\(identifier) must remain visible in an 860×680 transcript detail window."
            )
        }
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
    }

    func testWideSheetKeepsSectionAndFooterReachableAfterReopen() throws {
        let makeView = {
            TranscriptEditorView(
                session: self.session(), load: { "Draft" }, save: { _ in },
                export: {}, copy: {}
            )
        }
        let first = try SheetRenderHost(size: .init(width: 1_280, height: 800), root: makeView())
        XCTAssertTrue(first.contains(RecorderActionID.saveTranscript))
        first.close()

        let reopened = try SheetRenderHost(size: .init(width: 1_280, height: 800), root: makeView())
        defer { reopened.close() }
        XCTAssertGreaterThan(
            try XCTUnwrap(reopened.frame(for: "recorder.transcript.detail.root")).width,
            860,
            "Wide host must expand the transcript detail beyond its 860-point minimum."
        )
        XCTAssertTrue(reopened.contains(RecorderActionID.meetingIntelligenceCard))
        XCTAssertTrue(reopened.contains(RecorderActionID.saveTranscript))
        for identifier in [
            RecorderActionID.meetingIntelligenceCard,
            RecorderActionID.saveTranscript
        ] {
            XCTAssertTrue(
                reopened.windowContentRect.contains(try XCTUnwrap(reopened.frame(for: identifier))),
                "\(identifier) must be reachable in the wide window."
            )
        }
    }

    func testProjectionUpdatesKeepOpenDraftButClosingAndReopeningLoadsStoredText() throws {
        let state = TranscriptDetailLifecycleState(session: session())
        let host = try TranscriptDetailLifecycleHost(state: state)
        defer { host.close() }

        host.replaceEditorText(with: "Unsaved transcript draft")
        XCTAssertEqual(host.editorText, "Unsaved transcript draft")

        for index in 0 ..< 3 {
            state.publishUnrelatedUpdate()
            state.session = self.session(
                basedOn: state.session,
                title: "Generated title \(index)",
                favorite: index.isMultiple(of: 2)
            )
            host.render()
            XCTAssertEqual(host.editorText, "Unsaved transcript draft")
            XCTAssertEqual(host.accessibilityLabel(for: RecorderActionID.transcriptDetailTitle), "Generated title \(index)")
            XCTAssertEqual(host.accessibilityLabel(for: RecorderActionID.transcriptDetailFavorite), index.isMultiple(of: 2) ? "favorite" : "not-favorite")
        }

        state.closeDetail()
        host.render()
        state.reopenDetail()
        host.render()

        XCTAssertEqual(host.editorText, "Stored transcript")
    }

    func testTranscriptEditorSheetKeepsDraftOpenForFailedOrMismatchedSaveOutcome() throws {
        for makeOutcome in [
            { (sessionID: RecordingSession.ID) in
                LibrarySaveOutcome.failed(
                    sessionID: sessionID,
                    .transcript,
                    "Disk write failed"
                )
            },
            { (sessionID: RecordingSession.ID) in
                LibrarySaveOutcome.saved(sessionID: sessionID, .metadata)
            }
        ] {
            let state = TranscriptEditorSaveLifecycleState(makeOutcome: makeOutcome)
            let host = try TranscriptEditorSaveLifecycleHost(state: state)
            defer { host.close() }

            host.replaceEditorText(with: "Unsaved transcript draft")
            try host.click(RecorderActionID.saveTranscript)

            try host.waitUntil { state.savedTexts == ["Unsaved transcript draft"] }
            XCTAssertTrue(state.isPresented, "Only a successful transcript artifact may dismiss the editor.")
            XCTAssertEqual(host.editorText, "Unsaved transcript draft")
        }
    }

    func testTranscriptEditorSheetDismissesAfterMatchingTranscriptArtifactIsSaved() throws {
        let state = TranscriptEditorSaveLifecycleState {
            LibrarySaveOutcome.saved(sessionID: $0, .transcript)
        }
        let host = try TranscriptEditorSaveLifecycleHost(state: state)
        defer { host.close() }

        host.replaceEditorText(with: "Saved transcript")
        try host.click(RecorderActionID.saveTranscript)

        try host.waitUntil { state.savedTexts == ["Saved transcript"] && !state.isPresented }
        XCTAssertFalse(host.hasPresentedSheet)
    }

    func testMetadataSaveDispositionKeepsEditorOpenUnlessMetadataArtifactMatches() {
        let sessionID = editorLifecycleSession().id
        XCTAssertEqual(
            LibraryEditorSaveDisposition.disposition(
                for: .metadata,
                expectedSessionID: sessionID,
                outcome: .failed(
                    sessionID: sessionID,
                    .metadata,
                    "Metadata write failed"
                )
            ),
            .keepOpen
        )
        XCTAssertEqual(
            LibraryEditorSaveDisposition.disposition(
                for: .metadata,
                expectedSessionID: sessionID,
                outcome: .saved(sessionID: sessionID, .transcript)
            ),
            .keepOpen
        )
        XCTAssertEqual(
            LibraryEditorSaveDisposition.disposition(
                for: .metadata,
                expectedSessionID: sessionID,
                outcome: .saved(sessionID: sessionID, .metadata)
            ),
            .dismiss
        )
    }

    func testOpenUnsetSessionRefreshesThroughGeneratedTitlesAndProtectsManualOwnership() async throws {
        let publication = try PublicationFixture(
            metadata: .init(title: nil, titleOrigin: .unset)
        )
        defer { publication.remove() }
        let opened = session(
            basedOn: publication.session,
            title: nil,
            titleOrigin: .unset
        )
        let state = TranscriptDetailLifecycleState(session: opened)
        let host = try TranscriptDetailLifecycleHost(state: state)
        defer { host.close() }

        XCTAssertNil(state.openedSession.metadata.title)
        XCTAssertEqual(state.openedSession.metadata.titleOrigin, .unset)

        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceGenerate))
        try host.click(RecorderActionID.meetingIntelligenceGenerate)
        let generateSession = try XCTUnwrap(state.invokedSessions.first)
        XCTAssertEqual(generateSession.id, opened.id)
        XCTAssertNil(generateSession.metadata.title)
        XCTAssertEqual(generateSession.metadata.titleOrigin, .unset)

        let firstOutcome = try await publication.publisher.publish(
            publication.request.replacing(
                capturedTitle: generateSession.metadata.title,
                capturedTitleOrigin: generateSession.metadata.titleOrigin,
                content: .init(title: "MI title A", summary: "Summary A")
            )
        )
        XCTAssertTrue(firstOutcome.titleWasApplied)
        state.session = session(
            basedOn: opened,
            title: publication.metadata.title,
            titleOrigin: publication.metadata.titleOrigin
        )
        state.meetingIntelligencePresentation = .init(
            phase: .ready,
            summary: "Summary A",
            suggestedTitle: "MI title A",
            statusMessage: "Ready.",
            model: "test-model",
            titleIsProtected: false,
            unavailableReason: nil
        )
        host.render()

        XCTAssertEqual(host.accessibilityLabel(for: RecorderActionID.transcriptDetailTitle), "MI title A")
        XCTAssertEqual(state.presentationLookupSession?.metadata.title, "MI title A")
        XCTAssertEqual(state.presentationLookupSession?.metadata.titleOrigin, .meetingIntelligence)

        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceRegenerate))
        try host.click(RecorderActionID.meetingIntelligenceRegenerate)
        let regenerateSession = try XCTUnwrap(state.invokedSessions.last)
        XCTAssertEqual(regenerateSession.metadata.title, "MI title A")
        XCTAssertEqual(regenerateSession.metadata.titleOrigin, .meetingIntelligence)
        let secondOutcome = try await publication.publisher.publish(
            publication.request.replacing(
                capturedTitle: regenerateSession.metadata.title,
                capturedTitleOrigin: regenerateSession.metadata.titleOrigin,
                content: .init(title: "MI title B", summary: "Summary B")
            )
        )
        XCTAssertTrue(secondOutcome.titleWasApplied)
        state.session = session(
            basedOn: opened,
            title: publication.metadata.title,
            titleOrigin: publication.metadata.titleOrigin
        )
        state.meetingIntelligencePresentation = .init(
            phase: .ready,
            summary: "Summary B",
            suggestedTitle: "MI title B",
            statusMessage: "Ready.",
            model: "test-model",
            titleIsProtected: false,
            unavailableReason: nil
        )
        host.render()

        XCTAssertEqual(host.accessibilityLabel(for: RecorderActionID.transcriptDetailTitle), "MI title B")
        XCTAssertEqual(publication.metadata.title, "MI title B")
        XCTAssertEqual(publication.metadata.titleOrigin, .meetingIntelligence)
        XCTAssertEqual(state.presentationLookupSession?.metadata.title, "MI title B")
        XCTAssertEqual(state.presentationLookupSession?.metadata.titleOrigin, .meetingIntelligence)

        state.meetingIntelligencePresentation = .init(
            phase: .ready,
            summary: "Summary B",
            suggestedTitle: "MI title B",
            statusMessage: "Check availability again.",
            model: "test-model",
            titleIsProtected: false,
            unavailableReason: .connectionFailed
        )
        host.render()
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceCheckAgain))
        try host.click(RecorderActionID.meetingIntelligenceCheckAgain)

        state.meetingIntelligencePresentation = .init(
            phase: .failed,
            summary: "Summary B",
            suggestedTitle: "MI title B",
            statusMessage: "Generation failed.",
            model: "test-model",
            titleIsProtected: false,
            unavailableReason: nil
        )
        host.render()
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceRetryGeneration))
        try host.click(RecorderActionID.meetingIntelligenceRetryGeneration)

        state.meetingIntelligencePresentation = .init(
            phase: .generating(.init(stage: .generatingFinal, current: 1, total: 1)),
            summary: "Summary B",
            suggestedTitle: "MI title B",
            statusMessage: "Generating…",
            model: "test-model",
            titleIsProtected: false,
            unavailableReason: nil
        )
        host.render()
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceCancel))
        try host.click(RecorderActionID.meetingIntelligenceCancel)

        state.session = session(
            basedOn: opened,
            title: "Manual title",
            titleOrigin: .manual
        )
        state.meetingIntelligencePresentation = .init(
            phase: .ready,
            summary: "Summary B",
            suggestedTitle: "MI title B",
            statusMessage: "Ready.",
            model: "test-model",
            titleIsProtected: true,
            unavailableReason: nil
        )
        host.render()
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceManualTitleProtection))
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceApplyTitle))
        try host.click(RecorderActionID.meetingIntelligenceApplyTitle)

        XCTAssertEqual(
            state.invokedActions,
            ["generate", "regenerate", "checkAgain", "retryGeneration", "cancel", "applySuggestedTitle"]
        )
        XCTAssertEqual(state.invokedSessions.count, 6)
        XCTAssertEqual(state.invokedSessions[0].metadata.titleOrigin, .unset)
        XCTAssertEqual(state.invokedSessions[1].metadata.title, "MI title A")
        XCTAssertEqual(state.invokedSessions[1].metadata.titleOrigin, .meetingIntelligence)
        XCTAssertTrue(state.invokedSessions.dropFirst(2).prefix(3).allSatisfy { invoked in
            invoked.id == opened.id
                && invoked.metadata.title == "MI title B"
                && invoked.metadata.titleOrigin == .meetingIntelligence
        })
        XCTAssertEqual(state.invokedSessions[5].metadata.title, "Manual title")
        XCTAssertEqual(state.invokedSessions[5].metadata.titleOrigin, .manual)

        for protectedMetadata in [
            RecordingSessionMetadata(title: "Manual title", titleOrigin: .manual),
            RecordingSessionMetadata(title: nil, titleOrigin: .manual)
        ] {
            let protectedPublication = try PublicationFixture(metadata: protectedMetadata)
            defer { protectedPublication.remove() }
            let outcome = try await protectedPublication.publisher.publish(
                protectedPublication.request.replacing(
                    capturedTitle: protectedMetadata.title,
                    capturedTitleOrigin: protectedMetadata.titleOrigin,
                    content: .init(title: "MI title B", summary: "Summary B")
                )
            )

            XCTAssertFalse(outcome.titleWasApplied)
            XCTAssertEqual(outcome.artifact.suggestedTitle, "MI title B")
            XCTAssertEqual(protectedPublication.metadata, protectedMetadata)

            state.session = session(
                basedOn: opened,
                title: protectedMetadata.title,
                titleOrigin: protectedMetadata.titleOrigin
            )
            state.meetingIntelligencePresentation = .init(
                phase: .ready,
                summary: "Summary B",
                suggestedTitle: "MI title B",
                statusMessage: "Ready.",
                model: "test-model",
                titleIsProtected: protectedMetadata.titleOrigin == .manual,
                unavailableReason: nil
            )
            host.render()
            XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceManualTitleProtection))
            XCTAssertEqual(state.presentationLookupSession?.metadata, protectedMetadata)
        }
    }

    func testOpenSheetDerivesSuggestedTitleProtectionFromReloadedCanonicalSession() throws {
        let opened = session(title: "Manual title", titleOrigin: .manual)
        let state = TranscriptDetailLifecycleState(session: opened)
        state.meetingIntelligencePresentation = .init(
            phase: .ready,
            summary: "Summary",
            suggestedTitle: "Generated title",
            statusMessage: "Ready.",
            model: "test-model",
            titleIsProtected: true,
            unavailableReason: nil
        )
        let host = try TranscriptDetailLifecycleHost(state: state)
        defer { host.close() }

        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceManualTitleProtection))
        XCTAssertTrue(host.contains(RecorderActionID.meetingIntelligenceApplyTitle))
        try host.click(RecorderActionID.meetingIntelligenceApplyTitle)
        XCTAssertEqual(state.invokedActions, ["applySuggestedTitle"])
        XCTAssertEqual(state.durableSuggestedTitleWrites, 1)
        XCTAssertEqual(state.durableSuggestedTitlePublications, 1)
        XCTAssertEqual(state.capturedSuggestedTitleSession?.metadata.titleOrigin, .manual)

        // This is the canonical Library reload delivered by the durable title
        // publication. The MI projection remains deliberately stale so the
        // sheet proves it does not retain a second metadata owner.
        state.reloadCanonicalSession(session(
            basedOn: opened,
            title: "Generated title",
            titleOrigin: .meetingIntelligence
        ))
        host.renderWaitingForStatusTransition()

        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceManualTitleProtection))
        XCTAssertFalse(host.contains(RecorderActionID.meetingIntelligenceApplyTitle))
        XCTAssertEqual(state.invokedActions, ["applySuggestedTitle"])

        // This is the callback captured by the first, still-open sheet before
        // Library publication. This render probe replays that old session and
        // models durable-effect admission only; the production coordinator and
        // applier no-op route is covered by the integration test.
        state.replayCapturedSuggestedTitleApply()
        XCTAssertEqual(state.durableSuggestedTitleWrites, 1)
        XCTAssertEqual(state.durableSuggestedTitlePublications, 1)
    }

    private func session(
        basedOn existing: RecordingSession? = nil,
        title: String? = "Transcript detail",
        favorite: Bool = false,
        titleOrigin: RecordingTitleOrigin? = nil
    ) -> RecordingSession {
        let folder = existing?.folderURL ?? URL(fileURLWithPath: "/tmp/meeting-intelligence-sheet-\(UUID().uuidString)")
        return RecordingSession(
            id: existing?.id ?? folder,
            folderURL: folder,
            recordingURL: existing?.recordingURL ?? folder.appendingPathComponent("recording.m4a"),
            createdAt: existing?.createdAt ?? .now,
            duration: existing?.duration ?? 12,
            fileSize: existing?.fileSize ?? 1,
            metadata: .init(title: title, titleOrigin: titleOrigin, isFavorite: favorite)
        )
    }
}

@MainActor
private final class TranscriptDetailLifecycleState: ObservableObject {
    let openedSession: RecordingSession
    @Published var session: RecordingSession
    @Published var isDetailOpen = true
    @Published var meetingIntelligencePresentation = MeetingIntelligencePresentation.empty
    @Published private var unrelatedRevision = 0
    private(set) var presentationLookupSession: RecordingSession?
    private(set) var actionsLookupSession: RecordingSession?
    private(set) var invokedActions: [String] = []
    private(set) var invokedSessions: [RecordingSession] = []
    private let suggestedTitleAdmission: SuggestedTitleApplyAdmission
    private var capturedSuggestedTitleApply: (() -> Void)?

    var durableSuggestedTitleWrites: Int { suggestedTitleAdmission.durableWrites }
    var durableSuggestedTitlePublications: Int { suggestedTitleAdmission.durablePublications }
    var capturedSuggestedTitleSession: RecordingSession? { suggestedTitleAdmission.capturedSession }

    init(session: RecordingSession) {
        openedSession = session
        self.session = session
        suggestedTitleAdmission = .init(canonicalSession: session)
    }

    func publishUnrelatedUpdate() {
        unrelatedRevision += 1
    }

    func closeDetail() {
        isDetailOpen = false
    }

    func reopenDetail() {
        isDetailOpen = true
    }

    func meetingIntelligencePresentation(for session: RecordingSession) -> MeetingIntelligencePresentation {
        presentationLookupSession = session
        return meetingIntelligencePresentation
    }

    func record(_ action: String, session: RecordingSession) {
        actionsLookupSession = session
        invokedActions.append(action)
        invokedSessions.append(session)
        guard action == "applySuggestedTitle" else { return }
        let admission: () -> Void = { [weak self] in
            guard let self else { return }
            self.suggestedTitleAdmission.admit(session)
        }
        if capturedSuggestedTitleApply == nil {
            capturedSuggestedTitleApply = admission
            suggestedTitleAdmission.capturedSession = session
        }
        admission()
    }

    func reloadCanonicalSession(_ session: RecordingSession) {
        self.session = session
        suggestedTitleAdmission.canonicalSession = session
    }

    func replayCapturedSuggestedTitleApply() {
        capturedSuggestedTitleApply?()
    }

}

@MainActor
/// Test-only durable-effect admission counter for the session captured by the
/// first rendered Apply callback. Production stale-session handling is proved
/// by `MeetingIntelligenceJobCoordinatorTests`.
private final class SuggestedTitleApplyAdmission {
    var canonicalSession: RecordingSession
    var capturedSession: RecordingSession?
    private(set) var durableWrites = 0
    private(set) var durablePublications = 0

    init(canonicalSession: RecordingSession) {
        self.canonicalSession = canonicalSession
    }

    func admit(_ incoming: RecordingSession) {
        guard incoming.id == canonicalSession.id else { return }
        guard canonicalSession.metadata.titleOrigin != .meetingIntelligence else { return }
        durableWrites += 1
        durablePublications += 1
    }
}

@MainActor
private final class TranscriptEditorSaveLifecycleState: ObservableObject {
    @Published var isPresented = true
    let session = editorLifecycleSession()
    let makeOutcome: (RecordingSession.ID) -> LibrarySaveOutcome
    private(set) var savedTexts: [String] = []

    init(makeOutcome: @escaping (RecordingSession.ID) -> LibrarySaveOutcome) {
        self.makeOutcome = makeOutcome
    }

    func save(_ text: String) async -> LibrarySaveOutcome {
        savedTexts.append(text)
        return makeOutcome(session.id)
    }
}

@MainActor
private struct TranscriptEditorSaveLifecycleRoot: View {
    @ObservedObject var state: TranscriptEditorSaveLifecycleState

    var body: some View {
        Color.clear
            .frame(width: 420, height: 280)
            .sheet(isPresented: $state.isPresented) {
                TranscriptEditorView(
                    session: state.session,
                    load: { "Stored transcript" },
                    save: state.save,
                    export: {},
                    copy: {},
                    meetingIntelligencePresentation: { _ in .empty },
                    meetingIntelligenceActions: { _ in .init() }
                )
            }
    }
}

private func editorLifecycleSession() -> RecordingSession {
    let folder = URL(fileURLWithPath: "/tmp/editor-save-lifecycle-\(UUID().uuidString)")
    return RecordingSession(
        id: folder,
        folderURL: folder,
        recordingURL: folder.appendingPathComponent("recording.m4a"),
        createdAt: .now,
        duration: 12,
        fileSize: 1,
        metadata: .init(title: "Editor lifecycle")
    )
}

@MainActor
private struct TranscriptDetailLifecycleRoot: View {
    @ObservedObject var state: TranscriptDetailLifecycleState

    var body: some View {
        if state.isDetailOpen {
            TranscriptDetailSheetView(
                openedSession: state.openedSession,
                allSessions: [state.session],
                load: { "Stored transcript" },
                save: { _ in .saved(sessionID: state.openedSession.id, .transcript) },
                openFolder: {},
                play: {},
                export: {},
                copy: {},
                editDetails: { _ in },
                meetingIntelligencePresentation: state.meetingIntelligencePresentation,
                meetingIntelligenceObservedSnapshot: { _ in nil },
                checkMeetingIntelligenceAvailability: { state.record("checkAgain", session: $0) },
                generateMeetingIntelligence: { state.record("generate", session: $0) },
                regenerateMeetingIntelligence: { state.record("regenerate", session: $0) },
                retryMeetingIntelligenceGeneration: { state.record("retryGeneration", session: $0) },
                cancelMeetingIntelligence: { state.record("cancel", session: $0) },
                applyMeetingIntelligenceSuggestedTitle: { state.record("applySuggestedTitle", session: $0) }
            )
        }
    }
}

@MainActor
private final class TranscriptDetailLifecycleHost {
    private let hostingView: NSHostingView<TranscriptDetailLifecycleRoot>
    private let window: NSWindow

    init(state: TranscriptDetailLifecycleState) throws {
        hostingView = NSHostingView(rootView: .init(state: state))
        let frame = NSRect(x: 0, y: 0, width: 860, height: 680)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
        _ = try XCTUnwrap(editor)
    }

    var editorText: String { editor?.string ?? "" }

    func replaceEditorText(with text: String) {
        guard let editor else {
            XCTFail("Transcript editor was not rendered")
            return
        }
        editor.string = text
        editor.didChangeText()
        render()
    }

    func accessibilityLabel(for identifier: String) -> String? {
        view(for: identifier)?.accessibilityLabel()
            ?? accessibilityString(
                accessibilityElement(for: identifier),
                key: "accessibilityLabel"
            )
    }

    func contains(_ identifier: String) -> Bool {
        view(for: identifier) != nil || accessibilityElement(for: identifier) != nil
    }

    func click(_ identifier: String) throws {
        let marker = try XCTUnwrap(
            view(for: identifier),
            "Missing rendered action marker: \(identifier)"
        )
        let location = marker.convert(
            NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            )
            window.sendEvent(event)
        }
        render()
    }

    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func renderWaitingForStatusTransition() {
        render()
        let duration = RecorderMotionPolicy.make(reduceMotion: false).statusDuration
        RunLoop.main.run(until: Date().addingTimeInterval(duration + 0.05))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private var editor: NSTextView? {
        allViews(startingAt: hostingView).compactMap { $0 as? NSTextView }.first
    }

    private func view(for identifier: String) -> NSView? {
        allViews(startingAt: hostingView).first { $0.accessibilityIdentifier() == identifier }
    }

    private func accessibilityElement(for identifier: String) -> (any NSAccessibilityElementProtocol)? {
        func find(in elements: [Any]) -> (any NSAccessibilityElementProtocol)? {
            for element in elements {
                if let accessibility = element as? any NSAccessibilityElementProtocol,
                   accessibility.accessibilityIdentifier?() == identifier {
                    return accessibility
                }
                if let view = element as? NSView,
                   let found = find(in: view.accessibilityChildren() ?? []) {
                    return found
                }
            }
            return nil
        }
        return find(in: hostingView.accessibilityChildren() ?? [])
    }

    private func accessibilityString(
        _ element: (any NSAccessibilityElementProtocol)?,
        key: String
    ) -> String? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(key)) else {
            return nil
        }
        return object.value(forKey: key) as? String
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }
}

@MainActor
private final class TranscriptEditorSaveLifecycleHost {
    private let hostingView: NSHostingView<TranscriptEditorSaveLifecycleRoot>
    private let window: NSWindow

    init(state: TranscriptEditorSaveLifecycleState) throws {
        hostingView = NSHostingView(rootView: .init(state: state))
        let frame = NSRect(x: 0, y: 0, width: 500, height: 340)
        hostingView.frame = frame
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        try waitUntil { self.sheetWindow != nil }
    }

    var hasPresentedSheet: Bool { sheetWindow != nil }

    var editorText: String {
        guard let sheetWindow else { return "" }
        return allViews(startingAt: sheetWindow.contentView).compactMap { $0 as? NSTextView }.first?.string ?? ""
    }

    func replaceEditorText(with text: String) {
        guard let sheetWindow,
              let editor = allViews(startingAt: sheetWindow.contentView).compactMap({ $0 as? NSTextView }).first
        else {
            XCTFail("Transcript editor was not rendered in the presented sheet")
            return
        }
        editor.string = text
        editor.didChangeText()
        render()
    }

    func click(_ identifier: String) throws {
        guard let sheetWindow else {
            throw LifecycleHostError.sheetNotPresented
        }
        let marker = try XCTUnwrap(
            allViews(startingAt: sheetWindow.contentView).first {
                $0.accessibilityIdentifier() == identifier
            },
            "Missing rendered action marker: \(identifier)"
        )
        let location = marker.convert(
            NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: sheetWindow.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            )
            sheetWindow.sendEvent(event)
        }
        render()
    }

    func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 1
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            render()
        }
        XCTAssertTrue(condition(), "Timed out waiting for editor sheet lifecycle transition")
    }

    func close() {
        if let sheet = window.sheets.first {
            window.endSheet(sheet)
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    private var sheetWindow: NSWindow? {
        window.sheets.first
    }

    private func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        sheetWindow?.layoutIfNeeded()
        sheetWindow?.contentView?.layoutSubtreeIfNeeded()
    }

    private func allViews(startingAt view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { allViews(startingAt: $0) }
    }
}

private enum LifecycleHostError: Error {
    case sheetNotPresented
}

@MainActor
private final class SheetRenderHost<Root: View> {
    private let hostingView: NSHostingView<Root>
    private let window: NSWindow

    convenience init(size: CGSize, @ViewBuilder root: () -> Root) throws {
        try self.init(size: size, root: root())
    }

    init(size: CGSize, root: Root) throws {
        hostingView = NSHostingView(rootView: root)
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func contains(_ identifier: String) -> Bool {
        hostingView.accessibilityIdentifier() == identifier
            || allViews(startingAt: hostingView).contains {
                $0.accessibilityIdentifier() == identifier
            }
            || findAccessibility(in: hostingView.accessibilityChildren() ?? [], identifier: identifier) != nil
    }

    var windowContentRect: CGRect {
        let rect = window.contentLayoutRect
        return CGRect(origin: window.convertPoint(toScreen: rect.origin), size: rect.size)
    }

    func frame(for identifier: String) -> CGRect? {
        if let view = allViews(startingAt: hostingView).first(where: {
            $0.accessibilityIdentifier() == identifier
        }) {
            return view.accessibilityFrame()
        }
        return findAccessibility(in: hostingView.accessibilityChildren() ?? [], identifier: identifier)?
            .accessibilityFrame()
    }

    func containsView(named className: String) -> Bool {
        allViews(startingAt: hostingView).contains { String(describing: type(of: $0)).contains(className) }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func findAccessibility(in elements: [Any], identifier: String) -> (any NSAccessibilityElementProtocol)? {
        for element in elements {
            if let accessible = element as? any NSAccessibilityElementProtocol,
               accessible.accessibilityIdentifier?() == identifier { return accessible }
            if let view = element as? NSView,
               let found = findAccessibility(in: view.accessibilityChildren() ?? [], identifier: identifier) { return found }
            if let object = element as? NSObject,
               object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [Any],
               let found = findAccessibility(in: children, identifier: identifier) { return found }
        }
        return nil
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }
}
