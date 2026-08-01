import Foundation

/// Phase-owned subscription and admission boundary for the already-constructed
/// PR B features. It owns neither a session projection nor any job lifecycle.
@MainActor
final class PRBFeatureBridge {
    typealias Unregister = () -> Void

    struct Routes {
        let currentWorkspace: () -> LibraryWorkspaceSnapshot?
        let canonicalSession: (RecordingSession.ID) -> RecordingSession?
        let expectedTranscriptionPublicationSourceID: UUID
        let expectedLibrarySourceID: UUID
        let expectedMeetingIntelligencePublicationSourceID: UUID
        let transcriptionProviderIsConfigured: () -> Bool
        let registerTranscriptPublication: (@escaping (TranscriptPublished) -> Void) -> Unregister
        let registerLibrarySessionsLoaded: (@escaping (LibraryLoadedSnapshot) -> Void) -> Unregister
        let registerLibraryTranscriptCommit: (@escaping (LibraryTranscriptProjectionCommitted) -> Void) -> Unregister
        let registerTranscriptEdit: (@escaping (TranscriptEdited) -> Void) -> Unregister
        let registerMetadataSaved: (@escaping (MetadataSaved) -> Void) -> Unregister
        let registerImportedAudio: (@escaping (ImportedAudioSessionReady) -> Void) -> Unregister
        let registerSessionRemoval: (@escaping (SessionRemoved) -> Void) -> Unregister
        let registerMeetingIntelligencePublication: (@escaping (MeetingIntelligencePublished) -> Void) -> Unregister
        let registerProviderSave: (@escaping (ProviderSettingsSaved) -> Void) -> Unregister
        let acceptTranscriptPublication: (TranscriptPublished) -> Void
        let handleCommittedTranscriptPublication: (TranscriptPublished) -> Void
        let markTranscriptStale: (RecordingSession) -> Void
        let refreshAfterMeetingIntelligence: (RecordingSession, WorkspacePublicationFence) -> Void
        let startTranscription: (RecordingSession, Bool) -> Void
        let reportStatus: (String) -> Void
        let stopPlaybackIfActive: (RecordingSession.ID) -> Void
        let removeTranscriptionProjection: (RecordingSession.ID) -> Void
        let cancelAndRemoveMeetingIntelligence: (RecordingSession.ID) -> Void
        let replaceLoadedTranscriptionStates: ([RecordingSession.ID: TranscriptionState]) -> Void
        let reloadMeetingIntelligenceSessions: ([RecordingSession]) -> Void
        let clearLibraryForWorkspaceChange: () -> Void
        let refreshLibrary: (URL, WorkspacePublicationFence) -> Void
        let advanceTranscriptionFence: (WorkspacePublicationFence) -> Void
        let resetMeetingIntelligenceForWorkspaceChange: () -> Void
        let clearTranscriptionProjections: () -> Void
        let providerSettingsSaved: (ProviderSettingsSaved) -> Void
        let acceptRecordingFinalization: (RecordingFinalizationOutcome) -> Void
    }

    private enum LibraryEventIdentity: Hashable {
        case transcriptCommit(LibraryMutationIdentity)
        case transcriptEdit(LibraryMutationIdentity)
        case metadata(LibraryMutationIdentity)
        case importedAudio(LibraryMutationIdentity)
        case removed(LibraryMutationIdentity)
    }

    private struct TranscriptIdentity: Hashable {
        let identity: TranscriptPublicationIdentity
        let folder: URL
        let revision: TranscriptDocumentRevision
        let fence: WorkspacePublicationFence
    }

    private let routes: Routes
    private var unregisters: [Unregister] = []
    private var isAdmitting = false
    private var isTerminallyShutdown = false
    private var transcriptAdmissions = BoundedFIFOSet<TranscriptIdentity>()
    private var pendingTranscriptCommits = BoundedFIFOSet<TranscriptIdentity>()
    private var libraryAdmissions = BoundedFIFOSet<LibraryEventIdentity>()
    private var meetingIntelligenceAdmissions = BoundedFIFOSet<MeetingIntelligencePublicationIdentity>()
    private var providerAdmissions = BoundedFIFOSet<UUID>()
    private var finalizationAdmissions = BoundedFIFOSet<UUID>()

