import Foundation

/// Repository-wide identity representation for recording-library filesystem
/// artifacts. Every workspace, session folder, and media artifact admission
/// check must compare this form so a workspace selected through a symlink has
/// the same identity as the canonical publication path.
enum RecordingLibraryURLIdentity {
    static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

struct LibraryFeatureFailure: Error, Equatable, Sendable {
    let message: String
}

struct LibraryWorkspaceSnapshot: Equatable, Hashable, Sendable {
    let folder: URL
    let fence: WorkspacePublicationFence
}

/// The sole observable Library projection. `sessions` is canonical for the
/// active workspace and is never mirrored as separately mutable UI state.
struct LibraryFeatureSnapshot: Equatable, Sendable {
    let revision: UInt64
    let sessions: [RecordingSession]

    static let empty = Self(revision: 0, sessions: [])
}

struct LibraryMutationIdentity: Equatable, Hashable, Sendable {
    let librarySourceID: UUID
    let mutationID: UUID
    let sessionID: RecordingSession.ID
    let normalizedSessionFolder: URL
    let transcriptRevision: TranscriptDocumentRevision?
    let workspaceFence: WorkspacePublicationFence
}

struct LibraryTranscriptProjectionCommitted: Sendable {
    let identity: LibraryMutationIdentity
    let publication: TranscriptPublished
    let canonicalSession: RecordingSession
}

struct TranscriptEdited: Sendable {
    let identity: LibraryMutationIdentity
    let canonicalSession: RecordingSession
}

struct MetadataSaved: Sendable {
    let identity: LibraryMutationIdentity
    let canonicalSession: RecordingSession
}

struct ImportedAudioSessionReady: Sendable {
    let identity: LibraryMutationIdentity
    let canonicalSession: RecordingSession
}

struct SessionRemoved: Sendable {
    let identity: LibraryMutationIdentity
}

enum LibraryEditableArtifact: Equatable, Hashable, Sendable {
    case transcript
    case metadata
}

struct LibrarySaveFailure: Equatable, Sendable {
    let artifact: LibraryEditableArtifact
    let userMessage: String
}

struct LibrarySaveOutcome: Equatable, Sendable {
    /// Identifies the editor session to which this outcome belongs. A save
    /// completion for an older or different session must not dismiss the open
    /// editor.
    let sessionID: RecordingSession.ID
    let savedArtifacts: Set<LibraryEditableArtifact>
    let failures: [LibrarySaveFailure]

    static func saved(sessionID: RecordingSession.ID, _ artifact: LibraryEditableArtifact) -> Self {
        .init(sessionID: sessionID, savedArtifacts: [artifact], failures: [])
    }

    static func failed(
        sessionID: RecordingSession.ID,
        _ artifact: LibraryEditableArtifact,
        _ message: String
    ) -> Self {
        .init(
            sessionID: sessionID,
            savedArtifacts: [],
            failures: [.init(artifact: artifact, userMessage: message)]
        )
    }
}

enum LibraryEditorSaveDisposition: Equatable, Sendable {
    case keepOpen
    case dismiss

    static func disposition(
        for artifact: LibraryEditableArtifact,
        expectedSessionID: RecordingSession.ID,
        outcome: LibrarySaveOutcome
    ) -> Self {
        outcome.sessionID == expectedSessionID && outcome.savedArtifacts.contains(artifact)
            ? .dismiss
            : .keepOpen
    }
}

struct LibraryLoadedSnapshot: Equatable {
    let sessions: [RecordingSession]
    let transcriptionStates: [RecordingSession.ID: TranscriptionState]
}
