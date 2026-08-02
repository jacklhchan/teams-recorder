import Foundation

struct MeetingIntelligenceArtifactEditRequest: Sendable {
    let session: RecordingSession
    let capturedArtifact: MeetingIntelligenceArtifact
    let proposedSummary: String
    let proposedSuggestedTitle: String
    let editedAt: Date
    let lease: MeetingIntelligenceAttemptLease
}

enum MeetingIntelligenceArtifactEditError: LocalizedError, Equatable, Sendable {
    case invalidSummary
    case invalidSuggestedTitle
    case conflict
    case transcriptChanged
    case leaseInvalid
    case unsafeSessionFolder
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .invalidSummary:
            return "The meeting intelligence summary is invalid."
        case .invalidSuggestedTitle:
            return "The meeting intelligence suggested title is invalid."
        case .conflict:
            return "Meeting intelligence changed before the edit could be saved."
        case .transcriptChanged:
            return "The transcript changed before the edit could be saved."
        case .leaseInvalid:
            return "The meeting intelligence edit was cancelled."
        case .unsafeSessionFolder:
            return "The recording session folder is unsafe."
        case .storageFailure:
            return "The meeting intelligence edit could not be saved."
        }
    }
}

protocol MeetingIntelligenceArtifactEditing: Sendable {
    func save(
        _ request: MeetingIntelligenceArtifactEditRequest
    ) async throws -> MeetingIntelligenceArtifact
}

struct MeetingIntelligenceArtifactEditor: MeetingIntelligenceArtifactEditing, @unchecked Sendable {
    private let mutationGate: RecordingSessionMutationGate
    private let transcriptReader: any TranscriptDocumentReading
    private let artifactStore: any MeetingIntelligenceArtifactStoring

    init(
        mutationGate: RecordingSessionMutationGate,
        transcriptReader: any TranscriptDocumentReading,
        artifactStore: any MeetingIntelligenceArtifactStoring
    ) {
        self.mutationGate = mutationGate
        self.transcriptReader = transcriptReader
        self.artifactStore = artifactStore
    }

    func save(
        _ request: MeetingIntelligenceArtifactEditRequest
    ) async throws -> MeetingIntelligenceArtifact {
        guard let summary = MeetingIntelligenceArtifactValidator.summary(request.proposedSummary) else {
            throw MeetingIntelligenceArtifactEditError.invalidSummary
        }
        guard let suggestedTitle = MeetingIntelligenceArtifactValidator.title(request.proposedSuggestedTitle) else {
            throw MeetingIntelligenceArtifactEditError.invalidSuggestedTitle
        }
        guard request.lease.isValid else {
            throw MeetingIntelligenceArtifactEditError.leaseInvalid
        }

        let editedArtifact = MeetingIntelligenceArtifact(
            schemaVersion: MeetingIntelligenceArtifact.currentSchemaVersion,
            summary: summary,
            suggestedTitle: suggestedTitle,
            sourceTranscriptSHA256: request.capturedArtifact.sourceTranscriptSHA256,
            sourceTranscriptByteCount: request.capturedArtifact.sourceTranscriptByteCount,
            model: request.capturedArtifact.model,
            generatedAt: request.capturedArtifact.generatedAt,
            intent: request.capturedArtifact.intent,
            contentOrigin: .edited,
            editedAt: request.editedAt
        )

        let folder = try secureFolder(for: request.session)
        let directoryIdentity = try captureDirectoryIdentity(in: folder)
        guard let secureArtifactStore = artifactStore as? any MeetingIntelligenceArtifactSecureStoring else {
            throw MeetingIntelligenceArtifactEditError.storageFailure
        }

        let staged: URL
        do {
            staged = try secureArtifactStore.stage(
                editedArtifact,
                in: folder,
                expectedDirectory: directoryIdentity
            )
        } catch let error as MeetingIntelligenceArtifactEditError {
            throw error
        } catch {
            throw mapStagingError(error)
        }

        var promoted = false
        defer {
            if !promoted {
                removeStagedSafely(
                    staged,
                    in: folder,
                    expectedDirectory: directoryIdentity
                )
            }
        }

        do {
            return try mutationGate.withMutation(for: folder) {
                try verifyDirectory(folder, matches: directoryIdentity)

                guard try artifactStore.load(in: folder) == request.capturedArtifact else {
                    throw MeetingIntelligenceArtifactEditError.conflict
                }

                let transcript: TranscriptDocumentSnapshot
                do {
                    transcript = try transcriptReader.readCanonical(in: folder, allowLegacy: false)
                } catch let error as SecureTranscriptReadError {
                    if error == .identityChanged {
                        throw MeetingIntelligenceArtifactEditError.transcriptChanged
                    }
                    throw MeetingIntelligenceArtifactEditError.storageFailure
                } catch {
                    throw MeetingIntelligenceArtifactEditError.storageFailure
                }
                guard transcript.revision.sha256 == request.capturedArtifact.sourceTranscriptSHA256,
                      transcript.revision.byteCount == request.capturedArtifact.sourceTranscriptByteCount else {
                    throw MeetingIntelligenceArtifactEditError.transcriptChanged
                }

                try verifyDirectory(folder, matches: directoryIdentity)
                guard request.lease.isValid,
                      let reservation = request.lease.beginCommit() else {
                    throw MeetingIntelligenceArtifactEditError.leaseInvalid
                }
                defer { reservation.finish() }

                do {
                    try artifactStore.promoteStaged(staged, in: folder)
                } catch let error as MeetingIntelligenceArtifactEditError {
                    throw error
                } catch {
                    throw mapPromotionError(error)
                }
                promoted = true
                return editedArtifact
            }
        } catch let error as MeetingIntelligenceArtifactEditError {
            throw error
        } catch {
            throw mapStorageError(error)
        }
    }

