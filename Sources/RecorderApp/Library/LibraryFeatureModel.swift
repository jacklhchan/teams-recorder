import Foundation

@MainActor
final class LibraryFeatureModel: ObservableObject {
    typealias SessionLoader = @Sendable (URL) -> [RecordingSession]
    typealias SessionReloader = @Sendable (RecordingSession) -> RecordingSession
    typealias SearchDocumentLoader = @Sendable (RecordingSession) -> RecordingLibrarySearchDocument
    typealias Recovery = @Sendable (URL) -> Void
    typealias TrashHandler = @Sendable (URL) throws -> Bool
    typealias AudioImporter = @Sendable (URL, URL) throws -> RecordingSession
    /// Runs only for a session returned by `audioImporter` when this feature
    /// has not published it. The importer/cleanup pair therefore owns the
    /// transaction; callers never delete an arbitrary pre-existing session.
    typealias ImportedSessionCleanup = @Sendable (RecordingSession, URL) -> Void

    @Published private(set) var snapshot: LibraryFeatureSnapshot = .empty
    /// Read-only compatibility projection. The canonical observable state is
    /// `snapshot`, whose revision advances for every published mutation.
    var sessions: [RecordingSession] { snapshot.sessions }
    let librarySourceID = UUID()
    var onSessionsLoaded: ((LibraryLoadedSnapshot) -> Void)?
    var onTranscriptPublicationCommitted: ((LibraryTranscriptProjectionCommitted) -> Void)?
    var onTranscriptEdited: ((TranscriptEdited) -> Void)?
    var onMetadataSaved: ((MetadataSaved) -> Void)?
    var onImportedAudioReady: ((ImportedAudioSessionReady) -> Void)?
    var onSessionRemoved: ((SessionRemoved) -> Void)?

    private let sessionLoader: SessionLoader
    private let sessionReloader: SessionReloader
    private let searchDocumentLoader: SearchDocumentLoader
    private let recovery: Recovery
    private let trashHandler: TrashHandler
    private let audioImporter: AudioImporter
    /// The single per-session mutation gate shared by Library, ASR and MI.
    /// Internal so AppModel can adopt it when a Library feature is injected.
    let mutationGate: RecordingSessionMutationGate
    private let importedSessionCleanup: ImportedSessionCleanup
    private let loadingQueue = DispatchQueue(
        label: "local.meeting.recorder.recording-library",
        qos: .userInitiated
    )
    private var refreshGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var searchGenerations: [RecordingSession.ID: UInt64] = [:]
    private var reloadGenerations: [RecordingSession.ID: UInt64] = [:]
    /// Orders per-session projection commits independently, so an unrelated
    /// session refresh does not invalidate an active indexing operation while
    /// a newer projection of the same session does.
    private var projectionGenerations: [RecordingSession.ID: UInt64] = [:]
    /// Recovery is a one-time operation for the active workspace revision.
    /// Keep just that identity rather than retaining every workspace ever
    /// visited for the lifetime of the app.
    private var recoveredWorkspace: LibraryWorkspaceSnapshot?
    private var workspace: URL?
    private var workspaceFence: WorkspacePublicationFence?
    private var tombstones: Set<RecordingSession.ID> = []
    private enum PendingDurableKind: Equatable {
        case importedAudio
        case transcript
        case metadata
        case transcriptPublication
        case trash
    }
    private struct PendingDurableTicket {
        let id: UUID
        let session: RecordingSession
        let kind: PendingDurableKind
        let workspaceSnapshot: LibraryWorkspaceSnapshot
        var wasObservedByRefresh = false
    }
    /// A durable artifact may be on disk while its search/reload completion is
    /// still queued. Refresh retains the current physical artifact until that
    /// completion has either published or failed; it never compares a large
    /// search document to infer which callback is newer.
    private var pendingDurableTickets: [RecordingSession.ID: [UUID: PendingDurableTicket]] = [:]
    /// Cleanup runs outside the main actor. Reserve the physical artifact
    /// before crossing that boundary so a refresh cannot adopt an import in
    /// the check-to-cleanup interval.
    private var importedCleanupReservations: Set<String> = []
    /// A loader can read an artifact while cleanup is in flight, then return
    /// after the reservation is released. Keep that stale result suppressed
    /// until a later scan of the same workspace confirms the artifact absent.
    private var importedCleanupSuppressions: [String: String] = [:]
    /// A second request must not race the first handler invocation. The
    /// membership check below also prevents a completed tombstone from being
    /// emitted twice.
    private var trashInFlight: Set<RecordingSession.ID> = []
    /// Bumped only by a successful semantic canonical mutation. A refresh
    /// captures this number before it loads, so an old file-system listing
    /// cannot replace a newer imported/edited/removed projection.
    private var canonicalMutationGeneration: UInt64 = 0
    private var isShutdown = false

