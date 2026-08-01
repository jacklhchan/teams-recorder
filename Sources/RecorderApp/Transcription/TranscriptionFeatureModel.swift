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
        didSet {
            coordinator.onSuccessfulPublication = isShutdown
                ? nil
                : onSuccessfulPublication
        }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var isShutdown = false

    init(coordinator: TranscriptionJobCoordinator) {
        self.coordinator = coordinator
        publicationSourceID = coordinator.publicationSourceID
        coordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
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

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        coordinator.onStatusMessage = nil
        coordinator.onSuccessfulPublication = nil
        cancellables.removeAll()
        coordinator.shutdown()
    }
}
