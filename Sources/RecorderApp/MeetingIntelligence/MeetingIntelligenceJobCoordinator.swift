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

protocol MeetingIntelligenceSuggestedTitleApplying: Sendable {
    func applySuggestedTitle(
        _ request: MeetingIntelligenceSuggestedTitleRequest
    ) async throws -> Bool
}

/// A concrete applier must validate `lease` and `sourceRevision` again inside
/// the shared session mutation gate before changing metadata.
struct MeetingIntelligenceSuggestedTitleRequest: Sendable {
    let session: RecordingSession
    let artifact: MeetingIntelligenceArtifact
    let sourceRevision: TranscriptDocumentRevision
    let lease: MeetingIntelligenceAttemptLease
}

private actor MeetingIntelligenceIO {
    private let repository: any OpenAICompatibleProviderManaging
    private let reader: any TranscriptDocumentReading
    private let artifacts: any MeetingIntelligenceArtifactStoring
    private let states: any MeetingIntelligenceStateStoring
    private var latestGenerationByFolder: [URL: UInt64] = [:]
    private var disabledFolders = Set<URL>()

    init(repository: any OpenAICompatibleProviderManaging, reader: any TranscriptDocumentReading,
         artifacts: any MeetingIntelligenceArtifactStoring, states: any MeetingIntelligenceStateStoring) {
        self.repository = repository; self.reader = reader; self.artifacts = artifacts; self.states = states
    }
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { try repository.snapshot() }
    func transcript(in folder: URL) throws -> TranscriptDocumentSnapshot { try reader.readCanonical(in: folder, allowLegacy: false) }
    func artifact(in folder: URL) throws -> MeetingIntelligenceArtifact? { try artifacts.load(in: folder) }
    func state(in folder: URL) throws -> MeetingIntelligenceState? { try states.load(in: folder) }
    func save(_ state: MeetingIntelligenceState, in folder: URL, generation: UInt64) throws {
        guard !disabledFolders.contains(folder) else { return }
        latestGenerationByFolder[folder] = max(latestGenerationByFolder[folder] ?? 0, generation)
        guard latestGenerationByFolder[folder] == generation else { return }
        try states.save(state, in: folder)
    }
    func disable(folder: URL) { disabledFolders.insert(folder) }
}

@MainActor
final class MeetingIntelligenceJobCoordinator: ObservableObject {
    typealias DateNow = @Sendable () -> Date

    var onSuccessfulPublication: ((RecordingSession) -> Void)?

    private let expectedPublicationSourceID: UUID
    private let io: MeetingIntelligenceIO
    private let availabilityChecker: any MeetingIntelligenceAvailabilityChecking
    private let generator: any MeetingIntelligenceGenerating
    private let publisher: any MeetingIntelligencePublishing
    private let artifactStore: any MeetingIntelligenceArtifactStoring
    private let stateStore: any MeetingIntelligenceStateStoring
    private let titleApplier: (any MeetingIntelligenceSuggestedTitleApplying)?
    private let now: DateNow

    private var tasksBySessionID: [RecordingSession.ID: Task<Void, Never>] = [:]
    private var generationsBySessionID: [RecordingSession.ID: UInt64] = [:]
    private var attemptsBySessionID: [RecordingSession.ID: UUID] = [:]
    private var leasesBySessionID: [RecordingSession.ID: MeetingIntelligenceAttemptLease] = [:]
    private var latestPublicationsBySessionID: [RecordingSession.ID: TranscriptPublicationIdentity] = [:]
    private var sessionsByID: [RecordingSession.ID: RecordingSession] = [:]
    private var removedSessionIDs = Set<RecordingSession.ID>()
    private var isShutDown = false
    @Published private var presentationsBySessionID: [RecordingSession.ID: MeetingIntelligencePresentation] = [:]

