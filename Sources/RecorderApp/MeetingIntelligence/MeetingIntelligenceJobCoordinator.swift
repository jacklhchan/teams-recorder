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
        for session: RecordingSession,
        artifact: MeetingIntelligenceArtifact
    ) async throws -> Bool
}

@MainActor
final class MeetingIntelligenceJobCoordinator: ObservableObject {
    typealias DateNow = @Sendable () -> Date

    var onSuccessfulPublication: ((RecordingSession) -> Void)?

    private let providerRepository: any OpenAICompatibleProviderManaging
    private let transcriptReader: any TranscriptDocumentReading
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
        transcriptReader: any TranscriptDocumentReading = SecureTranscriptDocumentReader(),
        availabilityChecker: any MeetingIntelligenceAvailabilityChecking,
        generator: any MeetingIntelligenceGenerating,
        publisher: any MeetingIntelligencePublishing,
        artifactStore: any MeetingIntelligenceArtifactStoring,
        stateStore: any MeetingIntelligenceStateStoring,
        titleApplier: (any MeetingIntelligenceSuggestedTitleApplying)? = nil,
        now: @escaping DateNow = { Date() }
    ) {
        self.providerRepository = providerRepository
        self.transcriptReader = transcriptReader
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
              validate(event) else { return }
        let sessionID = event.session.id
        guard accepts(event.identity, after: latestPublicationsBySessionID[sessionID]) else { return }
        latestPublicationsBySessionID[sessionID] = event.identity
        sessionsByID[sessionID] = event.session
        startAutomatic(session: event.session, source: event.revision)
    }

    func checkAvailability(for session: RecordingSession) {
        guard !isShutDown else { return }
        sessionsByID[session.id] = session
        guard let snapshot = validSnapshot(for: session, intent: .generate) else { return }
        let ticket = replaceWork(for: session)
        setPresentation(.init(
            phase: .checkingAvailability, summary: presentation(for: session).summary,
            suggestedTitle: presentation(for: session).suggestedTitle,
            statusMessage: "Checking model availability…", model: snapshot.profile.llmModel,
            titleIsProtected: titleIsProtected(session), unavailableReason: nil
        ), for: session)
        persist(.checkingAvailability, message: "Checking availability.", revision: nil, for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            let result = await self?.availabilityChecker.availability(for: snapshot)
            guard let self, self.owns(ticket, for: session), let result else { return }
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
        guard let current = try? transcriptReader.readCanonical(in: session.folderURL, allowLegacy: false) else {
            setFailed("Transcript needs attention.", for: session)
            return
        }
        let artifact = try? artifactStore.load(in: session.folderURL)
        if let artifact, artifact.sourceTranscriptSHA256 == current.revision.sha256,
           artifact.sourceTranscriptByteCount == current.revision.byteCount {
            setPresentation(from: artifact, phase: .ready, message: "Ready.", session: session)
        } else if let artifact {
            setPresentation(from: artifact, phase: .stale, message: "Transcript changed. Regenerate to update.", session: session)
        } else {
            setPresentation(.empty, for: session)
        }
    }

    func remove(sessionID: RecordingSession.ID) {
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
        guard !isShutDown, let applier = titleApplier,
              let artifact = try? artifactStore.load(in: session.folderURL) else { return }
        let ticket = replaceWork(for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            let applied = (try? await applier.applySuggestedTitle(for: session, artifact: artifact)) ?? false
            guard let self, self.owns(ticket, for: session) else { return }
            if applied {
                self.onSuccessfulPublication?(session)
            }
            self.clearTaskIfOwned(ticket, for: session)
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for id in tasksBySessionID.keys { invalidateWork(for: id) }
        tasksBySessionID.removeAll()
        attemptsBySessionID.removeAll()
        leasesBySessionID.removeAll()
    }

    private func startAutomatic(session: RecordingSession, source: TranscriptDocumentRevision) {
        let snapshot: OpenAICompatibleProviderSnapshot
        do { snapshot = try providerRepository.snapshot() }
        catch { setFailed("Configure an AI provider before generating.", for: session); return }
        guard isUsableModel(snapshot.profile.llmModel) else {
            setUnavailable(.placeholderModel, session: session, snapshot: snapshot)
            return
        }
        let ticket = replaceWork(for: session)
        setPresentation(.init(phase: .checkingAvailability, summary: nil, suggestedTitle: nil,
                              statusMessage: "Checking model availability…", model: snapshot.profile.llmModel,
                              titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
        persist(.checkingAvailability, message: "Checking availability.", revision: source, for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            let availability = await self?.availabilityChecker.availability(for: snapshot)
            guard let self, self.owns(ticket, for: session), let availability else { return }
            guard case .confirmed = availability else {
                self.setAvailability(availability, session: session, snapshot: snapshot)
                self.clearTaskIfOwned(ticket, for: session)
                return
            }
            await self.generateOwned(session: session, source: source, snapshot: snapshot,
                                     intent: .automatic, ticket: ticket)
        }
    }

    private func startManual(session: RecordingSession, intent: MeetingIntelligenceIntent) {
        guard !isShutDown else { return }
        sessionsByID[session.id] = session
        guard let snapshot = validSnapshot(for: session, intent: intent),
              let source = try? transcriptReader.readCanonical(in: session.folderURL, allowLegacy: false) else {
            return
        }
        let ticket = replaceWork(for: session)
        tasksBySessionID[session.id] = Task { @MainActor [weak self] in
            await self?.generateOwned(session: session, source: source.revision, snapshot: snapshot,
                                      intent: intent, ticket: ticket)
        }
    }

    private func generateOwned(
        session: RecordingSession,
        source: TranscriptDocumentRevision,
        snapshot: OpenAICompatibleProviderSnapshot,
        intent: MeetingIntelligenceIntent,
        ticket: Ticket
    ) async {
        guard owns(ticket, for: session),
              let transcript = try? transcriptReader.readCanonical(in: session.folderURL, allowLegacy: false),
              transcript.revision == source else {
            return
        }
        setPresentation(.init(phase: .generating(.init(stage: .generatingFinal, current: 0, total: 0)),
                              summary: presentation(for: session).summary, suggestedTitle: presentation(for: session).suggestedTitle,
                              statusMessage: "Generating meeting intelligence…", model: snapshot.profile.llmModel,
                              titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
        persist(.generating, message: "Generating meeting intelligence.", revision: source, for: session)
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
            let outcome = try await publisher.publish(.init(session: session, sourceRevision: source,
                                                             capturedTitle: session.metadata.title,
                                                             capturedTitleOrigin: session.metadata.titleOrigin,
                                                             content: content, snapshot: snapshot, intent: intent,
                                                             generatedAt: now(), lease: ticket.lease))
            guard owns(ticket, for: session), !Task.isCancelled else { return }
            setPresentation(from: outcome.artifact, phase: .ready,
                            message: outcome.titleWarning ?? "Ready.", session: session)
            persist(.completed, message: outcome.titleWarning ?? "Ready.", revision: source, for: session)
            onSuccessfulPublication?(session)
            clearTaskIfOwned(ticket, for: session)
        } catch is CancellationError {
            finishCancellationIfOwned(ticket, session: session)
        } catch {
            guard owns(ticket, for: session), !Task.isCancelled else { return }
            setFailed(sanitized(error.localizedDescription), for: session)
            persist(.failed, message: sanitized(error.localizedDescription), revision: source, for: session)
            clearTaskIfOwned(ticket, for: session)
        }
    }

    private func validSnapshot(for session: RecordingSession, intent _: MeetingIntelligenceIntent) -> OpenAICompatibleProviderSnapshot? {
        do {
            let snapshot = try providerRepository.snapshot()
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
        do {
            let artifact = try artifactStore.load(in: session.folderURL)
            let state = try stateStore.load(in: session.folderURL)
            if let artifact, let transcript = try? transcriptReader.readCanonical(in: session.folderURL, allowLegacy: false) {
                let phase: MeetingIntelligencePresentation.Phase = artifact.sourceTranscriptSHA256 == transcript.revision.sha256 && artifact.sourceTranscriptByteCount == transcript.revision.byteCount ? .ready : .stale
                setPresentation(from: artifact, phase: phase, message: phase == .ready ? "Ready." : "Transcript changed. Regenerate to update.", session: session)
            } else if let state, state.phase == .interrupted {
                setPresentation(.init(phase: .interrupted, summary: nil, suggestedTitle: nil, statusMessage: state.message,
                                      model: nil, titleIsProtected: titleIsProtected(session), unavailableReason: nil), for: session)
            }
        } catch { setFailed("Meeting intelligence needs attention.", for: session) }
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
        try? stateStore.save(state, in: session.folderURL)
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

    private func validate(_ event: TranscriptPublished) -> Bool {
        let folder = event.session.folderURL.resolvingSymlinksInPath().standardizedFileURL
        guard folder == event.normalizedSessionFolder,
              event.session.id.standardizedFileURL == folder,
              let snapshot = try? transcriptReader.readCanonical(in: folder, allowLegacy: false),
              snapshot.url == event.canonicalURL,
              snapshot.revision == event.revision else { return false }
        return true
    }

    private func accepts(_ incoming: TranscriptPublicationIdentity, after current: TranscriptPublicationIdentity?) -> Bool {
        guard let current else { return true }
        guard current.coordinatorInstanceID == incoming.coordinatorInstanceID else { return true }
        // A TranscriptionJobCoordinator generation identifies one completed
        // publication attempt.  UUIDs are not ordered, so accepting another
        // UUID at the same generation would let a forged/late callback start
        // a second automatic job.
        return incoming.generation > current.generation
    }

    private func titleIsProtected(_ session: RecordingSession) -> Bool { session.metadata.titleOrigin == .manual }
    private func isUsableModel(_ model: String) -> Bool { let v = model.trimmingCharacters(in: .whitespacesAndNewlines); return !v.isEmpty && v != "legacy-unconfigured-llm" }
    private func sanitized(_ message: String) -> String { String(message.unicodeScalars.filter { $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t" }.map(String.init).joined().prefix(1_024)) }
}
