import Combine
import Foundation

typealias MeetingIntelligenceFeatureFactory = (
    any OpenAICompatibleProviderManaging,
    UUID,
    RecordingSessionMutationGate
) -> MeetingIntelligenceFeatureModel

/// Main-actor UI boundary for meeting intelligence.  The coordinator remains
/// the sole owner of attempt state and of the immutable snapshot; this model
/// only forwards commands and exposes that projection to SwiftUI.
@MainActor
final class MeetingIntelligenceFeatureModel: ObservableObject {
    private let coordinator: MeetingIntelligenceJobCoordinator
    private var isShutdown = false

    var onPublished: ((MeetingIntelligencePublished) -> Void)? {
        didSet { coordinator.onPublication = isShutdown ? nil : onPublished }
    }

    let publicationSourceID: UUID

    init(coordinator: MeetingIntelligenceJobCoordinator) {
        self.coordinator = coordinator
        publicationSourceID = coordinator.publicationSourceID
        coordinator.onSnapshotDidChange = { [weak self] _ in
            // The coordinator has committed the immutable snapshot before
            // this signal, so synchronous observers never see stale state.
            self?.objectWillChange.send()
        }
    }

    var snapshot: MeetingIntelligenceFeatureSnapshot { coordinator.snapshot }

    func presentation(for session: RecordingSession) -> MeetingIntelligencePresentation {
        snapshot.presentation(for: session)?.presentation ?? .empty
    }

    func checkAvailability(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) {
        guard !isShutdown else { return }
        coordinator.checkAvailability(for: session, workspaceFence: workspaceFence)
    }

    func generate(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) {
        guard !isShutdown else { return }
        coordinator.generate(for: session, workspaceFence: workspaceFence)
    }

    func regenerate(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) {
        guard !isShutdown else { return }
        coordinator.regenerate(for: session, workspaceFence: workspaceFence)
    }

    func retryGeneration(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) {
        guard !isShutdown else { return }
        coordinator.retryGeneration(for: session, workspaceFence: workspaceFence)
    }

    func cancel(sessionID: RecordingSession.ID) {
        guard !isShutdown else { return }
        coordinator.cancel(sessionID: sessionID)
    }

    func applySuggestedTitle(for session: RecordingSession, workspaceFence: WorkspacePublicationFence = .initial) {
        guard !isShutdown else { return }
        coordinator.applySuggestedTitle(for: session, workspaceFence: workspaceFence)
    }

    func handleTranscriptPublished(_ event: TranscriptPublished) {
        guard !isShutdown else { return }
        coordinator.handleTranscriptPublished(event)
    }

    func transcriptDidSave(_ session: RecordingSession) {
        guard !isShutdown else { return }
        coordinator.transcriptDidSave(session)
    }

    func reload(sessions: [RecordingSession]) {
        guard !isShutdown else { return }
        coordinator.reload(sessions: sessions)
    }

    func remove(sessionID: RecordingSession.ID) {
        guard !isShutdown else { return }
        coordinator.remove(sessionID: sessionID)
    }

    func resetForWorkspaceChange() {
        guard !isShutdown else { return }
        coordinator.resetForWorkspaceChange()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        // Release the UI consumer as well as detaching the coordinator.  This
        // keeps the feature boundary from retaining a closed presentation
        // surface through its compatibility callback.
        onPublished = nil
        coordinator.onSnapshotDidChange = nil
        coordinator.shutdown()
    }
}