    init(
        providerRepository: any OpenAICompatibleProviderManaging,
        expectedPublicationSourceID: UUID,
        transcriptReader: any TranscriptDocumentReading = SecureTranscriptDocumentReader(),
        availabilityChecker: any MeetingIntelligenceAvailabilityChecking,
        generator: any MeetingIntelligenceGenerating,
        publisher: any MeetingIntelligencePublishing,
        artifactStore: any MeetingIntelligenceArtifactStoring,
        stateStore: any MeetingIntelligenceStateStoring,
        titleApplier: (any MeetingIntelligenceSuggestedTitleApplying)? = nil,
        now: @escaping DateNow = { Date() }
    ) {
        self.expectedPublicationSourceID = expectedPublicationSourceID
        io = .init(repository: providerRepository, reader: transcriptReader,
                   artifacts: artifactStore, states: stateStore)
        self.availabilityChecker = availabilityChecker
        self.generator = generator
        self.publisher = publisher
        self.artifactStore = artifactStore
        self.stateStore = stateStore
        self.titleApplier = titleApplier
        self.now = now
    }

    deinit {
        tasksBySessionID.values.forEach { $0.cancel() }
        leasesBySessionID.values.forEach { $0.invalidate() }
    }

    func presentation(for session: RecordingSession) -> MeetingIntelligencePresentation {
        presentationsBySessionID[session.id] ?? .empty
    }

