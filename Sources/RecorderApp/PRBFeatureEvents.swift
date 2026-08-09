import Foundation

/// A repository-wide workspace transition. Consumers use the supplied fence to
/// reject work that was admitted for an older workspace.
struct WorkspaceFolderChanged: Equatable, Sendable {
    let workspace: LibraryWorkspaceSnapshot
}

/// Signals that a provider profile has been durably saved. The revision is an
/// opaque notification identity: already-running jobs retain their immutable
/// provider snapshot, while future jobs may use the newly saved profile.
struct ProviderSettingsSaved: Equatable, Sendable {
    let profileRevision: UUID
}

enum RecordingSourceMetadataPublicationOutcome: Equatable, Sendable {
    case saved
    case warning(String)
}

/// The semantic result of a recording finalization. It is emitted only after
/// the media artifact and its metadata attempt have reached their terminal
/// outcomes, so the Library boundary can perform one coherent refresh.
struct RecordingFinalizationOutcome: Equatable, Sendable {
    let finalizationID: UUID
    let folder: URL
    let workspaceFence: WorkspacePublicationFence
    let recordingURL: URL
    let health: RecordingHealthReport
    let metadataOutcome: RecordingSourceMetadataPublicationOutcome
    let source: RecordingSource
}