    init(routes: Routes) { self.routes = routes }

    convenience init(
        boundaries: PRBFeatureBoundaries,
        providerSettings: AIProviderSettingsModel,
        currentWorkspace: @escaping () -> LibraryWorkspaceSnapshot?,
        transcriptionProviderIsConfigured: @escaping () -> Bool,
        reportStatus: @escaping (String) -> Void
    ) {
        let library = boundaries.library
        let transcription = boundaries.transcription
        let meetingIntelligence = boundaries.meetingIntelligence
        let playback = boundaries.playback
        self.init(routes: .init(
            currentWorkspace: currentWorkspace,
            canonicalSession: { [weak library] id in
                library?.session(withID: id)
            },
            expectedTranscriptionPublicationSourceID:
                transcription.publicationSourceID,
            expectedLibrarySourceID: library.librarySourceID,
            expectedMeetingIntelligencePublicationSourceID:
                meetingIntelligence.publicationSourceID,
            transcriptionProviderIsConfigured:
                transcriptionProviderIsConfigured,
            registerTranscriptPublication: { [weak transcription] handler in
                guard let transcription else { return {} }
                let token = transcription.observeSuccessfulPublication(handler)
                return { [weak transcription] in
                    transcription?.removeSuccessfulPublicationObserver(token)
                }
            },
            registerLibrarySessionsLoaded: { [weak library] handler in
                guard let library else { return {} }
                let token = library.observeSessionsLoaded(handler)
                return { [weak library] in
                    library?.removeSessionsLoadedObserver(token)
                }
            },
            registerLibraryTranscriptCommit: { [weak library] handler in
                guard let library else { return {} }
                let token = library.observeTranscriptPublicationCommitted(handler)
                return { [weak library] in
                    library?.removeTranscriptPublicationCommittedObserver(token)
                }
            },
            registerTranscriptEdit: { [weak library] handler in
                guard let library else { return {} }
                let token = library.observeTranscriptEdited(handler)
                return { [weak library] in
                    library?.removeTranscriptEditedObserver(token)
                }
            },
            registerMetadataSaved: { [weak library] handler in
                guard let library else { return {} }
                let token = library.observeMetadataSaved(handler)
                return { [weak library] in
                    library?.removeMetadataSavedObserver(token)
                }
            },
            registerImportedAudio: { [weak library] handler in
                guard let library else { return {} }
                let token = library.observeImportedAudioReady(handler)
                return { [weak library] in
                    library?.removeImportedAudioReadyObserver(token)
                }
            },
            registerSessionRemoval: { [weak library] handler in
                guard let library else { return {} }
                let token = library.observeSessionRemoved(handler)
                return { [weak library] in
                    library?.removeSessionRemovedObserver(token)
                }
            },
            registerMeetingIntelligencePublication: {
                [weak meetingIntelligence] handler in
                guard let meetingIntelligence else { return {} }
                let token = meetingIntelligence.observePublication(handler)
                return { [weak meetingIntelligence] in
                    meetingIntelligence?.removePublicationObserver(token)
                }
            },
            registerProviderSave: { [weak providerSettings] handler in
                guard let providerSettings else { return {} }
                let token = providerSettings.observeProviderSettingsSaved(handler)
                return { [weak providerSettings] in
                    providerSettings?.removeProviderSettingsSavedObserver(token)
                }
            },
            acceptTranscriptPublication: { [weak library] event in
                library?.acceptTranscriptPublication(event)
            },
            handleCommittedTranscriptPublication: {
                [weak meetingIntelligence] event in
                meetingIntelligence?.handleTranscriptPublished(event)
            },
            markTranscriptStale: { [weak meetingIntelligence] session in
                meetingIntelligence?.transcriptDidSave(session)
            },
            refreshAfterMeetingIntelligence: { [weak library] session, fence in
                library?.refreshAfterMeetingIntelligence(session, fence: fence)
            },
            startTranscription: { [weak transcription] session, configured in
                transcription?.start(
                    session: session,
                    providerIsConfigured: configured
                )
            },
            reportStatus: reportStatus,
            stopPlaybackIfActive: { [weak playback] sessionID in
                playback?.stopIfActive(sessionID: sessionID)
            },
            removeTranscriptionProjection: { [weak transcription] sessionID in
                transcription?.removeProjection(for: sessionID)
            },
            cancelAndRemoveMeetingIntelligence: {
                [weak meetingIntelligence] sessionID in
                meetingIntelligence?.cancel(sessionID: sessionID)
                meetingIntelligence?.remove(sessionID: sessionID)
            },
            replaceLoadedTranscriptionStates: {
                [weak transcription] states in
                transcription?.replaceLoadedStates(states)
            },
            reloadMeetingIntelligenceSessions: {
                [weak meetingIntelligence] sessions in
                meetingIntelligence?.reload(sessions: sessions)
            },
            clearLibraryForWorkspaceChange: { [weak library] in
                library?.clearForWorkspaceChange()
            },
            refreshLibrary: { [weak library] workspace, fence in
                library?.refresh(workspace: workspace, fence: fence)
            },
            advanceTranscriptionFence: { [weak transcription] fence in
                transcription?.advanceWorkspacePublicationFence(to: fence)
            },
            resetMeetingIntelligenceForWorkspaceChange: {
                [weak meetingIntelligence] in
                meetingIntelligence?.resetForWorkspaceChange()
            },
            clearTranscriptionProjections: { [weak transcription] in
                transcription?.clearProjections()
            },
            providerSettingsSaved: { _ in
                // Jobs capture immutable provider snapshots when they start.
                // A committed save intentionally has no active-job command.
            },
            acceptRecordingFinalization: { [weak library] outcome in
                library?.acceptRecordingFinalization(outcome)
            }
        ))
    }

