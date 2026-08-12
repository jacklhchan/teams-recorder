import Combine
import Foundation

struct MeetingIntelligencePresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case notGenerated
        case checkingAvailability
        case generating(MeetingIntelligenceProgress)
        case ready
        case stale
        case failed
        case cancelled
        case interrupted
    }

    let phase: Phase
    let summary: String?
    let suggestedTitle: String?
    let statusMessage: String
    let model: String?
    let titleIsProtected: Bool
    let unavailableReason: MeetingIntelligenceUnavailableReason?
    let editableContent: MeetingIntelligenceEditableContent?

    init(
        phase: Phase,
        summary: String?,
        suggestedTitle: String?,
        statusMessage: String,
        model: String?,
        titleIsProtected: Bool,
        unavailableReason: MeetingIntelligenceUnavailableReason?,
        editableContent: MeetingIntelligenceEditableContent? = nil
    ) {
        self.phase = phase
        self.summary = summary
        self.suggestedTitle = suggestedTitle
        self.statusMessage = statusMessage
        self.model = model
        self.titleIsProtected = titleIsProtected
        self.unavailableReason = unavailableReason
        self.editableContent = editableContent
    }

    static let empty = Self(
        phase: .notGenerated,
        summary: nil,
        suggestedTitle: nil,
        statusMessage: "Not generated.",
        model: nil,
        titleIsProtected: false,
        unavailableReason: nil
    )
}

/// The physical identity used by the UI projection.  It intentionally carries
/// no metadata or search document: the Library remains the owner of those
/// mutable projections.
struct MeetingIntelligenceSessionPresentationIdentity: Hashable, Sendable {
    let sessionID: RecordingSession.ID
    let normalizedSessionFolder: URL

    init?(session: RecordingSession) {
        let folder = RecordingLibraryURLIdentity.normalized(session.folderURL)
        let recording = RecordingLibraryURLIdentity.normalized(session.recordingURL)
        guard session.id.path == folder.path,
              session.folderURL.path == folder.path,
              session.recordingURL.path == recording.path
        else { return nil }
        // Keep one physical URL representation so directory-hint differences
        // cannot split one recording into two UI projection keys.
        sessionID = folder
        normalizedSessionFolder = folder
    }
}

struct MeetingIntelligenceSessionPresentation: Equatable, Sendable {
    let identity: MeetingIntelligenceSessionPresentationIdentity
    let presentation: MeetingIntelligencePresentation
}

/// Immutable, read-only projection for UI consumers.  A lookup rejects an
/// alias/malformed session rather than accidentally presenting another
/// recording's state.
struct MeetingIntelligenceFeatureSnapshot: Equatable, Sendable {
    let revision: UInt64
    private let presentations: [MeetingIntelligenceSessionPresentationIdentity: MeetingIntelligenceSessionPresentation]

    static let empty = Self(revision: 0, presentations: [:])

    func presentation(for session: RecordingSession) -> MeetingIntelligenceSessionPresentation? {
        guard let identity = MeetingIntelligenceSessionPresentationIdentity(session: session) else { return nil }
        return presentations[identity]
    }

    fileprivate func replacing(
        _ presentation: MeetingIntelligencePresentation,
        for session: RecordingSession
    ) -> Self? {
        guard let identity = MeetingIntelligenceSessionPresentationIdentity(session: session) else { return nil }
        let value = MeetingIntelligenceSessionPresentation(identity: identity, presentation: presentation)
        guard presentations[identity] != value else { return nil }
        var next = presentations
        next[identity] = value
        return .init(revision: advancedRevision, presentations: next)
    }

    fileprivate func removing(_ identity: MeetingIntelligenceSessionPresentationIdentity) -> Self? {
        guard presentations[identity] != nil else { return nil }
        var next = presentations
        next.removeValue(forKey: identity)
        return .init(revision: advancedRevision, presentations: next)
    }

    fileprivate func resettingWorkspace() -> Self {
        .init(revision: advancedRevision, presentations: [:])
    }

    private var advancedRevision: UInt64 {
        // This is an in-process snapshot equality token, not a stale-work
        // admission fence.  Tickets, leases, and typed publication identities
        // own stale-work rejection.  Failing at the practically unreachable
        // UInt64 limit preserves uniqueness; wrapping or saturating would make
        // distinct visible snapshots share a revision.
        precondition(revision < .max, "Meeting intelligence snapshot revision exhausted")
        return revision + 1
    }
}

struct MeetingIntelligenceSuggestedTitleRequest: Sendable {
    let session: RecordingSession
    let artifact: MeetingIntelligenceArtifact
    let sourceRevision: TranscriptDocumentRevision
    let capturedTitle: String?
    let capturedTitleOrigin: RecordingTitleOrigin
    let lease: MeetingIntelligenceAttemptLease
}

/// A narrow asynchronous admission point before a state-file write. The
/// production implementation is immediate; it also gives lifecycle tests a
/// deterministic point at which remove/shutdown can invalidate a queued write.
protocol MeetingIntelligenceStateSaveScheduling: Sendable {
    func awaitAdmission() async
    func awaitCommitAdmission() async
}

extension MeetingIntelligenceStateSaveScheduling {
    func awaitCommitAdmission() async {}
}

private struct ImmediateMeetingIntelligenceStateSaveScheduler: MeetingIntelligenceStateSaveScheduling {
    func awaitAdmission() async {}
}

private actor MeetingIntelligenceIO {
    private let repository: any OpenAICompatibleProviderManaging
    private let reader: any TranscriptDocumentReading
    private let artifacts: any MeetingIntelligenceArtifactStoring
    private let states: any MeetingIntelligenceStateStoring
    private let publisher: any MeetingIntelligencePublishing
    private let artifactEditor: any MeetingIntelligenceArtifactEditing
    private let stateSaveScheduler: any MeetingIntelligenceStateSaveScheduling
    private var latestWriteByFolder: [URL: WriteIdentity] = [:]

    private struct WriteIdentity {
        let generation: UInt64
        let attempt: UUID
        let sequence: UInt64
    }

    init(repository: any OpenAICompatibleProviderManaging, reader: any TranscriptDocumentReading,
         artifacts: any MeetingIntelligenceArtifactStoring, states: any MeetingIntelligenceStateStoring,
         publisher: any MeetingIntelligencePublishing,
         artifactEditor: any MeetingIntelligenceArtifactEditing,
         stateSaveScheduler: any MeetingIntelligenceStateSaveScheduling) {
        self.repository = repository; self.reader = reader; self.artifacts = artifacts; self.states = states
        self.publisher = publisher; self.artifactEditor = artifactEditor
        self.stateSaveScheduler = stateSaveScheduler
    }
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { try repository.snapshot() }
    func transcript(in folder: URL) throws -> TranscriptDocumentSnapshot { try reader.readCanonical(in: folder, allowLegacy: false) }
    func artifact(in folder: URL) throws -> MeetingIntelligenceArtifact? { try artifacts.load(in: folder) }
    func state(in folder: URL) throws -> MeetingIntelligenceState? { try states.load(in: folder) }
    func save(
        _ state: MeetingIntelligenceState,
        in folder: URL,
        generation: UInt64,
        attempt: UUID,
        sequence: UInt64,
        lease: MeetingIntelligenceAttemptLease
    ) async throws {
        guard !Task.isCancelled, lease.isValid else { return }
        let incoming = WriteIdentity(generation: generation, attempt: attempt, sequence: sequence)
        if let latest = latestWriteByFolder[folder] {
            guard incoming.generation > latest.generation ||
                    (incoming.generation == latest.generation && incoming.attempt == latest.attempt && incoming.sequence > latest.sequence)
            else { return }
        }
        await stateSaveScheduler.awaitAdmission()
        guard !Task.isCancelled, lease.isValid else { return }
        await stateSaveScheduler.awaitCommitAdmission()
        guard !Task.isCancelled, lease.isValid else { return }
        // This reservation is the state-file linearization point. Lifecycle
        // invalidation that wins before it produces no recovery state; once it
        // exists, this exact save is the ordered winner.
        guard let commit = lease.beginCommit() else { return }
        defer { commit.finish() }
        latestWriteByFolder[folder] = incoming
        try states.save(state, in: folder)
    }
    func publish(_ request: MeetingIntelligencePublicationRequest) async throws -> MeetingIntelligencePublicationOutcome {
        guard !Task.isCancelled, request.lease.isValid else { throw CancellationError() }
        return try await publisher.publish(request)
    }
    func edit(_ request: MeetingIntelligenceArtifactEditRequest) async throws -> MeetingIntelligenceArtifact {
        try await artifactEditor.save(request)
    }
}