    private func secureFolder(for session: RecordingSession) throws -> URL {
        let folder = session.folderURL.standardizedFileURL
        guard folder == session.folderURL.resolvingSymlinksInPath().standardizedFileURL,
              session.id.standardizedFileURL == folder else {
            throw MeetingIntelligenceArtifactEditError.unsafeSessionFolder
        }
        return folder
    }

    private func captureDirectoryIdentity(
        in folder: URL
    ) throws -> MeetingIntelligenceStoreDirectoryIdentity {
        do {
            return try MeetingIntelligenceStoreFileIO.folderIdentity(in: folder)
        } catch {
            throw MeetingIntelligenceArtifactEditError.unsafeSessionFolder
        }
    }

    private func verifyDirectory(
        _ folder: URL,
        matches expected: MeetingIntelligenceStoreDirectoryIdentity
    ) throws {
        do {
            try MeetingIntelligenceStoreFileIO.verifyFolder(folder, matches: expected)
        } catch {
            throw MeetingIntelligenceArtifactEditError.unsafeSessionFolder
        }
    }

    private func removeStagedSafely(
        _ staged: URL,
        in folder: URL,
        expectedDirectory: MeetingIntelligenceStoreDirectoryIdentity
    ) {
        guard (try? MeetingIntelligenceStoreFileIO.verifyFolder(folder, matches: expectedDirectory)) != nil else {
            return
        }
        try? artifactStore.removeStaged(staged, in: folder)
    }

    private func mapStagingError(_ error: Error) -> MeetingIntelligenceArtifactEditError {
        if let error = error as? MeetingIntelligenceArtifactEditError {
            return error
        }
        if let error = error as? MeetingIntelligenceStoreError,
           error == .identityChanged {
            return .unsafeSessionFolder
        }
        return .storageFailure
    }

    private func mapPromotionError(_ error: Error) -> MeetingIntelligenceArtifactEditError {
        if let error = error as? MeetingIntelligenceArtifactEditError {
            return error
        }
        if let error = error as? MeetingIntelligenceStoreError,
           error == .identityChanged {
            return .unsafeSessionFolder
        }
        return .storageFailure
    }

    private func mapStorageError(_ error: Error) -> MeetingIntelligenceArtifactEditError {
        if let error = error as? MeetingIntelligenceArtifactEditError {
            return error
        }
        if let error = error as? MeetingIntelligenceStoreError,
           error == .identityChanged {
            return .unsafeSessionFolder
        }
        return .storageFailure
    }
}
