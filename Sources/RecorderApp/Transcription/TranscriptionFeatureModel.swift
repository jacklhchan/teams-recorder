import Combine
import Foundation

struct TranscriptionFeaturePresentation: Equatable {
    let transcribingSessionID: RecordingSession.ID?
    let transcriptionStatus: String
    let lastTranscriptionSessionID: RecordingSession.ID?
    let lastTranscriptionStatus: String
    let lastTranscriptionDidFail: Bool
    let transcriptURLsBySessionID: [RecordingSession.ID: URL]
    let transcriptLogURLsBySessionID: [RecordingSession.ID: URL]
    let transcriptionStatesBySessionID: [RecordingSession.ID: TranscriptionState]
}

@MainActor
final class TranscriptionFeatureModel: ObservableObject {
    private let coordinator: TranscriptionJobCoordinator
    let publicationSourceID: UUID

    var onStatusMessage: ((String) -> Void)? {
        didSet { coordinator.onStatusMessage = isShutdown ? nil : onStatusMessage }
    }
    var onSuccessfulPublication: ((TranscriptPublished) -> Void)? {
        get { successfulPublicationCallback }
        set { replaceSuccessfulPublicationObserver(with: newValue) }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var isShutdown = false
    private var successfulPublicationToken: UUID?
    private var successfulPublicationCallback: ((TranscriptPublished) -> Void)?

    init(coordinator: TranscriptionJobCoordinator) {
        self.coordinator = coordinator
        publicationSourceID = coordinator.publicationSourceID
        coordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Composition-only identity. The coordinator remains the owner of the
    /// gate; PR B uses this to reject an aggregate that would split one
    /// recording session's durable mutations across multiple locks.
    var mutationGate: RecordingSessionMutationGate { coordinator.mutationGate }

    /// Read-only composition identity; the coordinator remains the only ASR
    /// owner of the repository and of immutable per-attempt snapshots.
    var providerRepositoryIdentity: ObjectIdentifier {
        coordinator.providerRepositoryIdentity
    }

    var presentation: TranscriptionFeaturePresentation {
        .init(
            transcribingSessionID: coordinator.transcribingSessionID,
            transcriptionStatus: coordinator.transcriptionStatus,
            lastTranscriptionSessionID: coordinator.lastTranscriptionSessionID,
            lastTranscriptionStatus: coordinator.lastTranscriptionStatus,
            lastTranscriptionDidFail: coordinator.lastTranscriptionDidFail,
            transcriptURLsBySessionID: coordinator.transcriptURLsBySessionID,
            transcriptLogURLsBySessionID: coordinator.transcriptLogURLsBySessionID,
            transcriptionStatesBySessionID: coordinator.transcriptionStatesBySessionID
        )
    }

    func start(session: RecordingSession, providerIsConfigured: Bool) {
        guard !isShutdown else { return }
        guard providerIsConfigured else {
            onStatusMessage?("Configure and save an AI provider before starting transcription.")
            return
        }
        coordinator.start(session: session)
    }

    func cancel() { coordinator.cancel() }

    func advanceWorkspacePublicationFence(to fence: WorkspacePublicationFence) {
        coordinator.advanceWorkspacePublicationFence(to: fence)
    }

    func replaceLoadedStates(_ states: [RecordingSession.ID: TranscriptionState]) {
        coordinator.replaceLoadedStates(states)
    }

    func clearProjections() { coordinator.clearProjections() }

    func setTranscriptURL(_ url: URL?, for sessionID: RecordingSession.ID) {
        coordinator.setTranscriptURL(url, for: sessionID)
    }

    func setTranscriptLogURL(_ url: URL?, for sessionID: RecordingSession.ID) {
        coordinator.setTranscriptLogURL(url, for: sessionID)
    }

    func removeProjection(for sessionID: RecordingSession.ID) {
        coordinator.removeProjection(for: sessionID)
    }

    @discardableResult
    func observeSuccessfulPublication(
        _ observer: @escaping (TranscriptPublished) -> Void
    ) -> UUID {
        guard !isShutdown else { return UUID() }
        let token = UUID()
        successfulPublicationToken = token
        successfulPublicationCallback = observer
        coordinator.onSuccessfulPublication = observer
        return token
    }

    func removeSuccessfulPublicationObserver(_ token: UUID) {
        guard successfulPublicationToken == token else { return }
        successfulPublicationToken = nil
        successfulPublicationCallback = nil
        coordinator.onSuccessfulPublication = nil
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        coordinator.onStatusMessage = nil
        successfulPublicationToken = nil
        successfulPublicationCallback = nil
        coordinator.onSuccessfulPublication = nil
        cancellables.removeAll()
        coordinator.shutdown()
    }

    private func replaceSuccessfulPublicationObserver(
        with observer: ((TranscriptPublished) -> Void)?
    ) {
        guard let observer, !isShutdown else {
            successfulPublicationToken = nil
            successfulPublicationCallback = nil
            coordinator.onSuccessfulPublication = nil
            return
        }
        _ = observeSuccessfulPublication(observer)
    }
}