@MainActor
final class MeetingIntelligenceJobCoordinator: ObservableObject {
    typealias DateNow = @Sendable () -> Date

    var onPublication: ((MeetingIntelligencePublished) -> Void)?
    /// Called only after `snapshot` has been replaced.  Feature models use
    /// this post-commit signal instead of Combine's pre-mutation publishing.
    var onSnapshotDidChange: ((MeetingIntelligenceFeatureSnapshot) -> Void)?

    private let expectedPublicationSourceID: UUID
    var expectedTranscriptionPublicationSourceID: UUID {
        expectedPublicationSourceID
    }
    let publicationSourceID: UUID
    /// PR B composition identity. Production construction injects the same
    /// gate into the artifact/state/title collaborators for this coordinator.
    let mutationGate: RecordingSessionMutationGate
    let providerRepositoryIdentity: ObjectIdentifier
    private let io: MeetingIntelligenceIO
    private let availabilityChecker: any MeetingIntelligenceAvailabilityChecking
    private let generator: any MeetingIntelligenceGenerating
    private let titleApplier: MeetingIntelligenceSuggestedTitleApplier?
    private let publicationDeliveryScheduler: any MeetingIntelligencePublicationDeliveryScheduling
    private let thirdPartyProcessingAdmission: (any ThirdPartyProcessingAdmitting)?
    var thirdPartyProcessingAdmissionIdentity: ObjectIdentifier? {
        thirdPartyProcessingAdmission.map { ObjectIdentifier($0 as AnyObject) }
    }
    private let now: DateNow

    private var tasksBySessionID: [RecordingSession.ID: Task<Void, Never>] = [:]
    private var editTasksBySessionID: [RecordingSession.ID: Task<MeetingIntelligenceEditSaveOutcome, Never>] = [:]
    private var editTicketsBySessionID: [RecordingSession.ID: Ticket] = [:]
    private var cancelledEditTicketsBySessionID: [RecordingSession.ID: Ticket] = [:]
    private var reloadTasksBySessionID: [RecordingSession.ID: Task<Void, Never>] = [:]
    private var reloadTokensBySessionID: [RecordingSession.ID: UUID] = [:]
    private var generationsBySessionID: [RecordingSession.ID: UInt64] = [:]
    private var attemptsBySessionID: [RecordingSession.ID: UUID] = [:]
    private var leasesBySessionID: [RecordingSession.ID: MeetingIntelligenceAttemptLease] = [:]
    private var nextWriteSequenceBySessionID: [RecordingSession.ID: UInt64] = [:]
    private var latestPublicationsBySessionID: [RecordingSession.ID: TranscriptPublicationIdentity] = [:]
    private var sessionsByID: [RecordingSession.ID: RecordingSession] = [:]
    private var removedSessionIDs = Set<RecordingSession.ID>()
    private var cancelledSessionIDs = Set<RecordingSession.ID>()
    private var isShutDown = false
    @Published private(set) var snapshot = MeetingIntelligenceFeatureSnapshot.empty

    init(
        providerRepository: any OpenAICompatibleProviderManaging,
        expectedPublicationSourceID: UUID,
        publicationSourceID: UUID = UUID(),
        mutationGate: RecordingSessionMutationGate = .init(),
        transcriptReader: any TranscriptDocumentReading = SecureTranscriptDocumentReader(),
        availabilityChecker: any MeetingIntelligenceAvailabilityChecking,
        generator: any MeetingIntelligenceGenerating,
        publisher: any MeetingIntelligencePublishing,
        artifactStore: any MeetingIntelligenceArtifactStoring,
        stateStore: any MeetingIntelligenceStateStoring,
        artifactEditor: (any MeetingIntelligenceArtifactEditing)? = nil,
        titleApplier: MeetingIntelligenceSuggestedTitleApplier? = nil,
        stateSaveScheduler: any MeetingIntelligenceStateSaveScheduling = ImmediateMeetingIntelligenceStateSaveScheduler(),
        publicationDeliveryScheduler: any MeetingIntelligencePublicationDeliveryScheduling = ImmediateMeetingIntelligencePublicationDeliveryScheduler(),
        thirdPartyProcessingAdmission: (any ThirdPartyProcessingAdmitting)? = nil,
        now: @escaping DateNow = { Date() }
    ) {
        self.expectedPublicationSourceID = expectedPublicationSourceID
        self.publicationSourceID = publicationSourceID
        self.mutationGate = mutationGate
        providerRepositoryIdentity = providerRepository.compositionIdentity
        let resolvedArtifactEditor: any MeetingIntelligenceArtifactEditing = artifactEditor ?? MeetingIntelligenceArtifactEditor(
            mutationGate: mutationGate,
            transcriptReader: transcriptReader,
            artifactStore: artifactStore
        )
        io = .init(repository: providerRepository, reader: transcriptReader,
                   artifacts: artifactStore, states: stateStore, publisher: publisher,
                   artifactEditor: resolvedArtifactEditor,
                   stateSaveScheduler: stateSaveScheduler)
        self.availabilityChecker = availabilityChecker
        self.generator = generator
        self.titleApplier = titleApplier
        self.publicationDeliveryScheduler = publicationDeliveryScheduler
        self.thirdPartyProcessingAdmission = thirdPartyProcessingAdmission
        self.now = now
    }

    deinit {
        tasksBySessionID.values.forEach { $0.cancel() }
        editTasksBySessionID.values.forEach { $0.cancel() }
        reloadTasksBySessionID.values.forEach { $0.cancel() }
        leasesBySessionID.values.forEach { $0.invalidate() }
    }

