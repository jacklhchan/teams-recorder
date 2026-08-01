import Combine
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

/// Identifies one admitted editor save. The episode prevents an asynchronous
/// completion captured by an earlier sheet presentation from affecting the
/// current one.
struct LibraryEditorSaveAttempt: Equatable, Sendable {
    let episode: UUID
    let identifier: UUID
    let sessionID: RecordingSession.ID
    let artifact: LibraryEditableArtifact
}

enum LibraryEditorSaveStateValue: Equatable, Sendable {
    case idle
    case saving
    case failed(LibrarySaveFailure)
}

/// Main-actor admission for a single editor sheet. `begin` is deliberately
/// synchronous so a second button event cannot create a second durable write
/// before the first save task has started.
@MainActor
final class LibraryEditorSaveState: ObservableObject {
    @Published private(set) var state: LibraryEditorSaveStateValue = .idle
    private var episode = UUID()
    private var currentAttempt: LibraryEditorSaveAttempt?
    private(set) var didDismiss = false

    func begin(
        sessionID: RecordingSession.ID,
        artifact: LibraryEditableArtifact
    ) -> LibraryEditorSaveAttempt? {
        guard currentAttempt == nil, !didDismiss else { return nil }
        let attempt = LibraryEditorSaveAttempt(
            episode: episode,
            identifier: UUID(),
            sessionID: sessionID,
            artifact: artifact
        )
        currentAttempt = attempt
        state = .saving
        return attempt
    }

    func complete(
        _ attempt: LibraryEditorSaveAttempt,
        outcome: LibrarySaveOutcome
    ) -> LibraryEditorSaveDisposition {
        guard attempt.episode == episode,
              attempt == currentAttempt,
              !didDismiss
        else { return .keepOpen }

        currentAttempt = nil
        guard outcome.sessionID == attempt.sessionID else {
            state = .idle
            return .keepOpen
        }

        if let failure = outcome.failures.first(where: { $0.artifact == attempt.artifact }) {
            state = .failed(failure)
            return .keepOpen
        }

        guard outcome.savedArtifacts.contains(attempt.artifact) else {
            state = .idle
            return .keepOpen
        }

        didDismiss = true
        state = .idle
        return .dismiss
    }

    /// Called when the owning sheet disappears. A completion retained by an
    /// old task can no longer affect a later presentation of that editor.
    func invalidate() {
        episode = UUID()
        currentAttempt = nil
        state = .idle
        didDismiss = false
    }
}

struct LibraryLoadedSnapshot: Equatable {
    let sessions: [RecordingSession]
    let transcriptionStates: [RecordingSession.ID: TranscriptionState]
}