    func start() {
        guard !isTerminallyShutdown, unregisters.isEmpty else { return }
        // Register every producer before opening admission; synchronous
        // producers cannot observe a partly wired consumer graph.
        unregisters = [
            routes.registerTranscriptPublication { [weak self] in self?.receiveTranscript($0) },
            routes.registerLibrarySessionsLoaded { [weak self] in self?.receiveSessionsLoaded($0) },
            routes.registerLibraryTranscriptCommit { [weak self] in self?.receiveLibraryCommit($0) },
            routes.registerTranscriptEdit { [weak self] in self?.receiveTranscriptEdit($0) },
            routes.registerMetadataSaved { [weak self] in self?.receiveMetadataSaved($0) },
            routes.registerImportedAudio { [weak self] in self?.receiveImport($0) },
            routes.registerSessionRemoval { [weak self] in self?.receiveRemoval($0) },
            routes.registerMeetingIntelligencePublication { [weak self] in self?.receiveMeetingIntelligence($0) },
            routes.registerProviderSave { [weak self] in self?.receiveProviderSave($0) }
        ]
        isAdmitting = true
    }

    func shutdown() {
        guard !isTerminallyShutdown else { return }
        isAdmitting = false
        isTerminallyShutdown = true
        let callbacks = unregisters
        unregisters.removeAll()
        callbacks.forEach { $0() }
        transcriptAdmissions.removeAll(); pendingTranscriptCommits.removeAll(); libraryAdmissions.removeAll()
        meetingIntelligenceAdmissions.removeAll(); providerAdmissions.removeAll(); finalizationAdmissions.removeAll()
    }

    func workspaceDidChange(_ change: WorkspaceFolderChanged) {
        guard isAdmitting, let current = routes.currentWorkspace(), current == change.workspace else { return }
        clearWorkspaceAdmissions()
        routes.advanceTranscriptionFence(current.fence)
        routes.clearLibraryForWorkspaceChange()
        routes.resetMeetingIntelligenceForWorkspaceChange()
        routes.clearTranscriptionProjections()
        routes.refreshLibrary(current.folder, current.fence)
    }

