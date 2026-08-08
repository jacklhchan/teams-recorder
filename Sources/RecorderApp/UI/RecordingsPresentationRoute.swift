import Foundation

enum RecordingsPresentationRoute: Equatable {
    case list
    case transcript(RecordingSession.ID)

    func resolvedSession(in sessions: [RecordingSession]) -> RecordingSession? {
        guard case let .transcript(id) = self else { return nil }
        return sessions.first { $0.id == id }
    }

    mutating func invalidateIfMissing(from sessions: [RecordingSession]) {
        guard case .transcript = self, resolvedSession(in: sessions) == nil else {
            return
        }
        self = .list
    }
}

@MainActor
struct RecordingsCanonicalActionAdmission {
    let currentSessions: () -> [RecordingSession]

    init(currentSessions: @escaping () -> [RecordingSession]) {
        self.currentSessions = currentSessions
    }

    func canonicalSession(for sessionID: RecordingSession.ID) -> RecordingSession? {
        currentSessions().first { $0.id == sessionID }
    }

    @discardableResult
    func perform(
        sessionID: RecordingSession.ID,
        action: (RecordingSession) -> Void
    ) -> Bool {
        guard let session = canonicalSession(for: sessionID) else { return false }
        action(session)
        return true
    }

    func save(
        sessionID: RecordingSession.ID,
        artifact: LibraryEditableArtifact,
        action: (RecordingSession) async -> LibrarySaveOutcome
    ) async -> LibrarySaveOutcome {
        guard let session = canonicalSession(for: sessionID) else {
            return .failed(sessionID: sessionID, artifact,
                           "The recording is no longer available.")
        }
        return await action(session)
    }

    @discardableResult
    func performAsync(
        sessionID: RecordingSession.ID,
        action: (RecordingSession) async -> Void
    ) async -> Bool {
        guard let session = canonicalSession(for: sessionID) else { return false }
        await action(session)
        return true
    }
}

enum RecordingsSessionLocationAction {
    case openFolder
    case revealRecording
}

@MainActor
struct RecordingsSessionLocationActions {
    private let admission: RecordingsCanonicalActionAdmission
    private let openFolder: (RecordingSession) -> Void
    private let revealRecording: (RecordingSession) -> Void

    init(
        currentSessions: @escaping () -> [RecordingSession],
        openFolder: @escaping (RecordingSession) -> Void,
        revealRecording: @escaping (RecordingSession) -> Void
    ) {
        admission = .init(currentSessions: currentSessions)
        self.openFolder = openFolder
        self.revealRecording = revealRecording
    }

    @discardableResult
    func perform(
        _ action: RecordingsSessionLocationAction,
        sessionID: RecordingSession.ID
    ) -> Bool {
        admission.perform(sessionID: sessionID) { session in
            switch action {
            case .openFolder:
                openFolder(session)
            case .revealRecording:
                revealRecording(session)
            }
        }
    }
}