    init(
        sessionLoader: @escaping SessionLoader,
        sessionReloader: @escaping SessionReloader,
        searchDocumentLoader: @escaping SearchDocumentLoader,
        recovery: @escaping Recovery,
        trashHandler: @escaping TrashHandler,
        audioImporter: @escaping AudioImporter = { source, workspace in
            try ManualTranscriptionImporter.importAudioFile(source, into: workspace)
        },
        importedSessionCleanup: @escaping ImportedSessionCleanup = { session, workspace in
            let folder = RecordingLibraryURLIdentity.normalized(session.folderURL)
            let root = RecordingLibraryURLIdentity.normalized(workspace)
            // The native importer creates a direct child session folder. Do
            // not remove any path whose ownership cannot be established.
            guard folder.deletingLastPathComponent() == root else { return }
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        },
        mutationGate: RecordingSessionMutationGate = .init()
    ) {
        self.sessionLoader = sessionLoader
        self.sessionReloader = sessionReloader
        self.searchDocumentLoader = searchDocumentLoader
        self.recovery = recovery
        self.trashHandler = trashHandler
        self.audioImporter = audioImporter
        self.importedSessionCleanup = importedSessionCleanup
        self.mutationGate = mutationGate
    }

    func refresh(
        workspace: URL,
        fence: WorkspacePublicationFence,
        notifyOnUnchangedProjection: Bool = true
    ) {
        guard !isShutdown else { return }
        let isWorkspaceTransition = self.workspace != RecordingLibraryURLIdentity.normalized(workspace)
            || workspaceFence != fence
        installWorkspace(workspace, fence: fence)
        advanceRefreshGeneration()
        // Refreshing the current workspace is observational. Do not cancel a
        // transcript/metadata indexing operation that has already persisted
        // its artifact. A real workspace/fence transition still invalidates
        // every outstanding operation.
        if isWorkspaceTransition {
            invalidateIndexingGenerations()
        }
        let generation = refreshGeneration
        let folder = RecordingLibraryURLIdentity.normalized(workspace)
        let workspaceSnapshot = LibraryWorkspaceSnapshot(folder: folder, fence: fence)
        let shouldRecover = recoveredWorkspace != workspaceSnapshot
        if shouldRecover { recoveredWorkspace = workspaceSnapshot }
        let mutationGeneration = canonicalMutationGeneration
        let loader = sessionLoader
        let recovery = recovery
        loadingQueue.async { [weak self] in
            if shouldRecover { recovery(folder) }
            let loaded = loader(folder)
            var states: [RecordingSession.ID: TranscriptionState] = [:]
            for session in loaded {
                let sessionID = RecordingLibraryURLIdentity.normalized(session.folderURL)
                guard states[sessionID] == nil,
                      let state = try? TranscriptionStateStore.load(in: session.folderURL) else {
                    continue
                }
                states[sessionID] = state
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.refreshGeneration == generation,
                      self.admits(folder: folder, fence: fence) else { return }
                // A newer semantic mutation (for example an imported session)
                // is already canonical. Re-run against the current generation
                // rather than replacing it with this stale disk listing.
                guard self.canonicalMutationGeneration == mutationGeneration else {
                    self.refresh(workspace: folder, fence: fence)
                    return
                }
                var visibleLoaded = self.canonicalizedSessions(loaded)
                self.clearImportedCleanupSuppressionsObservedAbsent(
                    from: visibleLoaded,
                    workspace: folder
                )
                visibleLoaded = visibleLoaded.filter {
                    !self.tombstones.contains($0.id)
                        && !self.importedCleanupReservations.contains(self.cleanupArtifactKey($0))
                        && self.importedCleanupSuppressions[self.cleanupArtifactKey($0)] == nil
                }
                self.reconcilePendingDurableTickets(into: &visibleLoaded)
                visibleLoaded.removeAll {
                    self.importedCleanupReservations.contains(self.cleanupArtifactKey($0))
                        || self.importedCleanupSuppressions[self.cleanupArtifactKey($0)] != nil
                }
                let visibleIDs = Set(visibleLoaded.map(\.id))
                let visibleStates = states.filter { visibleIDs.contains($0.key) }
                if self.publish(visibleLoaded, semanticMutation: false)
                    || notifyOnUnchangedProjection {
                    self.onSessionsLoaded?(.init(
                        sessions: visibleLoaded,
                        transcriptionStates: visibleStates
                    ))
                }
            }
        }
    }