    func recordingDidFinalize(_ outcome: RecordingFinalizationOutcome) {
        guard isAdmitting, let current = routes.currentWorkspace(),
              admits(
                folder: outcome.folder,
                fence: outcome.workspaceFence,
                workspace: current
              ),
              literal(outcome.folder), literal(outcome.recordingURL),
              outcome.recordingURL.deletingLastPathComponent() == outcome.folder,
              finalizationAdmissions.insert(outcome.finalizationID) else { return }
        routes.acceptRecordingFinalization(outcome)
    }

    private func receiveTranscript(_ event: TranscriptPublished) {
        let identity = TranscriptIdentity(identity: event.identity, folder: event.normalizedSessionFolder, revision: event.revision, fence: event.workspaceFence)
        guard isAdmitting, let current = routes.currentWorkspace(), valid(event, workspace: current), transcriptAdmissions.insert(identity) else { return }
        _ = pendingTranscriptCommits.insert(identity)
        routes.acceptTranscriptPublication(event)
    }

    private func receiveSessionsLoaded(_ event: LibraryLoadedSnapshot) {
        guard isAdmitting else { return }
        routes.replaceLoadedTranscriptionStates(event.transcriptionStates)
        routes.reloadMeetingIntelligenceSessions(event.sessions)
    }

    private func receiveLibraryCommit(_ event: LibraryTranscriptProjectionCommitted) {
        guard isAdmitting, let current = routes.currentWorkspace(),
              valid(event.identity, session: event.canonicalSession, workspace: current),
              valid(event.publication, workspace: current),
              event.identity.transcriptRevision == event.publication.revision,
              sameCanonicalSession(event.publication.session, event.canonicalSession),
              pendingTranscriptCommits.consume(.init(identity: event.publication.identity, folder: event.publication.normalizedSessionFolder, revision: event.publication.revision, fence: event.publication.workspaceFence)),
              libraryAdmissions.insert(.transcriptCommit(event.identity)) else { return }
        routes.handleCommittedTranscriptPublication(event.publication)
    }

    private func receiveTranscriptEdit(_ event: TranscriptEdited) {
        guard isAdmitting, let current = routes.currentWorkspace(), valid(event.identity, session: event.canonicalSession, workspace: current), libraryAdmissions.insert(.transcriptEdit(event.identity)) else { return }
        routes.markTranscriptStale(event.canonicalSession)
    }

    private func receiveMetadataSaved(_ event: MetadataSaved) {
        guard isAdmitting, let current = routes.currentWorkspace(), valid(event.identity, session: event.canonicalSession, workspace: current), libraryAdmissions.insert(.metadata(event.identity)) else { return }
        routes.reloadMeetingIntelligenceSessions([event.canonicalSession])
    }

    private func receiveImport(_ event: ImportedAudioSessionReady) {
        guard isAdmitting, let current = routes.currentWorkspace(), valid(event.identity, session: event.canonicalSession, workspace: current), libraryAdmissions.insert(.importedAudio(event.identity)) else { return }
        routes.reportStatus("Audio imported for transcription: \(event.canonicalSession.displayName)")
        routes.startTranscription(event.canonicalSession, routes.transcriptionProviderIsConfigured())
    }

    private func receiveRemoval(_ event: SessionRemoved) {
        guard isAdmitting, let current = routes.currentWorkspace(),
              event.identity.librarySourceID == routes.expectedLibrarySourceID,
              routes.canonicalSession(event.identity.sessionID) == nil,
              literal(event.identity.normalizedSessionFolder),
              admits(folder: event.identity.normalizedSessionFolder, fence: event.identity.workspaceFence, workspace: current),
              libraryAdmissions.insert(.removed(event.identity)) else { return }
        routes.stopPlaybackIfActive(event.identity.sessionID)
        routes.removeTranscriptionProjection(event.identity.sessionID)
        routes.cancelAndRemoveMeetingIntelligence(event.identity.sessionID)
    }

    private func receiveMeetingIntelligence(_ event: MeetingIntelligencePublished) {
        guard isAdmitting, let current = routes.currentWorkspace(),
              event.identity.coordinatorInstanceID == routes.expectedMeetingIntelligencePublicationSourceID,
              event.identity.sessionID == event.canonicalSession.id,
              event.identity.normalizedSessionFolder == RecordingLibraryURLIdentity.normalized(event.canonicalSession.folderURL),
              validCanonical(event.canonicalSession),
              admits(event.canonicalSession, fence: event.identity.workspaceFence, workspace: current),
              meetingIntelligenceAdmissions.insert(event.identity) else { return }
        routes.refreshAfterMeetingIntelligence(event.canonicalSession, event.identity.workspaceFence)
    }