    func presentation(for session: RecordingSession) -> MeetingIntelligencePresentation {
        snapshot.presentation(for: session)?.presentation ?? .empty
    }

    /// Test-only synchronization that awaits concrete task completion instead
    /// of timing/yield polling. It intentionally has no production callers.
    func waitUntilIdleForTesting(sessionID: RecordingSession.ID) async {
        while true {
            if let task = tasksBySessionID[sessionID] {
                await task.value
                continue
            }
            if let task = editTasksBySessionID[sessionID] {
                _ = await task.value
                continue
            }
            if let task = reloadTasksBySessionID[sessionID] {
                await task.value
                continue
            }
            break
        }
    }

    func handleTranscriptPublished(_ event: TranscriptPublished) {
        let expectedTranscriptURL = TranscriptDocumentStore.editableURL(in: event.session.folderURL)
        let receivedTranscriptPath = event.canonicalURL.standardizedFileURL.path
        let normalizedReceivedTranscriptURL = RecordingLibraryURLIdentity.normalized(event.canonicalURL)
        let normalizedExpectedTranscriptURL = RecordingLibraryURLIdentity.normalized(expectedTranscriptURL)
        guard !isShutDown, !removedSessionIDs.contains(event.session.id),
              event.identity.coordinatorInstanceID == expectedPublicationSourceID,
              let session = canonicalSession(for: event.session),
              RecordingLibraryURLIdentity.normalized(event.normalizedSessionFolder).path == session.folderURL.path,
              // The callback must name the literal physical transcript path,
              // not a symlink that happens to resolve to it (or elsewhere).
              // Validate this before admitting work so the transcript reader
              // never receives an alias path.
              receivedTranscriptPath == normalizedReceivedTranscriptURL.path,
              normalizedReceivedTranscriptURL.path == normalizedExpectedTranscriptURL.path
        else { return }
        guard admitsThirdPartyProcessing() else { return }
        let canonicalEvent = TranscriptPublished(
            session: session,
            canonicalURL: normalizedExpectedTranscriptURL,
            revision: event.revision,
            normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
            identity: event.identity,
            workspaceFence: event.workspaceFence
        )
        let sessionID = session.id
        guard accepts(event.identity, after: latestPublicationsBySessionID[sessionID]) else { return }
        latestPublicationsBySessionID[sessionID] = event.identity
        sessionsByID[sessionID] = session
        let ticket = replaceWork(
            for: session,
            workspaceFence: event.workspaceFence
        )
        tasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: session) }
            await self.startAutomatic(event: canonicalEvent, ticket: ticket)
        }
    }

    func checkAvailability(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) {
        guard !isShutDown, let canonicalSession = canonicalSession(for: session) else { return }
        sessionsByID[canonicalSession.id] = canonicalSession
        guard admitsThirdPartyProcessing() else {
            setPrivacyModeUnavailable(for: canonicalSession)
            return
        }
        let ticket = replaceWork(for: canonicalSession, workspaceFence: workspaceFence)
        tasksBySessionID[canonicalSession.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: canonicalSession) }
            guard let snapshot = await self.snapshotIfUsable(for: canonicalSession, ticket: ticket) else { return }
            await self.setChecking(canonicalSession, snapshot: snapshot, revision: nil, ticket: ticket)
            let result = await self.availabilityChecker.availability(for: snapshot)
            guard self.owns(ticket, for: canonicalSession) else { return }
            await self.setAvailability(result, session: canonicalSession, snapshot: snapshot, ticket: ticket)
            self.clearTaskIfOwned(ticket, for: canonicalSession)
        }
    }

    func generate(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) { startManual(session: session, intent: .generate, workspaceFence: workspaceFence) }
    func regenerate(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) { startManual(session: session, intent: .regenerate, workspaceFence: workspaceFence) }
    func retryGeneration(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) { startManual(session: session, intent: .retryGeneration, workspaceFence: workspaceFence) }

    func saveEdit(
        for session: RecordingSession,
        capturedArtifact: MeetingIntelligenceArtifact,
        summary: String,
        suggestedTitle: String,
        capturedTranscriptRevision: TranscriptDocumentRevision? = nil,
        workspaceFence: WorkspacePublicationFence = .initial
    ) async -> MeetingIntelligenceEditSaveOutcome {
        guard !isShutDown,
              let canonicalSession = retainedCanonicalSession(for: session),
              tasksBySessionID[canonicalSession.id] == nil,
              editTasksBySessionID[canonicalSession.id] == nil,
              let editableContent = presentation(for: canonicalSession).editableContent,
              editableContent.artifact == capturedArtifact
        else {
            return .conflict(editMessage(for: .conflict))
        }
        let editTranscriptRevision = capturedTranscriptRevision ?? editableContent.transcriptRevision

        let ticket = replaceWork(for: canonicalSession, workspaceFence: workspaceFence)
        let capturedPublicationDelivery = onPublication
        let task: Task<MeetingIntelligenceEditSaveOutcome, Never> = Task { @MainActor [weak self] in
            guard let self else { return .conflict("The meeting intelligence edit was cancelled.") }
            defer {
                self.clearEditTaskIfOwned(ticket, for: canonicalSession)
                self.clearEditTicketIfMatching(ticket, for: canonicalSession)
            }
            return await self.saveEditOwned(
                session: canonicalSession,
                capturedArtifact: capturedArtifact,
                capturedTranscriptRevision: editTranscriptRevision,
                summary: summary,
                suggestedTitle: suggestedTitle,
                ticket: ticket,
                publicationDelivery: capturedPublicationDelivery
            )
        }
        editTasksBySessionID[canonicalSession.id] = task
        editTicketsBySessionID[canonicalSession.id] = ticket
        return await task.value
    }

    func cancel(sessionID: RecordingSession.ID) {
        guard let session = sessionsByID[sessionID], !isShutDown else { return }
        if editTasksBySessionID[sessionID] == nil,
           cancelledEditTicketsBySessionID[sessionID] != nil {
            return
        }
        let inFlightEdit = editTasksBySessionID[sessionID]
        let inFlightEditTicket = editTicketsBySessionID[sessionID]
        let ticket = replaceWork(for: session)
        cancelledSessionIDs.insert(sessionID)
        if let inFlightEditTicket {
            cancelledEditTicketsBySessionID[sessionID] = inFlightEditTicket
        }
        tasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: session) }
            if let inFlightEdit {
                let outcome = await inFlightEdit.value
                guard self.owns(ticket, for: session) else { return }
                if case .saved = outcome { return }
            }
            guard self.owns(ticket, for: session) else { return }
            self.setPresentation(.init(
                phase: .cancelled, summary: self.presentation(for: session).summary,
                suggestedTitle: self.presentation(for: session).suggestedTitle,
                statusMessage: "Meeting intelligence cancelled.", model: self.presentation(for: session).model,
                titleIsProtected: self.titleIsProtected(session), unavailableReason: nil
            ), for: session)
            await self.persist(.cancelled, message: "Meeting intelligence cancelled.", revision: nil,
                               ticket: ticket, for: session)
        }
    }

    func transcriptDidSave(_ session: RecordingSession) {
        guard !isShutDown, let canonicalSession = canonicalSession(for: session) else { return }
        sessionsByID[canonicalSession.id] = canonicalSession
        invalidateWork(for: canonicalSession.id)
        let ticket = replaceWork(for: canonicalSession)
        tasksBySessionID[canonicalSession.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: canonicalSession) }
            do {
                async let transcript = self.io.transcript(in: canonicalSession.folderURL)
                async let artifact = self.io.artifact(in: canonicalSession.folderURL)
                let (current, existing) = try await (transcript, artifact)
                guard self.owns(ticket, for: canonicalSession) else { return }
                if let existing, existing.sourceTranscriptSHA256 == current.revision.sha256,
                   existing.sourceTranscriptByteCount == current.revision.byteCount {
                    self.setPresentation(from: existing, phase: .ready, message: "Ready.", transcriptRevision: current.revision, session: canonicalSession)
                } else if let existing {
                    self.setPresentation(from: existing, phase: .stale, message: "Transcript changed. Regenerate to update.", transcriptRevision: current.revision, session: canonicalSession)
                } else { self.setPresentation(.empty, for: canonicalSession) }
                self.clearTaskIfOwned(ticket, for: canonicalSession)
            } catch {
                guard self.owns(ticket, for: canonicalSession) else { return }
                self.setFailed("Transcript needs attention.", for: canonicalSession)
                self.clearTaskIfOwned(ticket, for: canonicalSession)
            }
        }
    }

    func remove(sessionID: RecordingSession.ID) {
        // Do not normalize an arbitrary caller-provided URL into a deletion.
        // Only the exact canonical session retained by this coordinator may
        // clear an existing projection.
        guard let stored = sessionsByID[sessionID],
              let identity = MeetingIntelligenceSessionPresentationIdentity(session: stored)
        else { return }
        removedSessionIDs.insert(sessionID)
        cancelledSessionIDs.remove(sessionID)
        reloadTasksBySessionID.removeValue(forKey: sessionID)?.cancel()
        reloadTokensBySessionID.removeValue(forKey: sessionID)
        invalidateWork(for: sessionID)
        replaceSnapshot(snapshot.removing(identity))
        sessionsByID.removeValue(forKey: sessionID)
        latestPublicationsBySessionID.removeValue(forKey: sessionID)
    }

    func reload(sessions: [RecordingSession]) {
        guard !isShutDown else { return }
        // Reload is strictly observational. A transient library scan must not
        // imply that a session was deleted, nor cancel a live generation.
        // Explicit removal/trash paths call `remove(sessionID:)` themselves.
        for session in sessions {
            guard let canonicalSession = canonicalSession(for: session) else { continue }
            sessionsByID[canonicalSession.id] = canonicalSession
            removedSessionIDs.remove(canonicalSession.id)
            loadPresentation(for: canonicalSession)
        }
    }

    func applySuggestedTitle(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) {
        guard !isShutDown, let applier = titleApplier,
              let canonicalSession = canonicalSession(for: session) else { return }
        let ticket = replaceWork(for: canonicalSession, workspaceFence: workspaceFence)
        tasksBySessionID[canonicalSession.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: canonicalSession) }
            do {
                let artifact = try await self.io.artifact(in: canonicalSession.folderURL)
                let current = try await self.io.transcript(in: canonicalSession.folderURL)
                guard let artifact,
                      artifact.sourceTranscriptSHA256 == current.revision.sha256,
                      artifact.sourceTranscriptByteCount == current.revision.byteCount,
                      self.owns(ticket, for: canonicalSession) else { return }
                let applied = try await applier.applySuggestedTitle(.init(session: canonicalSession, artifact: artifact,
                                                                            sourceRevision: current.revision,
                                                                            capturedTitle: canonicalSession.metadata.title,
                                                                            capturedTitleOrigin: canonicalSession.metadata.titleOrigin,
                                                                            lease: ticket.lease))
                guard applied else { return }
                let publication = self.makePublication(
                    session: canonicalSession,
                    ticket: ticket,
                    revision: current.revision,
                    kind: .explicitSuggestedTitle,
                    artifact: nil,
                    titleOutcome: .explicitApplied
                )
                await self.deliverDurablePublication(publication)
            } catch {
                guard self.owns(ticket, for: canonicalSession), !Task.isCancelled else { return }
                self.setFailed(self.manualApplyFailureMessage(for: error), for: canonicalSession)
            }
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        reloadTasksBySessionID.values.forEach { $0.cancel() }
        reloadTasksBySessionID.removeAll()
        reloadTokensBySessionID.removeAll()
        for id in Set(tasksBySessionID.keys).union(editTasksBySessionID.keys) {
            invalidateWork(for: id)
        }
        tasksBySessionID.removeAll()
        attemptsBySessionID.removeAll()
        leasesBySessionID.removeAll()
        cancelledSessionIDs.removeAll()
    }

    /// Explicit workspace-cutover boundary. Library reload is observational;
    /// only a confirmed workspace switch is allowed to invalidate work that
    /// belongs to the old folder tree. Unlike shutdown, this coordinator can
    /// immediately accept sessions from the new workspace.
    func resetForWorkspaceChange() {
        guard !isShutDown else { return }
        reloadTasksBySessionID.values.forEach { $0.cancel() }
        reloadTasksBySessionID.removeAll()
        reloadTokensBySessionID.removeAll()
        for id in Set(tasksBySessionID.keys).union(editTasksBySessionID.keys) {
            invalidateWork(for: id)
        }
        tasksBySessionID.removeAll()
        // Keep the counters across a workspace cutover. A user can later
        // switch back to the same folder, whose IO actor has already observed
        // a higher generation; resetting to one would permanently reject all
        // subsequent state writes for that folder.
        attemptsBySessionID.removeAll()
        leasesBySessionID.removeAll()
        nextWriteSequenceBySessionID.removeAll()
        latestPublicationsBySessionID.removeAll()
        sessionsByID.removeAll()
        removedSessionIDs.removeAll()
        cancelledSessionIDs.removeAll()
        // A workspace boundary is visible even where its prior projection was
        // already empty, so the consumer can invalidate a captured snapshot.
        replaceSnapshot(snapshot.resettingWorkspace())
    }

    private func startAutomatic(event: TranscriptPublished, ticket: Ticket) async {
        let session = event.session
        let transcript: TranscriptDocumentSnapshot
        do {
            transcript = try await io.transcript(in: session.folderURL)
        } catch {
            guard owns(ticket, for: session) else { return }
            setFailed("Transcript needs attention.", for: session)
            return
        }
        guard owns(ticket, for: session), transcript.url == event.canonicalURL,
              transcript.revision == event.revision,
              normalizedFolder(for: session)?.path == event.normalizedSessionFolder.path else { return }
        // A persisted result for the exact canonical bytes is already the
        // desired automatic outcome; do not spend a fresh /models or chat call.
        let existingArtifact: MeetingIntelligenceArtifact?
        do {
            existingArtifact = try await io.artifact(in: session.folderURL)
        } catch {
            guard owns(ticket, for: session) else { return }
            setFailed("Meeting intelligence needs attention.", for: session)
            return
        }
        if let artifact = existingArtifact,
           artifact.sourceTranscriptSHA256 == transcript.revision.sha256,
           artifact.sourceTranscriptByteCount == transcript.revision.byteCount {
            guard owns(ticket, for: session) else { return }
            setPresentation(from: artifact, phase: .ready, message: "Ready.", transcriptRevision: transcript.revision, session: session)
            clearTaskIfOwned(ticket, for: session)
            return
        }
        guard let snapshot = await snapshotIfUsable(for: session, ticket: ticket) else { return }
        await setChecking(session, snapshot: snapshot, revision: transcript.revision, ticket: ticket)
        let availability = await availabilityChecker.availability(for: snapshot)
        guard owns(ticket, for: session) else { return }
        guard case .confirmed = availability else {
            await setAvailability(availability, session: session, snapshot: snapshot, ticket: ticket)
            clearTaskIfOwned(ticket, for: session)
            return
        }
        await generateOwned(session: session, transcript: transcript, snapshot: snapshot,
                            intent: .automatic, ticket: ticket)
    }

    private func startManual(
        session: RecordingSession,
        intent: MeetingIntelligenceIntent,
        workspaceFence: WorkspacePublicationFence
    ) {
        guard !isShutDown, let canonicalSession = canonicalSession(for: session) else { return }
        sessionsByID[canonicalSession.id] = canonicalSession
        guard admitsThirdPartyProcessing() else {
            setPrivacyModeUnavailable(for: canonicalSession)
            return
        }
        let ticket = replaceWork(for: canonicalSession, workspaceFence: workspaceFence)
        tasksBySessionID[canonicalSession.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: canonicalSession) }
            guard let snapshot = await self.snapshotIfUsable(for: canonicalSession, ticket: ticket) else { return }
            let transcript: TranscriptDocumentSnapshot
            do {
                transcript = try await self.io.transcript(in: canonicalSession.folderURL)
            } catch {
                guard self.owns(ticket, for: canonicalSession), !Task.isCancelled else { return }
                self.setFailed("Transcript needs attention.", for: canonicalSession)
                return
            }
            guard self.owns(ticket, for: canonicalSession) else { return }
            await self.generateOwned(session: canonicalSession, transcript: transcript, snapshot: snapshot,
                                     intent: intent, ticket: ticket)
        }
    }

    private func generateOwned(
        session: RecordingSession,
        transcript: TranscriptDocumentSnapshot,
        snapshot: OpenAICompatibleProviderSnapshot,
        intent: MeetingIntelligenceIntent,
        ticket: Ticket
    ) async {
        guard owns(ticket, for: session) else { return }
        setPresentation(.init(phase: .generating(.init(stage: .generatingFinal, current: 0, total: 0)),
                              summary: presentation(for: session).summary, suggestedTitle: presentation(for: session).suggestedTitle,
                              statusMessage: "Generating meeting intelligence…", model: snapshot.profile.llmModel,
                              titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
        await persist(.generating, message: "Generating meeting intelligence.", revision: transcript.revision,
                      ticket: ticket, for: session)
        guard owns(ticket, for: session), !Task.isCancelled else { return }
        do {
            let content = try await generator.generate(transcript: transcript, snapshot: snapshot) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.owns(ticket, for: session) else { return }
                    self.setPresentation(.init(phase: .generating(progress), summary: self.presentation(for: session).summary,
                                               suggestedTitle: self.presentation(for: session).suggestedTitle,
                                               statusMessage: "Generating meeting intelligence…", model: snapshot.profile.llmModel,
                                               titleIsProtected: self.titleIsProtected(session), unavailableReason: nil), for: session)
                }
            }
            guard owns(ticket, for: session), !Task.isCancelled else { return }
            let outcome = try await io.publish(.init(session: session, sourceRevision: transcript.revision,
                                                      capturedTitle: session.metadata.title,
                                                      capturedTitleOrigin: session.metadata.titleOrigin,
                                                      content: content, snapshot: snapshot, intent: intent,
                                                      generatedAt: now(), lease: ticket.lease))
            // A successful publisher return is the durable semantic boundary.
            // The typed event is deliberately delivered before lifecycle UI
            // checks: cancellation/removal after this point cannot erase one
            // already-committed Library refresh.
            let publication = makePublication(
                session: session,
                ticket: ticket,
                revision: transcript.revision,
                kind: .artifactAndAutomaticTitle,
                artifact: outcome.artifact,
                titleOutcome: outcome.titleOutcome
            )
            await deliverDurablePublication(publication)
            guard owns(ticket, for: session), !Task.isCancelled else { return }
            setPresentation(from: outcome.artifact, phase: .ready,
                            message: outcome.titleWarning ?? "Ready.",
                            transcriptRevision: transcript.revision,
                            session: session)
            // Publication is the semantic success boundary. State persistence
            // is recovery-only and may be delayed/cancelled without changing
            // the one successful library/search refresh callback.
            await persist(.completed, message: outcome.titleWarning ?? "Ready.", revision: transcript.revision,
                          ticket: ticket, for: session)
            clearTaskIfOwned(ticket, for: session)
        } catch is CancellationError {
            await finishCancellationIfOwned(ticket, session: session)
        } catch {
            guard owns(ticket, for: session), !Task.isCancelled else { return }
            let message = failureMessage(for: error)
            setFailed(message, for: session)
            await persist(.failed, message: message, revision: transcript.revision, ticket: ticket, for: session)
            clearTaskIfOwned(ticket, for: session)
        }
    }

    private func saveEditOwned(
        session: RecordingSession,
        capturedArtifact: MeetingIntelligenceArtifact,
        capturedTranscriptRevision: TranscriptDocumentRevision,
        summary: String,
        suggestedTitle: String,
        ticket: Ticket,
        publicationDelivery: ((MeetingIntelligencePublished) -> Void)?
    ) async -> MeetingIntelligenceEditSaveOutcome {
        guard owns(ticket, for: session), !Task.isCancelled else {
            return .conflict(editMessage(for: .leaseInvalid))
        }

        let request = MeetingIntelligenceArtifactEditRequest(
            session: session,
            capturedArtifact: capturedArtifact,
            capturedTranscriptRevision: capturedTranscriptRevision,
            proposedSummary: summary,
            proposedSuggestedTitle: suggestedTitle,
            editedAt: now(),
            lease: ticket.lease
        )

        do {
            let editedArtifact = try await io.edit(request)
            // A successful editor return is the durable semantic boundary. It
            // remains one publication even when a competing command or
            // lifecycle transition invalidates this ticket while delivery is
            // delayed.
            let publication = makePublication(
                session: session,
                ticket: ticket,
                revision: .init(
                    sha256: editedArtifact.sourceTranscriptSHA256,
                    byteCount: editedArtifact.sourceTranscriptByteCount
                ),
                kind: .editedArtifact,
                artifact: editedArtifact,
                titleOutcome: .preserved
            )
            await deliverDurablePublication(publication, capturedDelivery: publicationDelivery)

            // A newer generation/edit/remove owns the presentation now. The
            // durable edit is still saved and published, but its late result
            // must not overwrite that canonical latest projection.
            guard acceptsEditProjection(ticket, for: session) else {
                return editProjectionFailure(for: session)
            }
            let projection = await editProjection(
                for: editedArtifact,
                session: session,
                fallbackRevision: capturedTranscriptRevision
            )
            guard acceptsEditProjection(ticket, for: session) else {
                return editProjectionFailure(for: session)
            }
            guard setPresentation(
                from: editedArtifact,
                phase: projection.phase,
                message: projection.message,
                transcriptRevision: projection.transcriptRevision,
                session: session
            ) else {
                return editProjectionFailure(for: session)
            }
            return .saved(editedArtifact)
        } catch is CancellationError {
            return .conflict(editMessage(for: .leaseInvalid))
        } catch {
            return editOutcome(for: error)
        }
    }

    private func editProjection(
        for artifact: MeetingIntelligenceArtifact,
        session: RecordingSession,
        fallbackRevision: TranscriptDocumentRevision
    ) async -> (
        phase: MeetingIntelligencePresentation.Phase,
        message: String,
        transcriptRevision: TranscriptDocumentRevision
    ) {
        do {
            let transcript = try await io.transcript(in: session.folderURL)
            guard transcript.revision.sha256 == artifact.sourceTranscriptSHA256,
                  transcript.revision.byteCount == artifact.sourceTranscriptByteCount else {
                return (.stale, "Transcript changed. Regenerate to update.", transcript.revision)
            }
            return (.ready, "Ready.", transcript.revision)
        } catch {
            // The editor already validated the transcript before durable
            // promotion. A later observational read must not turn that durable
            // success into a user-visible failure.
            guard fallbackRevision.sha256 == artifact.sourceTranscriptSHA256,
                  fallbackRevision.byteCount == artifact.sourceTranscriptByteCount else {
                return (.stale, "Transcript changed. Regenerate to update.", fallbackRevision)
            }
            return (.ready, "Ready.", fallbackRevision)
        }
    }

    private func snapshotIfUsable(for session: RecordingSession, ticket: Ticket) async -> OpenAICompatibleProviderSnapshot? {
        do {
            let snapshot = try await io.snapshot()
            guard owns(ticket, for: session) else { return nil }
            guard isUsableModel(snapshot.profile.llmModel) else {
                await setUnavailable(.placeholderModel, session: session, snapshot: snapshot, ticket: ticket)
                return nil
            }
            return snapshot
        } catch {
            guard owns(ticket, for: session), !Task.isCancelled else { return nil }
            setFailed("Configure an AI provider before generating.", for: session)
            return nil
        }
    }

    private func setChecking(_ session: RecordingSession, snapshot: OpenAICompatibleProviderSnapshot,
                             revision: TranscriptDocumentRevision?, ticket: Ticket? = nil) async {
        setPresentation(.init(phase: .checkingAvailability, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle,
                              statusMessage: "Checking model availability…", model: snapshot.profile.llmModel,
                              titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
        if let ticket { await persist(.checkingAvailability, message: "Checking availability.", revision: revision, ticket: ticket, for: session) }
    }

    private func setAvailability(_ availability: MeetingIntelligenceAvailability, session: RecordingSession, snapshot: OpenAICompatibleProviderSnapshot, ticket: Ticket? = nil) async {
        switch availability {
        case .confirmed:
            setPresentation(.init(phase: .notGenerated, summary: presentation(for: session).summary,
                                  suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: "Model is available.",
                                  model: snapshot.profile.llmModel, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
            if let ticket { await persist(.completed, message: "Model is available.", revision: nil, ticket: ticket, for: session) }
        case .unconfirmed(let reason): await setUnavailable(reason, session: session, snapshot: snapshot, ticket: ticket)
        }
    }

    private func setUnavailable(_ reason: MeetingIntelligenceUnavailableReason, session: RecordingSession, snapshot: OpenAICompatibleProviderSnapshot, ticket: Ticket? = nil) async {
        setPresentation(.init(phase: .notGenerated, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: "Automatic generation is unavailable.",
                              model: snapshot.profile.llmModel, titleIsProtected: titleIsProtected(session), unavailableReason: reason), for: session)
        if let ticket { await persist(.completed, message: "Automatic generation is unavailable.", revision: nil, ticket: ticket, for: session) }
    }

    private func admitsThirdPartyProcessing() -> Bool {
        thirdPartyProcessingAdmission?.admitThirdPartyProcessing() != .blockedLocalOnly
    }

    private func setPrivacyModeUnavailable(for session: RecordingSession) {
        let current = presentation(for: session)
        setPresentation(.init(
            phase: current.phase,
            summary: current.summary,
            suggestedTitle: current.suggestedTitle,
            statusMessage: PrivacyModePolicy.localOnlyMessage,
            model: current.model,
            titleIsProtected: titleIsProtected(session),
            unavailableReason: .privacyModeEnabled,
            editableContent: current.editableContent
        ), for: session)
    }

    private func loadPresentation(for session: RecordingSession) {
        // Reload is observational only. It deliberately owns a distinct token
        // and never replaces/cancels an active generation.
        guard tasksBySessionID[session.id] == nil,
              editTasksBySessionID[session.id] == nil else { return }
        reloadTasksBySessionID.removeValue(forKey: session.id)?.cancel()
        let token = UUID()
        reloadTokensBySessionID[session.id] = token
        reloadTasksBySessionID[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.reloadTokensBySessionID[session.id] == token {
                    self.reloadTasksBySessionID.removeValue(forKey: session.id)
                    self.reloadTokensBySessionID.removeValue(forKey: session.id)
                }
            }
            do {
                async let artifact = self.io.artifact(in: session.folderURL)
                async let state = self.io.state(in: session.folderURL)
                let (existing, recovered) = try await (artifact, state)
                guard self.reloadTokensBySessionID[session.id] == token,
                      self.tasksBySessionID[session.id] == nil,
                      self.editTasksBySessionID[session.id] == nil,
                      !self.isShutDown,
                      !self.removedSessionIDs.contains(session.id) else { return }
                if let existing {
                    let source = try await self.io.transcript(in: session.folderURL)
                    guard self.reloadTokensBySessionID[session.id] == token,
                          self.tasksBySessionID[session.id] == nil,
                          self.editTasksBySessionID[session.id] == nil else { return }
                    let phase: MeetingIntelligencePresentation.Phase = existing.sourceTranscriptSHA256 == source.revision.sha256 && existing.sourceTranscriptByteCount == source.revision.byteCount ? .ready : .stale
                    self.setPresentation(from: existing, phase: phase, message: phase == .ready ? "Ready." : "Transcript changed. Regenerate to update.", transcriptRevision: source.revision, session: session)
                } else if let recovered,
                          [.interrupted, .checkingAvailability, .generating].contains(recovered.phase) {
                    self.setPresentation(.init(phase: .interrupted, summary: nil, suggestedTitle: nil,
                                               statusMessage: "Meeting intelligence interrupted. You can generate again.",
                                               model: nil, titleIsProtected: self.titleIsProtected(session), unavailableReason: nil), for: session)
                }
            } catch {
                guard self.reloadTokensBySessionID[session.id] == token,
                      self.tasksBySessionID[session.id] == nil,
                      self.editTasksBySessionID[session.id] == nil,
                      !self.isShutDown,
                      !self.removedSessionIDs.contains(session.id) else { return }
                self.setFailed("Meeting intelligence needs attention.", for: session)
            }
        }
    }

    @discardableResult
    private func setPresentation(
        from artifact: MeetingIntelligenceArtifact,
        phase: MeetingIntelligencePresentation.Phase,
        message: String,
        transcriptRevision: TranscriptDocumentRevision,
        session: RecordingSession
    ) -> Bool {
        let editableContent: MeetingIntelligenceEditableContent?
        switch phase {
        case .ready, .stale:
            editableContent = MeetingIntelligenceArtifactValidator.isValid(artifact)
                ? .init(artifact: artifact, transcriptRevision: transcriptRevision)
                : nil
        default:
            editableContent = nil
        }
        return setPresentation(.init(phase: phase, summary: artifact.summary, suggestedTitle: artifact.suggestedTitle,
                                     statusMessage: message, model: artifact.model, titleIsProtected: titleIsProtected(session), unavailableReason: nil,
                                     editableContent: editableContent), for: session)
    }

    private func setFailed(_ message: String, for session: RecordingSession) {
        setPresentation(.init(phase: .failed, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: message,
                              model: presentation(for: session).model, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
    }

    @discardableResult
    private func setPresentation(_ value: MeetingIntelligencePresentation, for session: RecordingSession) -> Bool {
        guard !isShutDown, !removedSessionIDs.contains(session.id) else { return false }
        guard let next = snapshot.replacing(value, for: session) else {
            return presentation(for: session) == value
        }
        replaceSnapshot(next)
        return true
    }

    private func replaceSnapshot(_ next: MeetingIntelligenceFeatureSnapshot?) {
        guard let next else { return }
        snapshot = next
        onSnapshotDidChange?(next)
    }

    private func persist(
        _ phase: MeetingIntelligenceStatePhase,
        message: String,
        revision: TranscriptDocumentRevision?,
        ticket: Ticket,
        for session: RecordingSession
    ) async {
        guard owns(ticket, for: session), !Task.isCancelled else { return }
        let sequence = nextSequence(for: session, ticket: ticket)
        let state = MeetingIntelligenceState(schemaVersion: MeetingIntelligenceState.currentSchemaVersion, phase: phase,
                                             message: sanitized(message), sourceTranscriptSHA256: revision?.sha256,
                                             startedAt: ticket.startedAt,
                                             finishedAt: [.completed, .failed, .cancelled, .interrupted].contains(phase) ? now() : nil)
        do {
            try await io.save(state, in: session.folderURL, generation: ticket.generation,
                              attempt: ticket.attempt, sequence: sequence, lease: ticket.lease)
        } catch {
            // State persistence is diagnostic/recovery data. The attempt
            // remains valid; user-visible completion must not turn into a
            // provider failure solely because this optional state file failed.
        }
    }

    private struct Ticket: Equatable {
        let generation: UInt64
        let attempt: UUID
        let lease: MeetingIntelligenceAttemptLease
        let startedAt: Date
        let workspaceFence: WorkspacePublicationFence
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.generation == rhs.generation && lhs.attempt == rhs.attempt }
    }

    private func replaceWork(
        for session: RecordingSession,
        workspaceFence: WorkspacePublicationFence = .initial
    ) -> Ticket {
        invalidateWork(for: session.id)
        cancelledSessionIDs.remove(session.id)
        let generation = (generationsBySessionID[session.id] ?? 0) &+ 1
        let attempt = UUID()
        let lease = MeetingIntelligenceAttemptLease()
        generationsBySessionID[session.id] = generation
        attemptsBySessionID[session.id] = attempt
        leasesBySessionID[session.id] = lease
        nextWriteSequenceBySessionID[session.id] = 0
        reloadTasksBySessionID.removeValue(forKey: session.id)?.cancel()
        reloadTokensBySessionID.removeValue(forKey: session.id)
        return .init(
            generation: generation,
            attempt: attempt,
            lease: lease,
            startedAt: now(),
            workspaceFence: workspaceFence
        )
    }

    private func invalidateWork(for sessionID: RecordingSession.ID) {
        leasesBySessionID[sessionID]?.invalidate()
        tasksBySessionID.removeValue(forKey: sessionID)?.cancel()
        editTasksBySessionID.removeValue(forKey: sessionID)?.cancel()
        editTicketsBySessionID.removeValue(forKey: sessionID)
        cancelledEditTicketsBySessionID.removeValue(forKey: sessionID)
        attemptsBySessionID.removeValue(forKey: sessionID)
        leasesBySessionID.removeValue(forKey: sessionID)
    }

    private func owns(_ ticket: Ticket, for session: RecordingSession) -> Bool {
        !isShutDown && !removedSessionIDs.contains(session.id) && ticket.lease.isValid &&
            generationsBySessionID[session.id] == ticket.generation && attemptsBySessionID[session.id] == ticket.attempt
    }

    private func acceptsEditProjection(_ ticket: Ticket, for session: RecordingSession) -> Bool {
        guard !isShutDown,
              !removedSessionIDs.contains(session.id),
              sessionsByID[session.id] != nil else { return false }
        if owns(ticket, for: session) { return true }
        return cancelledEditTicketsBySessionID[session.id] == ticket
    }

    private func clearTaskIfOwned(_ ticket: Ticket, for session: RecordingSession) {
        guard owns(ticket, for: session) else { return }
        tasksBySessionID.removeValue(forKey: session.id)
        attemptsBySessionID.removeValue(forKey: session.id)
        leasesBySessionID.removeValue(forKey: session.id)
        nextWriteSequenceBySessionID.removeValue(forKey: session.id)
    }

    private func clearEditTaskIfOwned(_ ticket: Ticket, for session: RecordingSession) {
        guard owns(ticket, for: session) else { return }
        editTasksBySessionID.removeValue(forKey: session.id)
        attemptsBySessionID.removeValue(forKey: session.id)
        leasesBySessionID.removeValue(forKey: session.id)
        nextWriteSequenceBySessionID.removeValue(forKey: session.id)
    }

    private func clearEditTicketIfMatching(_ ticket: Ticket, for session: RecordingSession) {
        guard editTicketsBySessionID[session.id] == ticket else { return }
        editTicketsBySessionID.removeValue(forKey: session.id)
        if cancelledEditTicketsBySessionID[session.id] == ticket {
            cancelledEditTicketsBySessionID.removeValue(forKey: session.id)
        }
    }

    private func canonicalSession(for session: RecordingSession) -> RecordingSession? {
        let folder = RecordingLibraryURLIdentity.normalized(session.folderURL)
        let recording = RecordingLibraryURLIdentity.normalized(session.recordingURL)
        guard session.id.path == folder.path,
              session.folderURL.path == folder.path,
              session.recordingURL.path == recording.path else { return nil }
        // URL equality also incorporates directory-hint representation on
        // Darwin. The verified input path is already physical/canonical; keep
        // the Library's value identity unchanged for task dictionaries.
        return session
    }

    private func retainedCanonicalSession(for session: RecordingSession) -> RecordingSession? {
        guard canonicalSession(for: session) != nil,
              let retained = sessionsByID[session.id],
              canonicalSession(for: retained) != nil,
              RecordingLibraryURLIdentity.normalized(retained.folderURL).path
                  == RecordingLibraryURLIdentity.normalized(session.folderURL).path,
              RecordingLibraryURLIdentity.normalized(retained.recordingURL).path
                  == RecordingLibraryURLIdentity.normalized(session.recordingURL).path
        else { return nil }
        return retained
    }

    private func editOutcome(for error: Error) -> MeetingIntelligenceEditSaveOutcome {
        if let error = error as? MeetingIntelligenceArtifactEditError {
            switch error {
            case .invalidSummary:
                return .invalidSummary(editMessage(for: error))
            case .invalidSuggestedTitle:
                return .invalidSuggestedTitle(editMessage(for: error))
            case .conflict, .transcriptChanged, .leaseInvalid:
                return .conflict(editMessage(for: error))
            case .unsafeSessionFolder, .storageFailure:
                return .failed(editMessage(for: error))
            }
        }
        if error is CancellationError {
            return .conflict(editMessage(for: .leaseInvalid))
        }
        return .failed(editMessage(for: .storageFailure))
    }

    private func editMessage(for error: MeetingIntelligenceArtifactEditError) -> String {
        switch error {
        case .invalidSummary:
            return "The meeting intelligence summary is invalid."
        case .invalidSuggestedTitle:
            return "The meeting intelligence suggested title is invalid."
        case .conflict:
            return "Meeting intelligence changed before the edit could be saved."
        case .transcriptChanged:
            return "The transcript changed before the edit could be saved."
        case .leaseInvalid:
            return "The meeting intelligence edit was cancelled."
        case .unsafeSessionFolder, .storageFailure:
            return "The meeting intelligence edit could not be saved."
        }
    }

    private func editProjectionFailure(for session: RecordingSession) -> MeetingIntelligenceEditSaveOutcome {
        if isShutDown || removedSessionIDs.contains(session.id) || cancelledSessionIDs.contains(session.id) || sessionsByID[session.id] == nil ||
            presentation(for: session).phase == .cancelled {
            return .conflict(editMessage(for: .leaseInvalid))
        }
        return .conflict(editMessage(for: .conflict))
    }

    private func makePublication(
        session: RecordingSession,
        ticket: Ticket,
        revision: TranscriptDocumentRevision,
        kind: MeetingIntelligencePublicationKind,
        artifact: MeetingIntelligenceArtifact?,
        titleOutcome: MeetingIntelligenceTitleOutcome
    ) -> MeetingIntelligencePublished {
        // Commands are admitted through canonicalSession(for:) before work
        // starts. A durable publisher return can therefore never encounter a
        // new identity rejection at delivery time.
        precondition(session.id.path == session.folderURL.path)
        return .init(
            identity: .init(
                coordinatorInstanceID: publicationSourceID,
                sessionID: session.id,
                normalizedSessionFolder: RecordingLibraryURLIdentity.normalized(session.folderURL),
                generation: ticket.generation,
                attemptID: ticket.attempt,
                transcriptRevision: revision,
                workspaceFence: ticket.workspaceFence,
                kind: kind
            ),
            canonicalSession: session,
            artifact: artifact,
            titleOutcome: titleOutcome
        )
    }

    private func deliverDurablePublication(
        _ publication: MeetingIntelligencePublished,
        capturedDelivery: ((MeetingIntelligencePublished) -> Void)? = nil
    ) async {
        // Capture the recipient at the durable boundary. Feature shutdown is
        // permitted to detach its live callback, but it cannot erase a
        // semantic publication whose artifact/title mutation has committed.
        let delivery = capturedDelivery ?? onPublication
        await publicationDeliveryScheduler.awaitDeliveryAdmission()
        // Do not consult task ownership or cancellation here. Publisher/title
        // success is the durable boundary, and this one semantic event must
        // survive later cancellation, removal, or shutdown.
        delivery?(publication)
    }

    private func finishCancellationIfOwned(_ ticket: Ticket, session: RecordingSession) async {
        guard owns(ticket, for: session) else { return }
        setPresentation(.init(phase: .cancelled, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: "Meeting intelligence cancelled.",
                              model: presentation(for: session).model, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
        await persist(.cancelled, message: "Meeting intelligence cancelled.", revision: nil,
                      ticket: ticket, for: session)
        clearTaskIfOwned(ticket, for: session)
    }

    private func accepts(_ incoming: TranscriptPublicationIdentity, after current: TranscriptPublicationIdentity?) -> Bool {
        guard let current else { return true }
        guard current.coordinatorInstanceID == incoming.coordinatorInstanceID else { return false }
        // A TranscriptionJobCoordinator generation identifies one completed
        // publication attempt.  UUIDs are not ordered, so accepting another
        // UUID at the same generation would let a forged/late callback start
        // a second automatic job.
        return incoming.generation > current.generation
    }

    private func titleIsProtected(_ session: RecordingSession) -> Bool { session.metadata.titleOrigin == .manual }
    private func isUsableModel(_ model: String) -> Bool { let v = model.trimmingCharacters(in: .whitespacesAndNewlines); return !v.isEmpty && v != "legacy-unconfigured-llm" }
    private func sanitized(_ message: String) -> String { String(message.unicodeScalars.filter { $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t" }.map(String.init).joined().prefix(1_024)) }
    private func normalizedFolder(for session: RecordingSession) -> URL? {
        let folder = RecordingLibraryURLIdentity.normalized(session.folderURL)
        return RecordingLibraryURLIdentity.normalized(session.id).path == folder.path ? folder : nil
    }
    private func failureMessage(for error: Error) -> String {
        switch error {
        case is CancellationError: return "Meeting intelligence cancelled."
        case MeetingIntelligencePipelineError.cancelled: return "Meeting intelligence cancelled."
        case MeetingIntelligencePipelineError.deadlineExceeded: return "Meeting intelligence timed out. You can retry generation."
        case MeetingIntelligencePipelineError.sourceTooLarge: return "The transcript is too large to summarize."
        case MeetingIntelligencePublicationError.transcriptChanged: return "Transcript changed. Regenerate to update."
        case MeetingIntelligencePublicationError.leaseInvalid: return "Meeting intelligence cancelled."
        default: return "Meeting intelligence could not be completed. You can retry generation."
        }
    }

    private func manualApplyFailureMessage(for error: Error) -> String {
        switch error {
        case MeetingIntelligencePublicationError.transcriptChanged:
            return "The transcript changed. Generate a new suggested title before applying it."
        case MeetingIntelligencePublicationError.leaseInvalid, is CancellationError:
            return "Applying the suggested title was cancelled."
        default:
            return "The suggested title could not be applied. You can try again."
        }
    }

    private func nextSequence(for session: RecordingSession, ticket: Ticket) -> UInt64 {
        guard owns(ticket, for: session) else { return 0 }
        let next = (nextWriteSequenceBySessionID[session.id] ?? 0) &+ 1
        nextWriteSequenceBySessionID[session.id] = next
        return next
    }
}
