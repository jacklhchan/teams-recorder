import Combine
import Foundation

@MainActor
final class TranscriptionJobCoordinator: ObservableObject {
    @Published private(set) var transcribingSessionID: RecordingSession.ID?
    @Published private(set) var transcriptionStatus = ""
    @Published private(set) var lastTranscriptionSessionID: RecordingSession.ID?
    @Published private(set) var lastTranscriptionStatus = ""
    @Published private(set) var lastTranscriptionDidFail = false
    @Published private(set) var transcriptURLsBySessionID:
        [RecordingSession.ID: URL] = [:]
    @Published private(set) var transcriptLogURLsBySessionID:
        [RecordingSession.ID: URL] = [:]
    @Published private(set) var transcriptionStatesBySessionID:
        [RecordingSession.ID: TranscriptionState] = [:]

    var onStatusMessage: ((String) -> Void)?
    var onSuccessfulPublication: ((TranscriptPublished) -> Void)?

    /// The only publication stream which a meeting-intelligence coordinator
    /// may consume.  This is intentionally read-only outside this type.
    var publicationSourceID: UUID { coordinatorInstanceID }

    private let providerRepository:
        any OpenAICompatibleProviderManaging
    let providerRepositoryIdentity: ObjectIdentifier
    private let audioPreparer: any TranscriptionAudioPreparing
    private let service: any TranscriptionServicing
    /// The feature boundary exposes this identity for PR B aggregate
    /// composition validation; this coordinator remains its sole user for ASR
    /// artifact publication.
    let mutationGate: RecordingSessionMutationGate
    private let failureDiagnosticPublisher: TranscriptionArtifactPublisher
    private let transcriptReader: any TranscriptDocumentReading
    private let coordinatorInstanceID: UUID
    private let attemptIDFactory: () -> UUID
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var activeAttempt: UUID?
    private var activeSession: RecordingSession?
    private var cancellationRequested = false
    private var workspacePublicationFence: WorkspacePublicationFence = .initial

    init(
        providerRepository: any OpenAICompatibleProviderManaging,
        audioPreparer: any TranscriptionAudioPreparing,
        service: any TranscriptionServicing,
        mutationGate: RecordingSessionMutationGate = .init(),
        transcriptReader: any TranscriptDocumentReading =
            SecureTranscriptDocumentReader(),
        coordinatorInstanceID: UUID = UUID(),
        attemptIDFactory: @escaping () -> UUID = UUID.init
    ) {
        self.providerRepository = providerRepository
        providerRepositoryIdentity = providerRepository.compositionIdentity
        self.audioPreparer = audioPreparer
        self.service = service
        self.mutationGate = mutationGate
        failureDiagnosticPublisher = .init(mutationGate: mutationGate)
        self.transcriptReader = transcriptReader
        self.coordinatorInstanceID = coordinatorInstanceID
        self.attemptIDFactory = attemptIDFactory
    }

    deinit {
        task?.cancel()
    }

    var isRunning: Bool {
        task != nil || transcribingSessionID != nil
    }

    func advanceWorkspacePublicationFence(
        to fence: WorkspacePublicationFence
    ) {
        precondition(
            fence.revision > workspacePublicationFence.revision,
            "Workspace publication fence must advance monotonically."
        )
        workspacePublicationFence = fence
    }