    private func receiveProviderSave(_ event: ProviderSettingsSaved) {
        guard isAdmitting, providerAdmissions.insert(event.profileRevision) else { return }
        routes.providerSettingsSaved(event)
    }

    private func valid(_ identity: LibraryMutationIdentity, session: RecordingSession, workspace: LibraryWorkspaceSnapshot) -> Bool {
        guard let canonical = routes.canonicalSession(identity.sessionID),
              canonical == session,
              identity.librarySourceID == routes.expectedLibrarySourceID,
              identity.sessionID == session.id,
              identity.normalizedSessionFolder == RecordingLibraryURLIdentity.normalized(session.folderURL),
              validCanonical(session), admits(session, fence: identity.workspaceFence, workspace: workspace) else { return false }
        return true
    }

    private func valid(_ event: TranscriptPublished, workspace: LibraryWorkspaceSnapshot) -> Bool {
        event.identity.coordinatorInstanceID == routes.expectedTranscriptionPublicationSourceID
            && event.normalizedSessionFolder == RecordingLibraryURLIdentity.normalized(event.session.folderURL)
            && event.canonicalURL == TranscriptDocumentStore.editableURL(in: event.session.folderURL)
            && validCanonical(event.session)
            && admits(event.session, fence: event.workspaceFence, workspace: workspace)
    }

    private func validCanonical(_ session: RecordingSession) -> Bool {
        guard let canonical = routes.canonicalSession(session.id) else { return false }
        return sameCanonicalSession(session, canonical)
    }

    private func sameCanonicalSession(_ lhs: RecordingSession, _ rhs: RecordingSession) -> Bool {
        lhs.id == rhs.id && lhs.folderURL == rhs.folderURL && lhs.recordingURL == rhs.recordingURL
            && literal(lhs.folderURL) && literal(lhs.recordingURL)
    }

    private func admits(_ session: RecordingSession, fence: WorkspacePublicationFence, workspace: LibraryWorkspaceSnapshot) -> Bool {
        validCanonical(session) && admits(folder: session.folderURL, fence: fence, workspace: workspace)
    }

    private func admits(folder: URL, fence: WorkspacePublicationFence, workspace: LibraryWorkspaceSnapshot? = nil) -> Bool {
        guard let current = workspace ?? routes.currentWorkspace(), current.fence == fence else { return false }
        let canonicalFolder = RecordingLibraryURLIdentity.normalized(folder)
        let canonicalWorkspace = RecordingLibraryURLIdentity.normalized(current.folder)
        return canonicalFolder.deletingLastPathComponent() == canonicalWorkspace
    }

    private func literal(_ url: URL) -> Bool {
        let raw = url.path
        return !raw.contains("/../") && !raw.hasSuffix("/..")
            && url.standardizedFileURL.path == raw
            && url.resolvingSymlinksInPath().standardizedFileURL.path == raw
    }

    private func clearWorkspaceAdmissions() {
        transcriptAdmissions.removeAll(); pendingTranscriptCommits.removeAll(); libraryAdmissions.removeAll(); meetingIntelligenceAdmissions.removeAll(); finalizationAdmissions.removeAll()
    }
}

private struct BoundedFIFOSet<Element: Hashable> {
    private let capacity = 256
    private var members: Set<Element> = []
    private var order: [Element] = []

    mutating func insert(_ element: Element) -> Bool {
        guard members.insert(element).inserted else { return false }
        order.append(element)
        if order.count > capacity { members.remove(order.removeFirst()) }
        return true
    }

    mutating func consume(_ element: Element) -> Bool {
        guard members.remove(element) != nil else { return false }
        if let index = order.firstIndex(of: element) { order.remove(at: index) }
        return true
    }

    mutating func removeAll() { members.removeAll(); order.removeAll() }
}