    func handleTranscriptPublished(_ event: TranscriptPublished) {
        guard !isShutDown, !removedSessionIDs.contains(event.session.id),
              event.identity.coordinatorInstanceID == expectedPublicationSourceID else { return }
        let sessionID = event.session.id
        guard accepts(event.identity, after: latestPublicationsBySessionID[sessionID]) else { return }
        latestPublicationsBySessionID[sessionID] = event.identity
        sessionsByID[sessionID] = event.session
        let ticket = replaceWork(for: event.session)
        tasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: event.session) }
            await self.startAutomatic(event: event, ticket: ticket)
        }
    }

    func checkAvailability(for session: RecordingSession) {
        guard !isShutDown else { return }
        sessionsByID[session.id] = session
        let ticket = replaceWork(for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: session) }
            guard let snapshot = await self.snapshotIfUsable(for: session, ticket: ticket) else { return }
            self.setChecking(session, snapshot: snapshot, revision: nil)
            let result = await self.availabilityChecker.availability(for: snapshot)
            guard self.owns(ticket, for: session) else { return }
            self.setAvailability(result, session: session, snapshot: snapshot)
            self.clearTaskIfOwned(ticket, for: session)
        }
    }

    func generate(for session: RecordingSession) { startManual(session: session, intent: .generate) }
    func regenerate(for session: RecordingSession) { startManual(session: session, intent: .regenerate) }
    func retryGeneration(for session: RecordingSession) { startManual(session: session, intent: .retryGeneration) }

    func cancel(sessionID: RecordingSession.ID) {
        guard let session = sessionsByID[sessionID], !isShutDown else { return }
        invalidateWork(for: sessionID)
        setPresentation(.init(
            phase: .cancelled, summary: presentation(for: session).summary,
            suggestedTitle: presentation(for: session).suggestedTitle,
            statusMessage: "Meeting intelligence cancelled.", model: presentation(for: session).model,
            titleIsProtected: titleIsProtected(session), unavailableReason: nil
        ), for: session)
        persist(.cancelled, message: "Meeting intelligence cancelled.", revision: nil, for: session)
    }

    func transcriptDidSave(_ session: RecordingSession) {
        guard !isShutDown else { return }
        sessionsByID[session.id] = session
        invalidateWork(for: session.id)
        let ticket = replaceWork(for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: session) }
            do {
                async let transcript = self.io.transcript(in: session.folderURL)
                async let artifact = self.io.artifact(in: session.folderURL)
                let (current, existing) = try await (transcript, artifact)
                guard self.owns(ticket, for: session) else { return }
                if let existing, existing.sourceTranscriptSHA256 == current.revision.sha256,
                   existing.sourceTranscriptByteCount == current.revision.byteCount {
                    self.setPresentation(from: existing, phase: .ready, message: "Ready.", session: session)
                } else if let existing {
                    self.setPresentation(from: existing, phase: .stale, message: "Transcript changed. Regenerate to update.", session: session)
                } else { self.setPresentation(.empty, for: session) }
                self.clearTaskIfOwned(ticket, for: session)
            } catch {
                guard self.owns(ticket, for: session) else { return }
                self.setFailed("Transcript needs attention.", for: session)
                self.clearTaskIfOwned(ticket, for: session)
            }
        }
    }

    func remove(sessionID: RecordingSession.ID) {
        if let session = sessionsByID[sessionID] {
            Task { await io.disable(folder: session.folderURL) }
        }
        removedSessionIDs.insert(sessionID)
        invalidateWork(for: sessionID)
        presentationsBySessionID.removeValue(forKey: sessionID)
        sessionsByID.removeValue(forKey: sessionID)
        latestPublicationsBySessionID.removeValue(forKey: sessionID)
    }

    func reload(sessions: [RecordingSession]) {
        guard !isShutDown else { return }
        let alive = Set(sessions.map(\.id))
        for id in Set(sessionsByID.keys).subtracting(alive) { remove(sessionID: id) }
        for session in sessions {
            sessionsByID[session.id] = session
            removedSessionIDs.remove(session.id)
            loadPresentation(for: session)
        }
    }

    func applySuggestedTitle(for session: RecordingSession) {
        guard !isShutDown, let applier = titleApplier else { return }
        let ticket = replaceWork(for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: session) }
            guard let artifact = try? await self.io.artifact(in: session.folderURL),
                  let current = try? await self.io.transcript(in: session.folderURL),
                  artifact.sourceTranscriptSHA256 == current.revision.sha256,
                  artifact.sourceTranscriptByteCount == current.revision.byteCount,
                  self.owns(ticket, for: session) else { return }
            let applied = (try? await applier.applySuggestedTitle(.init(session: session, artifact: artifact,
                                                                         sourceRevision: current.revision,
                                                                         lease: ticket.lease))) ?? false
            guard self.owns(ticket, for: session) else { return }
            if applied {
                self.onSuccessfulPublication?(session)
            }
            self.clearTaskIfOwned(ticket, for: session)
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for id in Array(tasksBySessionID.keys) {
            if let session = sessionsByID[id] {
                Task { await io.disable(folder: session.folderURL) }
            }
            invalidateWork(for: id)
        }
        tasksBySessionID.removeAll()
        attemptsBySessionID.removeAll()
        leasesBySessionID.removeAll()
    }

    private func startAutomatic(event: TranscriptPublished, ticket: Ticket) async {
        let session = event.session
        guard owns(ticket, for: session),
              let transcript = try? await io.transcript(in: session.folderURL),
              transcript.url == event.canonicalURL, transcript.revision == event.revision,
              normalizedFolder(for: session) == event.normalizedSessionFolder else { return }
        // A persisted result for the exact canonical bytes is already the
        // desired automatic outcome; do not spend a fresh /models or chat call.
        if let artifact = try? await io.artifact(in: session.folderURL),
           artifact.sourceTranscriptSHA256 == transcript.revision.sha256,
           artifact.sourceTranscriptByteCount == transcript.revision.byteCount {
            guard owns(ticket, for: session) else { return }
            setPresentation(from: artifact, phase: .ready, message: "Ready.", session: session)
            clearTaskIfOwned(ticket, for: session)
            return
        }
        guard let snapshot = await snapshotIfUsable(for: session, ticket: ticket) else { return }
        setChecking(session, snapshot: snapshot, revision: transcript.revision)
        let availability = await availabilityChecker.availability(for: snapshot)
        guard owns(ticket, for: session) else { return }
        guard case .confirmed = availability else {
            setAvailability(availability, session: session, snapshot: snapshot)
            clearTaskIfOwned(ticket, for: session)
            return
        }
        await generateOwned(session: session, transcript: transcript, snapshot: snapshot,
                            intent: .automatic, ticket: ticket)
    }

    private func startManual(session: RecordingSession, intent: MeetingIntelligenceIntent) {
        guard !isShutDown else { return }
        sessionsByID[session.id] = session
        let ticket = replaceWork(for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: session) }
            guard let snapshot = await self.snapshotIfUsable(for: session, ticket: ticket),
                  let transcript = try? await self.io.transcript(in: session.folderURL),
                  self.owns(ticket, for: session) else { return }
            await self.generateOwned(session: session, transcript: transcript, snapshot: snapshot,
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
        persist(.generating, message: "Generating meeting intelligence.", revision: transcript.revision, for: session)
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
            let outcome = try await publisher.publish(.init(session: session, sourceRevision: transcript.revision,
                                                             capturedTitle: session.metadata.title,
                                                             capturedTitleOrigin: session.metadata.titleOrigin,
                                                             content: content, snapshot: snapshot, intent: intent,
                                                             generatedAt: now(), lease: ticket.lease))
            guard owns(ticket, for: session), !Task.isCancelled else { return }
            setPresentation(from: outcome.artifact, phase: .ready,
                            message: outcome.titleWarning ?? "Ready.", session: session)
            persist(.completed, message: outcome.titleWarning ?? "Ready.", revision: transcript.revision, for: session)
            onSuccessfulPublication?(session)
            clearTaskIfOwned(ticket, for: session)
        } catch is CancellationError {
            finishCancellationIfOwned(ticket, session: session)
        } catch {
            guard owns(ticket, for: session), !Task.isCancelled else { return }
            let message = failureMessage(for: error)
            setFailed(message, for: session)
            persist(.failed, message: message, revision: transcript.revision, for: session)
            clearTaskIfOwned(ticket, for: session)
        }
    }

    private func snapshotIfUsable(for session: RecordingSession, ticket: Ticket) async -> OpenAICompatibleProviderSnapshot? {
        do {
            let snapshot = try await io.snapshot()
            guard owns(ticket, for: session) else { return nil }
            guard isUsableModel(snapshot.profile.llmModel) else {
                setUnavailable(.placeholderModel, session: session, snapshot: snapshot)
                return nil
            }
            return snapshot
        } catch {
            setFailed("Configure an AI provider before generating.", for: session)
            return nil
        }
    }

    private func setChecking(_ session: RecordingSession, snapshot: OpenAICompatibleProviderSnapshot,
                             revision: TranscriptDocumentRevision?) {
        setPresentation(.init(phase: .checkingAvailability, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle,
                              statusMessage: "Checking model availability…", model: snapshot.profile.llmModel,
                              titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
        persist(.checkingAvailability, message: "Checking availability.", revision: revision, for: session)
    }

    private func setAvailability(_ availability: MeetingIntelligenceAvailability, session: RecordingSession, snapshot: OpenAICompatibleProviderSnapshot) {
        switch availability {
        case .confirmed:
            setPresentation(.init(phase: .notGenerated, summary: presentation(for: session).summary,
                                  suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: "Model is available.",
                                  model: snapshot.profile.llmModel, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
            persist(.completed, message: "Model is available.", revision: nil, for: session)
        case .unconfirmed(let reason): setUnavailable(reason, session: session, snapshot: snapshot)
        }
    }

    private func setUnavailable(_ reason: MeetingIntelligenceUnavailableReason, session: RecordingSession, snapshot: OpenAICompatibleProviderSnapshot) {
        setPresentation(.init(phase: .notGenerated, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: "Automatic generation is unavailable.",
                              model: snapshot.profile.llmModel, titleIsProtected: titleIsProtected(session), unavailableReason: reason), for: session)
        persist(.completed, message: "Automatic generation is unavailable.", revision: nil, for: session)
    }

    private func loadPresentation(for session: RecordingSession) {
        let ticket = replaceWork(for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearTaskIfOwned(ticket, for: session) }
            do {
                async let artifact = self.io.artifact(in: session.folderURL)
                async let state = self.io.state(in: session.folderURL)
                let (existing, recovered) = try await (artifact, state)
                guard self.owns(ticket, for: session) else { return }
                if let existing {
                    let source = try await self.io.transcript(in: session.folderURL)
                    guard self.owns(ticket, for: session) else { return }
                    let phase: MeetingIntelligencePresentation.Phase = existing.sourceTranscriptSHA256 == source.revision.sha256 && existing.sourceTranscriptByteCount == source.revision.byteCount ? .ready : .stale
                    self.setPresentation(from: existing, phase: phase, message: phase == .ready ? "Ready." : "Transcript changed. Regenerate to update.", session: session)
                } else if recovered?.phase == .interrupted {
                    self.setPresentation(.init(phase: .interrupted, summary: nil, suggestedTitle: nil,
                                               statusMessage: "Meeting intelligence interrupted. You can generate again.",
                                               model: nil, titleIsProtected: self.titleIsProtected(session), unavailableReason: nil), for: session)
                }
            } catch {
                guard self.owns(ticket, for: session) else { return }
                self.setFailed("Meeting intelligence needs attention.", for: session)
            }
        }
    }

    private func setPresentation(from artifact: MeetingIntelligenceArtifact, phase: MeetingIntelligencePresentation.Phase, message: String, session: RecordingSession) {
        setPresentation(.init(phase: phase, summary: artifact.summary, suggestedTitle: artifact.suggestedTitle,
                              statusMessage: message, model: artifact.model, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
    }

    private func setFailed(_ message: String, for session: RecordingSession) {
        setPresentation(.init(phase: .failed, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: message,
                              model: presentation(for: session).model, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
    }

    private func setPresentation(_ value: MeetingIntelligencePresentation, for session: RecordingSession) {
        guard !isShutDown, !removedSessionIDs.contains(session.id) else { return }
        presentationsBySessionID[session.id] = value
    }

    private func persist(_ phase: MeetingIntelligenceStatePhase, message: String, revision: TranscriptDocumentRevision?, for session: RecordingSession) {
        let state = MeetingIntelligenceState(schemaVersion: MeetingIntelligenceState.currentSchemaVersion, phase: phase,
                                             message: sanitized(message), sourceTranscriptSHA256: revision?.sha256,
                                             startedAt: now(), finishedAt: [.completed, .failed, .cancelled, .interrupted].contains(phase) ? now() : nil)
        guard let generation = generationsBySessionID[session.id], !isShutDown else { return }
        Task { _ = try? await io.save(state, in: session.folderURL, generation: generation) }
    }

    private struct Ticket: Equatable {
        let generation: UInt64
        let attempt: UUID
        let lease: MeetingIntelligenceAttemptLease
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.generation == rhs.generation && lhs.attempt == rhs.attempt }
    }

    private func replaceWork(for session: RecordingSession) -> Ticket {
        invalidateWork(for: session.id)
        let generation = (generationsBySessionID[session.id] ?? 0) &+ 1
        let attempt = UUID()
        let lease = MeetingIntelligenceAttemptLease()
        generationsBySessionID[session.id] = generation
        attemptsBySessionID[session.id] = attempt
        leasesBySessionID[session.id] = lease
        return .init(generation: generation, attempt: attempt, lease: lease)
    }

    private func invalidateWork(for sessionID: RecordingSession.ID) {
        leasesBySessionID[sessionID]?.invalidate()
        tasksBySessionID.removeValue(forKey: sessionID)?.cancel()
        attemptsBySessionID.removeValue(forKey: sessionID)
        leasesBySessionID.removeValue(forKey: sessionID)
    }

    private func owns(_ ticket: Ticket, for session: RecordingSession) -> Bool {
        !isShutDown && !removedSessionIDs.contains(session.id) && ticket.lease.isValid &&
            generationsBySessionID[session.id] == ticket.generation && attemptsBySessionID[session.id] == ticket.attempt
    }

    private func clearTaskIfOwned(_ ticket: Ticket, for session: RecordingSession) {
        guard owns(ticket, for: session) else { return }
        tasksBySessionID.removeValue(forKey: session.id)
        attemptsBySessionID.removeValue(forKey: session.id)
        leasesBySessionID.removeValue(forKey: session.id)
    }

    private func finishCancellationIfOwned(_ ticket: Ticket, session: RecordingSession) {
        guard owns(ticket, for: session) else { return }
        setPresentation(.init(phase: .cancelled, summary: presentation(for: session).summary,
                              suggestedTitle: presentation(for: session).suggestedTitle, statusMessage: "Meeting intelligence cancelled.",
                              model: presentation(for: session).model, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
        persist(.cancelled, message: "Meeting intelligence cancelled.", revision: nil, for: session)
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
        let folder = session.folderURL.resolvingSymlinksInPath().standardizedFileURL
        return session.id.standardizedFileURL == folder ? folder : nil
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
}