    func clearForWorkspaceChange() {
        guard !isShutdown else { return }
        advanceRefreshGeneration()
        invalidateIndexingGenerations()
        tombstones.removeAll()
        publish([], semanticMutation: true)
    }

    /// Cancels admission for all queued callbacks and releases UI callbacks
    /// before the owning AppModel/feature graph is torn down.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        advanceRefreshGeneration()
        invalidateIndexingGenerations()
        workspace = nil
        workspaceFence = nil
        pendingDurableTickets.removeAll()
        importedCleanupReservations.removeAll()
        importedCleanupSuppressions.removeAll()
        onSessionsLoaded = nil
        onTranscriptPublicationCommitted = nil
        onTranscriptEdited = nil
        onMetadataSaved = nil
        onImportedAudioReady = nil
        onSessionRemoved = nil
    }

    /// Internal test fixture seed. It never appears in AppModel or normal UI
    /// command composition, so there is no production arbitrary replacement.
    func seedCanonicalSessionsForTesting(
        _ sessions: [RecordingSession],
        workspace: URL,
        fence: WorkspacePublicationFence
    ) {
        guard !isShutdown else { return }
        installWorkspace(workspace, fence: fence)
        publish(sessions, semanticMutation: true)
    }

    func acceptTranscriptPublication(_ event: TranscriptPublished) {
        guard hasCanonicalPhysicalPaths(event.session) else { return }
        let session = canonicalized(event.session)
        guard admits(session: session, fence: event.workspaceFence),
              isCanonicalMember(session),
              let workspaceSnapshot = activeWorkspaceSnapshot(),
              let ticket = beginPendingDurableTicket(
                for: session,
                kind: .transcriptPublication,
                workspaceSnapshot: workspaceSnapshot
              ) else { return }
        Task { [weak self] in
            guard let self,
                  await self.rebuildSearchDocument(
                    for: session,
                    fence: event.workspaceFence,
                    reconcileSameArtifactRefresh: true
                  ),
                  let canonical = self.session(withID: session.id) else {
                self?.finishPendingDurableTicket(ticket, refreshing: true)
                return
            }
            self.onTranscriptPublicationCommitted?(.init(
                identity: self.identity(for: canonical, revision: event.revision, fence: event.workspaceFence),
                publication: event,
                canonicalSession: canonical
            ))
            self.finishPendingDurableTicket(ticket, refreshing: true)
        }
    }

    func transcriptText(for session: RecordingSession) throws -> String {
        try TranscriptDocumentStore.read(in: canonicalized(session).folderURL)
    }

    func saveTranscript(
        _ text: String,
        for inputSession: RecordingSession,
        fence: WorkspacePublicationFence
    ) async -> LibrarySaveOutcome {
        let session = canonicalized(inputSession)
        guard admits(session: session, fence: fence), isCanonicalMember(session) else {
            return .failed(sessionID: session.id, .transcript, "The recording workspace changed before the transcript could be saved.")
        }
        guard let initiatingWorkspaceSnapshot = activeWorkspaceSnapshot() else {
            return .failed(sessionID: session.id, .transcript, "The recording workspace changed before the transcript could be saved.")
        }
        do {
            let gate = mutationGate
            let folder = session.folderURL
            try await Task.detached {
                try gate.withMutation(for: folder) {
                    try TranscriptDocumentStore.save(text, in: folder)
                }
            }.value
        } catch {
            return .failed(sessionID: session.id, .transcript, "Cannot save transcript: \(error.localizedDescription)")
        }
        guard isWorkspaceSnapshotActive(initiatingWorkspaceSnapshot),
              admits(session: session, fence: fence),
              isCanonicalMember(session),
              let ticket = beginPendingDurableTicket(
                for: session,
                kind: .transcript,
                workspaceSnapshot: initiatingWorkspaceSnapshot
              ) else {
            return .failed(sessionID: session.id, .transcript, "The recording workspace changed before the transcript could be indexed.")
        }
        guard await rebuildSearchDocument(
            for: session,
            fence: fence,
            reconcileSameArtifactRefresh: true
        ),
              admits(session: session, fence: fence),
              isCanonicalMember(session) else {
            finishPendingDurableTicket(ticket, refreshing: true)
            return .failed(sessionID: session.id, .transcript, "The recording workspace changed before the transcript could be indexed.")
        }
        if let canonical = self.session(withID: session.id) {
            onTranscriptEdited?(.init(
                identity: identity(for: canonical, revision: nil, fence: fence),
                canonicalSession: canonical
            ))
        }
        finishPendingDurableTicket(ticket, refreshing: true)
        return .saved(sessionID: session.id, .transcript)
    }

    func saveMetadata(
        titleEdit: RecordingTitleEdit,
        tags: String,
        isFavorite: Bool,
        for inputSession: RecordingSession,
        fence: WorkspacePublicationFence
    ) async -> LibrarySaveOutcome {
        let session = canonicalized(inputSession)
        guard admits(session: session, fence: fence), isCanonicalMember(session) else {
            return .failed(sessionID: session.id, .metadata, "The recording workspace changed before details could be saved.")
        }
        guard let initiatingWorkspaceSnapshot = activeWorkspaceSnapshot() else {
            return .failed(sessionID: session.id, .metadata, "The recording workspace changed before details could be saved.")
        }
        do {
            let gate = mutationGate
            let folder = session.folderURL
            try await Task.detached {
                try gate.withMutation(for: folder) {
                    var metadata = RecordingSessionMetadataStore.load(in: folder)
                    metadata.applyTitleEdit(titleEdit)
                    metadata.tags = tags.split(separator: ",").map(String.init)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    metadata.isFavorite = isFavorite
                    try RecordingSessionMetadataStore.save(metadata, in: folder)
                }
            }.value
        } catch {
            return .failed(sessionID: session.id, .metadata, "Cannot save recording details: \(error.localizedDescription)")
        }
        guard isWorkspaceSnapshotActive(initiatingWorkspaceSnapshot),
              admits(session: session, fence: fence),
              isCanonicalMember(session),
              let ticket = beginPendingDurableTicket(
                for: session,
                kind: .metadata,
                workspaceSnapshot: initiatingWorkspaceSnapshot
              ) else {
            return .failed(sessionID: session.id, .metadata, "The recording workspace changed before details could be indexed.")
        }
        guard await reload(
            session,
            fence: fence,
            reconcileSameArtifactRefresh: true
        ), admits(session: session, fence: fence),
           isCanonicalMember(session) else {
            finishPendingDurableTicket(ticket, refreshing: true)
            return .failed(sessionID: session.id, .metadata, "The recording workspace changed before details could be indexed.")
        }
        if let canonical = self.session(withID: session.id) {
            onMetadataSaved?(.init(
                identity: identity(for: canonical, revision: nil, fence: fence),
                canonicalSession: canonical
            ))
        }
        finishPendingDurableTicket(ticket, refreshing: true)
        return .saved(sessionID: session.id, .metadata)
    }

    func refreshAfterMeetingIntelligence(
        _ inputSession: RecordingSession,
        fence: WorkspacePublicationFence
    ) {
        let session = canonicalized(inputSession)
        guard admits(session: session, fence: fence),
              isCanonicalMember(session),
              let workspaceSnapshot = activeWorkspaceSnapshot(),
              let ticket = beginPendingDurableTicket(
                for: session,
                kind: .metadata,
                workspaceSnapshot: workspaceSnapshot
              ) else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.reload(
                session,
                fence: fence,
                reconcileSameArtifactRefresh: true
            )
            self.finishPendingDurableTicket(ticket, refreshing: true)
        }
    }

    func importAudio(
        _ sourceURL: URL,
        workspace: URL,
        fence: WorkspacePublicationFence
    ) async -> Result<RecordingSession, LibraryFeatureFailure> {
        let workspace = RecordingLibraryURLIdentity.normalized(workspace)
        guard admits(folder: workspace, fence: fence) else {
            return .failure(.init(message: "The recording workspace changed before audio could be imported."))
        }
        let initiatingWorkspaceSnapshot = LibraryWorkspaceSnapshot(folder: workspace, fence: fence)
        do {
            let importer = audioImporter
            let imported = try await Task.detached {
                try importer(sourceURL, workspace)
            }.value
            let session = canonicalized(imported)
            guard admits(session: session, fence: fence),
                  self.session(withID: session.id) == nil || isCanonicalMember(session) else {
                await cleanupImportedIfStillOwned(session, workspace: workspace, ticket: nil)
                return .failure(.init(message: "The recording workspace changed before audio could be imported."))
            }
            guard let ticket = beginPendingDurableTicket(
                for: session,
                kind: .importedAudio,
                workspaceSnapshot: initiatingWorkspaceSnapshot
            ) else {
                await cleanupImportedIfStillOwned(session, workspace: workspace, ticket: nil)
                return .failure(.init(message: "The recording workspace changed before audio could be imported."))
            }
            guard let indexed = await loadedSearchDocument(
                for: session,
                fence: fence,
                reconcileSameArtifactRefresh: true
            ) else {
                await cleanupImportedIfStillOwned(session, workspace: workspace, ticket: ticket)
                finishPendingDurableTicket(ticket, refreshing: true)
                return .failure(.init(message: "The recording workspace changed before audio could be indexed."))
            }
            guard admits(session: session, fence: fence) else {
                await cleanupImportedIfStillOwned(session, workspace: workspace, ticket: ticket)
                finishPendingDurableTicket(ticket, refreshing: true)
                return .failure(.init(message: "The recording workspace changed before audio could be indexed."))
            }
            var canonical = snapshot.sessions.filter { $0.id != session.id }
            canonical.insert(indexed, at: 0)
            publish(canonical, semanticMutation: true)
            onImportedAudioReady?(.init(
                identity: identity(for: indexed, revision: nil, fence: fence),
                canonicalSession: indexed
            ))
            finishPendingDurableTicket(ticket, refreshing: true)
            return .success(session)
        } catch {
            return .failure(.init(message: "Audio import failed: \(error.localizedDescription)"))
        }
    }

    func moveToTrash(
        _ inputSession: RecordingSession,
        fence: WorkspacePublicationFence
    ) async -> Result<Void, LibraryFeatureFailure> {
        let session = canonicalized(inputSession)
        guard admits(session: session, fence: fence),
              isCanonicalMember(session),
              !tombstones.contains(session.id),
              !trashInFlight.contains(session.id) else {
            return .failure(.init(message: "The recording workspace changed before it could be moved to Trash."))
        }
        trashInFlight.insert(session.id)
        defer { trashInFlight.remove(session.id) }
        guard let workspaceSnapshot = activeWorkspaceSnapshot(),
              let ticket = beginPendingDurableTicket(
                for: session,
                kind: .trash,
                workspaceSnapshot: workspaceSnapshot
              ) else {
            return .failure(.init(message: "The recording workspace changed before it could be moved to Trash."))
        }
        do {
            let handler = trashHandler
            let didMove = try await Task.detached {
                try handler(session.folderURL)
            }.value
            guard didMove else {
                finishPendingDurableTicket(ticket, refreshing: true)
                return .failure(.init(message: "Cannot move recording to Trash."))
            }
            guard admits(session: session, fence: fence),
                  !tombstones.contains(session.id) else {
                finishPendingDurableTicket(ticket, refreshing: true)
                return .failure(.init(message: "The recording workspace changed before it could be moved to Trash."))
            }
            if self.session(withID: session.id) != nil, !isCanonicalMember(session) {
                finishPendingDurableTicket(ticket, refreshing: true)
                return .failure(.init(message: "The recording workspace changed before it could be moved to Trash."))
            }
            tombstones.insert(session.id)
            if !publish(snapshot.sessions.filter { $0.id != session.id }, semanticMutation: true) {
                // A same-workspace refresh can observe the handler's durable
                // removal before this callback resumes. Preserve the
                // tombstone and invalidate stale refreshes without inventing
                // a second snapshot revision or removal event.
                recordSemanticMutation()
            }
            onSessionRemoved?(.init(
                identity: identity(for: session, revision: nil, fence: fence)
            ))
            finishPendingDurableTicket(ticket, refreshing: true)
            return .success(())
        } catch {
            finishPendingDurableTicket(ticket, refreshing: true)
            return .failure(.init(message: "Cannot move recording to Trash: \(error.localizedDescription)"))
        }
    }

    private func reload(
        _ initial: RecordingSession,
        fence: WorkspacePublicationFence,
        reconcileSameArtifactRefresh: Bool = false
    ) async -> Bool {
        var session = canonicalized(initial)
        let sessionID = session.id

        while true {
            guard admits(session: session, fence: fence), !tombstones.contains(sessionID) else {
                return false
            }
            let projectionGeneration = projectionGenerations[sessionID] ?? 0
            let generation = nextGeneration(reloadGenerations[sessionID] ?? 0)
            reloadGenerations[sessionID] = generation
            let reloader = sessionReloader
            let reloaded = canonicalized(await Task.detached { reloader(session) }.value)
            guard reloadGenerations[sessionID] == generation,
                  admits(session: session, fence: fence),
                  !tombstones.contains(sessionID) else { return false }
            guard projectionGenerations[sessionID] ?? 0 == projectionGeneration else {
                guard reconcileSameArtifactRefresh,
                      let canonical = matchingCanonicalArtifact(for: session) else { return false }
                session = canonical
                continue
            }
            guard let indexed = await loadedSearchDocument(
                for: reloaded,
                fence: fence,
                requeueWhenCanonicalMetadataDiffers: false,
                expectedProjectionGeneration: projectionGeneration,
                reconcileSameArtifactRefresh: reconcileSameArtifactRefresh
            ),
                  reloadGenerations[sessionID] == generation,
                  admits(session: indexed, fence: fence),
                  !tombstones.contains(sessionID) else { return false }
            guard !reconcileSameArtifactRefresh || matchingCanonicalArtifact(for: indexed) != nil else {
                return false
            }
            replace(indexed, semanticMutation: true)
            return true
        }
    }

    private func rebuildSearchDocument(
        for session: RecordingSession,
        fence: WorkspacePublicationFence,
        reconcileSameArtifactRefresh: Bool
    ) async -> Bool {
        guard admits(session: session, fence: fence) else { return false }
        guard let indexed = await loadedSearchDocument(
            for: session,
            fence: fence,
            reconcileSameArtifactRefresh: reconcileSameArtifactRefresh
        ) else { return false }
        replace(indexed, semanticMutation: true)
        return true
    }

    /// Loads a search document without publishing. The caller combines it with
    /// the matching canonical session in one snapshot publication.
    private func loadedSearchDocument(
        for initial: RecordingSession,
        fence: WorkspacePublicationFence,
        requeueWhenCanonicalMetadataDiffers: Bool = true,
        expectedProjectionGeneration: UInt64? = nil,
        reconcileSameArtifactRefresh: Bool = false
    ) async -> RecordingSession? {
        let initial = canonicalized(initial)
        let sessionID = initial.id
        var projectionGeneration = expectedProjectionGeneration
            ?? projectionGenerations[sessionID]
            ?? 0
        searchGeneration = nextGeneration(searchGeneration)
        let generation = searchGeneration
        searchGenerations[sessionID] = generation
        var candidate = initial

        while true {
            guard admits(session: candidate, fence: fence),
                  !tombstones.contains(sessionID),
                  searchGenerations[sessionID] == generation else { return nil }
            if projectionGenerations[sessionID] ?? 0 != projectionGeneration {
                guard reconcileSameArtifactRefresh,
                      let canonical = matchingCanonicalArtifact(for: candidate) else { return nil }
                candidate = canonical
                projectionGeneration = projectionGenerations[sessionID] ?? 0
                continue
            }
            let loader = searchDocumentLoader
            let document = await Task.detached { loader(candidate) }.value
            guard searchGenerations[sessionID] == generation,
                  admits(session: candidate, fence: fence),
                  !tombstones.contains(sessionID) else { return nil }

            if projectionGenerations[sessionID] ?? 0 != projectionGeneration {
                guard reconcileSameArtifactRefresh,
                      let canonical = matchingCanonicalArtifact(for: candidate) else { return nil }
                candidate = canonical
                projectionGeneration = projectionGenerations[sessionID] ?? 0
                continue
            }

            if requeueWhenCanonicalMetadataDiffers,
               let current = session(withID: sessionID), current.metadata != candidate.metadata {
                candidate = current
                projectionGeneration = projectionGenerations[sessionID] ?? 0
                continue
            }
            searchGenerations[sessionID] = nil
            // If the session is not yet canonical (successful import), the
            // caller deliberately owns the single insertion publication.
            let canonical = requeueWhenCanonicalMetadataDiffers
                ? (session(withID: sessionID) ?? candidate)
                : candidate
            return canonical.replacingSearchDocument(document)
        }
    }

    private func replace(_ input: RecordingSession, semanticMutation: Bool) {
        let session = canonicalized(input)
        var canonical = snapshot.sessions
        if let index = canonical.firstIndex(where: { $0.id == session.id }) {
            canonical[index] = session
        } else {
            canonical.append(session)
        }
        publish(canonical, semanticMutation: semanticMutation)
    }

    func session(withID id: RecordingSession.ID) -> RecordingSession? {
        let canonicalID = RecordingLibraryURLIdentity.normalized(id)
        return snapshot.sessions.first { $0.id == canonicalID }
    }

    /// Metadata and search text may legitimately be stale at the caller, but
    /// a same-ID session must never redirect trash I/O to another folder or
    /// media artifact.
    private func isCanonicalMember(_ candidate: RecordingSession) -> Bool {
        matchingCanonicalArtifact(for: candidate) != nil
    }

    private func matchingCanonicalArtifact(for candidate: RecordingSession) -> RecordingSession? {
        let candidate = canonicalized(candidate)
        guard let canonical = session(withID: candidate.id) else { return nil }
        return RecordingLibraryURLIdentity.normalized(canonical.folderURL)
            == RecordingLibraryURLIdentity.normalized(candidate.folderURL)
            && RecordingLibraryURLIdentity.normalized(canonical.recordingURL)
            == RecordingLibraryURLIdentity.normalized(candidate.recordingURL)
            ? canonical
            : nil
    }

    private func installWorkspace(_ folder: URL, fence: WorkspacePublicationFence) {
        workspace = RecordingLibraryURLIdentity.normalized(folder)
        workspaceFence = fence
    }

    private func identity(
        for session: RecordingSession,
        revision: TranscriptDocumentRevision?,
        fence: WorkspacePublicationFence
    ) -> LibraryMutationIdentity {
        let session = canonicalized(session)
        return .init(
            librarySourceID: librarySourceID,
            mutationID: UUID(),
            sessionID: session.id,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            transcriptRevision: revision,
            workspaceFence: fence
        )
    }

    private func admits(session: RecordingSession, fence: WorkspacePublicationFence) -> Bool {
        admits(folder: canonicalized(session).folderURL, fence: fence)
    }

    private func admits(folder: URL, fence: WorkspacePublicationFence) -> Bool {
        guard !isShutdown, workspaceFence == fence, let workspace else { return false }
        let current = RecordingLibraryURLIdentity.normalized(workspace)
        let candidate = RecordingLibraryURLIdentity.normalized(folder)
        return candidate.path == current.path || candidate.path.hasPrefix(current.path + "/")
    }

    private func cleanupImported(_ session: RecordingSession, workspace: URL) async {
        let session = canonicalized(session)
        let artifactKey = cleanupArtifactKey(session)
        guard importedCleanupReservations.insert(artifactKey).inserted else { return }
        let cleanup = importedSessionCleanup
        await Task.detached { cleanup(session, workspace) }.value
        importedCleanupReservations.remove(artifactKey)
        importedCleanupSuppressions[artifactKey] = RecordingLibraryURLIdentity.normalized(workspace).path
        // A refresh that was already queued before the reservation was
        // installed must not leave a deleted artifact in the snapshot.
        if !isShutdown, snapshot.sessions.contains(where: { $0.id == session.id }) {
            publish(snapshot.sessions.filter { $0.id != session.id }, semanticMutation: true)
        }
    }

    private func cleanupImportedIfStillOwned(
        _ session: RecordingSession,
        workspace: URL,
        ticket: PendingDurableTicket?
    ) async {
        guard !isShutdown else { return }
        // A refresh for a newer fence may have already adopted this exact
        // physical artifact. The old importer must then never remove it,
        // regardless of whether its own ticket is still active.
        guard matchingCanonicalArtifact(for: session) == nil else { return }
        if let ticket, !containsPendingDurableTicket(ticket) { return }
        await cleanupImported(session, workspace: workspace)
    }

    private func beginPendingDurableTicket(
        for input: RecordingSession,
        kind: PendingDurableKind,
        workspaceSnapshot: LibraryWorkspaceSnapshot
    ) -> PendingDurableTicket? {
        let session = canonicalized(input)
        guard isWorkspaceSnapshotActive(workspaceSnapshot),
              admits(session: session, fence: workspaceSnapshot.fence) else { return nil }
        let ticket = PendingDurableTicket(
            id: UUID(),
            session: session,
            kind: kind,
            workspaceSnapshot: workspaceSnapshot
        )
        pendingDurableTickets[session.id, default: [:]][ticket.id] = ticket
        return ticket
    }

    private func containsPendingDurableTicket(_ ticket: PendingDurableTicket) -> Bool {
        pendingDurableTickets[ticket.session.id]?[ticket.id] != nil
    }

    private func finishPendingDurableTicket(
        _ ticket: PendingDurableTicket,
        refreshing: Bool
    ) {
        guard let stored = pendingDurableTickets[ticket.session.id]?[ticket.id] else { return }
        pendingDurableTickets[stored.session.id]?[stored.id] = nil
        if pendingDurableTickets[ticket.session.id]?.isEmpty == true {
            pendingDurableTickets[ticket.session.id] = nil
        }
        guard refreshing,
              stored.wasObservedByRefresh,
              isTicketActive(stored),
              !isShutdown,
              let workspace,
              let workspaceFence else { return }
        refresh(
            workspace: workspace,
            fence: workspaceFence,
            notifyOnUnchangedProjection: false
        )
    }

    private func reconcilePendingDurableTickets(into loaded: inout [RecordingSession]) {
        let tickets = pendingDurableTickets.values.flatMap(\.values)
        for ticket in tickets where isTicketActive(ticket) {
            let artifactKey = cleanupArtifactKey(ticket.session)
            guard !importedCleanupReservations.contains(artifactKey),
                  importedCleanupSuppressions[artifactKey] == nil else { continue }
            var observed = ticket
            observed.wasObservedByRefresh = true
            pendingDurableTickets[observed.session.id]?[observed.id] = observed
            if let current = matchingCanonicalArtifact(for: ticket.session) {
                if let index = loaded.firstIndex(where: { $0.id == current.id }) {
                    loaded[index] = current
                } else {
                    loaded.append(current)
                }
            } else if ticket.kind == .importedAudio {
                loaded.removeAll { $0.id == ticket.session.id }
            }
        }
    }

    private func isTicketActive(_ ticket: PendingDurableTicket) -> Bool {
        isWorkspaceSnapshotActive(ticket.workspaceSnapshot)
    }

    private func clearImportedCleanupSuppressionsObservedAbsent(
        from loaded: [RecordingSession],
        workspace: URL
    ) {
        let workspacePath = RecordingLibraryURLIdentity.normalized(workspace).path
        let loadedKeys = Set(loaded.map(cleanupArtifactKey))
        importedCleanupSuppressions = importedCleanupSuppressions.filter { artifactKey, cleanupWorkspacePath in
            cleanupWorkspacePath != workspacePath || loadedKeys.contains(artifactKey)
        }
    }

    private func cleanupArtifactKey(_ session: RecordingSession) -> String {
        RecordingLibraryURLIdentity.normalized(session.folderURL).path
    }

    private func activeWorkspaceSnapshot() -> LibraryWorkspaceSnapshot? {
        guard !isShutdown, let workspace, let workspaceFence else { return nil }
        return .init(folder: workspace, fence: workspaceFence)
    }

    private func isWorkspaceSnapshotActive(_ workspaceSnapshot: LibraryWorkspaceSnapshot) -> Bool {
        activeWorkspaceSnapshot() == workspaceSnapshot
    }

    private func hasCanonicalPhysicalPaths(_ session: RecordingSession) -> Bool {
        let folder = RecordingLibraryURLIdentity.normalized(session.folderURL)
        return session.id == folder
            && session.folderURL == folder
            && session.recordingURL == RecordingLibraryURLIdentity.normalized(session.recordingURL)
    }

    @discardableResult
    private func publish(_ inputSessions: [RecordingSession], semanticMutation: Bool) -> Bool {
        let sessions = canonicalizedSessions(inputSessions)
        guard snapshot.sessions != sessions else { return false }
        let previousByID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let changedSessionIDs = Set(previousByID.keys).union(nextByID.keys).filter {
            previousByID[$0] != nextByID[$0]
        }
        precondition(
            snapshot.revision < UInt64.max,
            "Library feature snapshot revision exhausted."
        )
        snapshot = .init(revision: snapshot.revision + 1, sessions: sessions)
        for sessionID in changedSessionIDs {
            projectionGenerations[sessionID] = nextGeneration(projectionGenerations[sessionID] ?? 0)
        }
        if semanticMutation {
            recordSemanticMutation()
        }
        return true
    }

    private func advanceRefreshGeneration() {
        refreshGeneration = nextGeneration(refreshGeneration)
    }

    private func recordSemanticMutation() {
        canonicalMutationGeneration = nextGeneration(canonicalMutationGeneration)
    }

    private func invalidateIndexingGenerations() {
        searchGeneration = nextGeneration(searchGeneration)
        searchGenerations.removeAll()
        reloadGenerations.removeAll()
    }

    private func nextGeneration(_ current: UInt64) -> UInt64 {
        precondition(current < UInt64.max, "Library feature generation exhausted.")
        return current + 1
    }

    private func canonicalized(_ session: RecordingSession) -> RecordingSession {
        let folder = RecordingLibraryURLIdentity.normalized(session.folderURL)
        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: RecordingLibraryURLIdentity.normalized(session.recordingURL),
            createdAt: session.createdAt,
            duration: session.duration,
            fileSize: session.fileSize,
            metadata: session.metadata,
            searchDocument: session.searchDocument
        )
    }

    private func canonicalizedSessions(_ sessions: [RecordingSession]) -> [RecordingSession] {
        var seen = Set<RecordingSession.ID>()
        return sessions.compactMap { session in
            let canonical = canonicalized(session)
            return seen.insert(canonical.id).inserted ? canonical : nil
        }
    }
}