    func start(session: RecordingSession) {
        guard !isRunning else {
            publishGlobalStatus("A transcription is already running.")
            return
        }

        let snapshot: OpenAICompatibleProviderSnapshot
        do {
            snapshot = try providerRepository.snapshot()
        } catch {
            lastTranscriptionSessionID = session.id
            lastTranscriptionStatus = error.localizedDescription
            lastTranscriptionDidFail = true
            publishGlobalStatus(error.localizedDescription)
            return
        }

        generation &+= 1
        let attempt = attemptIDFactory()
        let attemptGeneration = generation
        let attemptWorkspaceFence = workspacePublicationFence
        activeAttempt = attempt
        activeSession = session
        cancellationRequested = false
        transcribingSessionID = session.id
        lastTranscriptionSessionID = session.id
        lastTranscriptionStatus = "Preparing transcription"
        lastTranscriptionDidFail = false
        transcriptionStatus = "Preparing transcription"
        updateState(
            .init(
                phase: .queued,
                message: transcriptionStatus,
                startedAt: Date()
            ),
            for: session
        )
        publishGlobalStatus(transcriptionStatus)

        let preparer = audioPreparer
        let service = service
        task = Task { @MainActor [weak self, preparer, service] in
            var prepared: PreparedTranscriptionAudio?
            defer {
                if let prepared {
                    preparer.cleanup(prepared)
                }
            }
            do {
                try Task.checkCancellation()
                let audio = try await preparer.prepare(for: session)
                prepared = audio
                try Task.checkCancellation()
                guard self?.isActive(
                    generation: attemptGeneration,
                    attempt: attempt
                ) == true else {
                    return
                }

                let result = try await service.transcribe(
                    .init(
                        audioURL: audio.audioURL,
                        sessionFolder: session.folderURL,
                        snapshot: snapshot
                    ),
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.apply(
                                progress,
                                session: session,
                                generation: attemptGeneration,
                                attempt: attempt
                            )
                        }
                    }
                )
                guard self?.isActive(
                    generation: attemptGeneration,
                    attempt: attempt
                ) == true else {
                    return
                }
                if Task.isCancelled
                    || self?.cancellationRequested == true {
                    self?.finishCancellation(
                        session: session,
                        generation: attemptGeneration,
                        attempt: attempt
                    )
                    return
                }
                guard let transcriptURL = self?.validatedArtifact(
                    result.transcriptURL,
                    in: session.folderURL
                ) else {
                    throw CoordinatorError.invalidArtifact
                }
                if let logURL = result.logURL,
                   self?.validatedArtifact(
                    logURL,
                    in: session.folderURL
                   ) == nil {
                    throw CoordinatorError.invalidArtifact
                }
                guard let self else { return }
                let event = try self.mutationGate.withMutation(
                    for: session.folderURL
                ) {
                    guard self.isActive(
                        generation: attemptGeneration,
                        attempt: attempt
                    ), !self.cancellationRequested else {
                        throw CoordinatorError.staleAttempt
                    }
                    let snapshot = try self.transcriptReader.readCanonical(
                        in: session.folderURL,
                        allowLegacy: true
                    )
                    guard snapshot.url == transcriptURL,
                          snapshot.revision == result.committedTranscriptRevision else {
                        throw CoordinatorError.committedRevisionMismatch
                    }
                    self.transcriptURLsBySessionID[session.id] = transcriptURL
                    if let logURL = result.logURL {
                        self.transcriptLogURLsBySessionID[session.id] = logURL
                    }
                    return TranscriptPublished(
                        session: session,
                        canonicalURL: transcriptURL,
                        revision: result.committedTranscriptRevision,
                        normalizedSessionFolder: session.folderURL
                            .resolvingSymlinksInPath()
                            .standardizedFileURL,
                        identity: .init(
                            coordinatorInstanceID: self.coordinatorInstanceID,
                            generation: attemptGeneration,
                            attemptID: attempt
                        ),
                        workspaceFence: attemptWorkspaceFence
                    )
                }
                self.onSuccessfulPublication?(event)
                self.finishSuccess(
                    session: session,
                    generation: attemptGeneration,
                    attempt: attempt
                )
            } catch is CancellationError {
                self?.finishCancellation(
                    session: session,
                    generation: attemptGeneration,
                    attempt: attempt
                )
            } catch {
                guard let self else { return }
                self.handleFailure(
                    error,
                    prepared: prepared,
                    session: session,
                    snapshot: snapshot,
                    generation: attemptGeneration,
                    attempt: attempt
                )
            }
        }
    }

    func cancel() {
        guard let session = activeSession, task != nil else { return }
        cancellationRequested = true
        task?.cancel()
        transcriptionStatus = "Cancelling transcription..."
        lastTranscriptionStatus = transcriptionStatus
        updateState(
            .init(
                phase: .cancelled,
                message: transcriptionStatus,
                startedAt:
                    transcriptionStatesBySessionID[session.id]?.startedAt
                    ?? Date(),
                finishedAt: Date()
            ),
            for: session
        )
    }

    func shutdown() {
        generation &+= 1
        cancellationRequested = true
        task?.cancel()
        task = nil
        transcribingSessionID = nil
        activeAttempt = nil
        activeSession = nil
    }

    func replaceLoadedStates(_ states: [RecordingSession.ID: TranscriptionState]) {
        var projected = states.mapValues { state in
            guard [.queued, .uploading, .transcribing].contains(state.phase) else {
                return state
            }
            var interrupted = state
            interrupted.phase = .interrupted
            interrupted.message = "Transcription interrupted. You can start it again."
            interrupted.finishedAt = Date()
            return interrupted
        }

        if let activeID = transcribingSessionID {
            if let liveState = transcriptionStatesBySessionID[activeID] {
                projected[activeID] = liveState
            } else if let loadedState = states[activeID] {
                projected[activeID] = loadedState
            }
        }
        transcriptionStatesBySessionID = projected
    }

    func clearProjections() {
        transcriptURLsBySessionID = [:]
        transcriptLogURLsBySessionID = [:]
        transcriptionStatesBySessionID = [:]
    }

    func setTranscriptURL(_ url: URL?, for sessionID: RecordingSession.ID) {
        transcriptURLsBySessionID[sessionID] = url
    }

    func setTranscriptLogURL(_ url: URL?, for sessionID: RecordingSession.ID) {
        transcriptLogURLsBySessionID[sessionID] = url
    }

    func removeProjection(for sessionID: RecordingSession.ID) {
        transcriptionStatesBySessionID.removeValue(forKey: sessionID)
        transcriptURLsBySessionID.removeValue(forKey: sessionID)
        transcriptLogURLsBySessionID.removeValue(forKey: sessionID)
    }

    private func apply(
        _ progress: TranscriptionServiceProgress,
        session: RecordingSession,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActive(generation: generation, attempt: attempt),
              !cancellationRequested else {
            return
        }
        transcriptionStatus = progress.message
        lastTranscriptionStatus = progress.message
        updateState(
            .init(
                phase: progress.phase,
                message: progress.message,
                startedAt:
                    transcriptionStatesBySessionID[session.id]?.startedAt
                    ?? Date()
            ),
            for: session
        )
    }

    private func finishSuccess(
        session: RecordingSession,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActive(generation: generation, attempt: attempt) else {
            return
        }
        transcriptionStatus = "Transcription complete"
        lastTranscriptionStatus = transcriptionStatus
        lastTranscriptionDidFail = false
        updateState(
            .init(
                phase: .completed,
                message: transcriptionStatus,
                startedAt:
                    transcriptionStatesBySessionID[session.id]?.startedAt
                    ?? Date(),
                finishedAt: Date()
            ),
            for: session
        )
        publishGlobalStatus(transcriptionStatus)
        clear(generation: generation, attempt: attempt)
    }

    private func finishCancellation(
        session: RecordingSession,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActive(generation: generation, attempt: attempt) else {
            return
        }
        transcriptionStatus = "Transcription cancelled"
        lastTranscriptionStatus = transcriptionStatus
        lastTranscriptionDidFail = false
        updateState(
            .init(
                phase: .cancelled,
                message: transcriptionStatus,
                startedAt:
                    transcriptionStatesBySessionID[session.id]?.startedAt
                    ?? Date(),
                finishedAt: Date()
            ),
            for: session
        )
        publishGlobalStatus(transcriptionStatus)
        clear(generation: generation, attempt: attempt)
    }

    private func finishFailure(
        session: RecordingSession,
        message: String,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActive(generation: generation, attempt: attempt) else {
            return
        }
        transcriptionStatus = "Transcription failed"
        lastTranscriptionStatus = message
        lastTranscriptionDidFail = true
        updateState(
            .init(
                phase: .failed,
                message: message,
                startedAt:
                    transcriptionStatesBySessionID[session.id]?.startedAt
                    ?? Date(),
                finishedAt: Date()
            ),
            for: session
        )
        publishGlobalStatus(message)
        clear(generation: generation, attempt: attempt)
    }

    private func isActive(
        generation: UInt64,
        attempt: UUID
    ) -> Bool {
        self.generation == generation && activeAttempt == attempt
    }

    private func clear(generation: UInt64, attempt: UUID) {
        guard isActive(generation: generation, attempt: attempt) else {
            return
        }
        task = nil
        transcribingSessionID = nil
        activeAttempt = nil
        activeSession = nil
    }

    private func validatedArtifact(
        _ url: URL,
        in sessionFolder: URL
    ) -> URL? {
        guard url.isFileURL else { return nil }
        let expectedParent = sessionFolder
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == expectedParent,
              RecordingSessionStore.isRegularFile(candidate) else {
            return nil
        }
        return candidate
    }

    private func redacted(_ message: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return message }
        return message.replacingOccurrences(
            of: secret,
            with: "[redacted]"
        )
    }

    func handleFailure(
        _ error: Error,
        prepared: PreparedTranscriptionAudio?,
        session: RecordingSession,
        snapshot: OpenAICompatibleProviderSnapshot,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActive(generation: generation, attempt: attempt) else {
            return
        }
        if Task.isCancelled
            || cancellationRequested
            || (error as? URLError)?.code == .cancelled {
            finishCancellation(
                session: session,
                generation: generation,
                attempt: attempt
            )
            return
        }

        _ = try? failureDiagnosticPublisher.publishFailureDiagnostic(
            failureDiagnostic(for: error, prepared: prepared),
            sessionFolder: session.folderURL
        )
        let prefix = prepared == nil
            ? "Transcription preparation failed"
            : "Transcription launch failed"
        let detail = redacted(
            error.localizedDescription,
            secret: snapshot.apiKey
        )
        finishFailure(
            session: session,
            message: "\(prefix): \(detail)",
            generation: generation,
            attempt: attempt
        )
    }

    private func failureDiagnostic(
        for error: Error,
        prepared: PreparedTranscriptionAudio?
    ) -> TranscriptionFailureDiagnostic {
        guard prepared != nil else {
            return .init(
                stage: .preparation,
                errorCode: .preparationFailure
            )
        }

        switch error {
        case let error as OpenAICompatibleTranscriptionError:
            switch error {
            case .audioChunkTooLarge:
                return .init(
                    stage: .upload,
                    errorCode: .audioChunkTooLarge
                )
            case .httpStatus(let status):
                return .init(
                    stage: .upload,
                    errorCode: .providerHTTPFailure,
                    httpStatus: status
                )
            case .invalidResponse, .authenticationRejected:
                return .init(
                    stage: .upload,
                    errorCode: .providerTransportFailure
                )
            }
        case let error as ProviderHTTPTransportError:
            switch error {
            case .responseTooLarge:
                return .init(
                    stage: .upload,
                    errorCode: .providerResponseTooLarge
                )
            case .redirectRejected:
                return .init(
                    stage: .upload,
                    errorCode: .providerTransportFailure
                )
            }
        case let error as CoordinatorError:
            switch error {
            case .invalidArtifact:
                return .init(
                    stage: .publication,
                    errorCode: .invalidArtifact
                )
            case .committedRevisionMismatch:
                return .init(
                    stage: .publication,
                    errorCode: .committedRevisionMismatch
                )
            case .staleAttempt:
                return .init(
                    stage: .publication,
                    errorCode: .publicationFailure
                )
            }
        default:
            return .init(
                stage: .upload,
                errorCode: .providerTransportFailure
            )
        }
    }

    private func updateState(
        _ state: TranscriptionState,
        for session: RecordingSession
    ) {
        transcriptionStatesBySessionID[session.id] = state
        try? TranscriptionStateStore.save(
            state,
            in: session.folderURL
        )
    }

    private func publishGlobalStatus(_ message: String) {
        onStatusMessage?(message)
    }

    private enum CoordinatorError: LocalizedError {
        case invalidArtifact
        case committedRevisionMismatch
        case staleAttempt

        var errorDescription: String? {
            switch self {
            case .invalidArtifact:
                "Transcription reported an invalid artifact path."
            case .committedRevisionMismatch:
                "Committed transcript revision did not match the canonical file."
            case .staleAttempt:
                "Transcription attempt is no longer active."
            }
        }
    }
}
