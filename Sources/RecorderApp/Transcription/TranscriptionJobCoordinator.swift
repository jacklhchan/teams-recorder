import Combine
import Foundation

@MainActor
final class TranscriptionJobCoordinator: ObservableObject {
    @Published var transcribingSessionID: RecordingSession.ID?
    @Published var transcriptionStatus = ""
    @Published var lastTranscriptionSessionID: RecordingSession.ID?
    @Published var lastTranscriptionStatus = ""
    @Published var lastTranscriptionDidFail = false
    @Published var transcriptURLsBySessionID:
        [RecordingSession.ID: URL] = [:]
    @Published var transcriptLogURLsBySessionID:
        [RecordingSession.ID: URL] = [:]
    @Published var transcriptionStatesBySessionID:
        [RecordingSession.ID: TranscriptionState] = [:]

    var onStatusMessage: ((String) -> Void)?

    private let providerRepository:
        any OpenAICompatibleProviderManaging
    private let audioPreparer: any TranscriptionAudioPreparing
    private let service: any TranscriptionServicing
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var activeAttempt: UUID?
    private var activeSession: RecordingSession?
    private var cancellationRequested = false

    init(
        providerRepository: any OpenAICompatibleProviderManaging,
        audioPreparer: any TranscriptionAudioPreparing,
        service: any TranscriptionServicing
    ) {
        self.providerRepository = providerRepository
        self.audioPreparer = audioPreparer
        self.service = service
    }

    deinit {
        task?.cancel()
    }

    var isRunning: Bool {
        task != nil || transcribingSessionID != nil
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
        let attempt = UUID()
        let attemptGeneration = generation
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
                self?.transcriptURLsBySessionID[session.id] =
                    transcriptURL
                if let logURL = result.logURL {
                    self?.transcriptLogURLsBySessionID[session.id] =
                        logURL
                }
                self?.finishSuccess(
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
                if Task.isCancelled || self.cancellationRequested {
                    self.finishCancellation(
                        session: session,
                        generation: attemptGeneration,
                        attempt: attempt
                    )
                } else {
                    let prefix = prepared == nil
                        ? "Transcription preparation failed"
                        : "Transcription launch failed"
                    let detail = self.redacted(
                        error.localizedDescription,
                        secret: snapshot.apiKey
                    )
                    self.finishFailure(
                        session: session,
                        message: "\(prefix): \(detail)",
                        generation: attemptGeneration,
                        attempt: attempt
                    )
                }
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
        publishGlobalStatus(progress.message)
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

        var errorDescription: String? {
            "Transcription reported an invalid artifact path."
        }
    }
}
