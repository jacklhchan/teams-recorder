import Foundation

protocol RecordingSessionMetadataStoring: Sendable {
    func load(in folder: URL) -> RecordingSessionMetadata
    func save(_ metadata: RecordingSessionMetadata, in folder: URL) throws
}

struct RecordingSessionMetadataStoreAdapter: RecordingSessionMetadataStoring {
    private static let maximumBytes = 256 * 1_024
    private static let stagePrefix = ".meeting-intelligence-metadata-stage-"

    func load(in folder: URL) -> RecordingSessionMetadata {
        guard let data = try? MeetingIntelligenceStoreFileIO.read(
            named: RecordingSessionMetadataStore.fileName,
            in: folder,
            maximumBytes: Self.maximumBytes
        ) else {
            return RecordingSessionMetadata()
        }
        return (try? Self.decoder.decode(RecordingSessionMetadata.self, from: data))
            ?? RecordingSessionMetadata()
    }

    func save(_ metadata: RecordingSessionMetadata, in folder: URL) throws {
        try metadata.validateForPersistence()
        var metadata = metadata
        metadata.schemaVersion = max(metadata.schemaVersion, RecordingSessionMetadata.currentSchemaVersion)
        let data = try Self.encoder.encode(metadata)
        guard data.count <= Self.maximumBytes else { throw MeetingIntelligenceStoreError.tooLarge }
        let normalizedFolder = try MeetingIntelligenceStoreFileIO.normalizedFolder(folder)
        let destination = try MeetingIntelligenceStoreFileIO.snapshot(
            named: RecordingSessionMetadataStore.fileName,
            in: normalizedFolder,
            maximumBytes: Self.maximumBytes
        )
        let staged = try MeetingIntelligenceStoreFileIO.createSnapshot(
            named: Self.stagePrefix + UUID().uuidString,
            data: data,
            in: normalizedFolder
        )
        do {
            try MeetingIntelligenceStoreFileIO.promote(
                staged,
                to: RecordingSessionMetadataStore.fileName,
                over: destination,
                in: normalizedFolder
            )
        } catch {
            try? MeetingIntelligenceStoreFileIO.remove(staged, in: normalizedFolder)
            throw error
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum MeetingIntelligencePublicationError: LocalizedError, Equatable, Sendable {
    case leaseInvalid
    case transcriptChanged
    case unsafeSessionFolder

    var errorDescription: String? {
        switch self {
        case .leaseInvalid:
            "Meeting intelligence publication was cancelled."
        case .transcriptChanged:
            "The transcript changed before meeting intelligence could be published."
        case .unsafeSessionFolder:
            "The recording session folder is unsafe."
        }
    }
}

final class MeetingIntelligenceAttemptLease: @unchecked Sendable {
    /// The reservation is the linearization point for durable meeting-intelligence
    /// publication. `invalidate()` wins only before `beginCommit()` returns one.
    /// Once reserved, filesystem work happens outside this lock and is allowed to
    /// finish; cancellation never waits for that work.
    final class CommitReservation: @unchecked Sendable {
        private let lease: MeetingIntelligenceAttemptLease
        private let identifier: UInt64
        private var finished = false

        fileprivate init(lease: MeetingIntelligenceAttemptLease, identifier: UInt64) {
            self.lease = lease
            self.identifier = identifier
        }

        var isCurrent: Bool { lease.isReservationCurrent(identifier) }

        func finish() {
            guard !finished else { return }
            finished = true
            lease.finishCommit(identifier)
        }

        deinit { finish() }
    }

    private let lock = NSLock()
    private var valid = true
    private var activeReservation: UInt64?
    private var nextReservation: UInt64 = 0

    var isValid: Bool {
        lock.withLock { valid }
    }

    func invalidate() {
        lock.withLock { valid = false }
    }

    /// Reserves the durable commit. This is deliberately tiny: no filesystem or
    /// gate work occurs under the lock, so a MainActor cancellation cannot block.
    func beginCommit() -> CommitReservation? {
        lock.withLock {
            guard valid, activeReservation == nil else { return nil }
            nextReservation &+= 1
            activeReservation = nextReservation
            return CommitReservation(lease: self, identifier: nextReservation)
        }
    }

    private func isReservationCurrent(_ identifier: UInt64) -> Bool {
        lock.withLock { activeReservation == identifier }
    }

    private func finishCommit(_ identifier: UInt64) {
        lock.withLock {
            guard activeReservation == identifier else { return }
            activeReservation = nil
        }
    }
}

struct MeetingIntelligencePublicationRequest: Sendable {
    let session: RecordingSession
    let sourceRevision: TranscriptDocumentRevision
    let capturedTitle: String?
    let capturedTitleOrigin: RecordingTitleOrigin
    let content: MeetingIntelligenceGeneratedContent
    let snapshot: OpenAICompatibleProviderSnapshot
    let intent: MeetingIntelligenceIntent
    let generatedAt: Date
    let lease: MeetingIntelligenceAttemptLease
}

struct MeetingIntelligencePublicationOutcome: Equatable, Sendable {
    static let metadataWarning =
        "Meeting intelligence was saved, but the generated title could not be applied."

    let artifact: MeetingIntelligenceArtifact
    let titleWasApplied: Bool
    let titleWarning: String?
}

protocol MeetingIntelligencePublishing: Sendable {
    func publish(
        _ request: MeetingIntelligencePublicationRequest
    ) async throws -> MeetingIntelligencePublicationOutcome
}

/// Publishes a completed result only after rechecking the attempt lease and
/// canonical transcript inside the shared per-session mutation boundary.
struct MeetingIntelligencePublisher: MeetingIntelligencePublishing, @unchecked Sendable {
    private let mutationGate: RecordingSessionMutationGate
    private let transcriptReader: any TranscriptDocumentReading
    private let artifactStore: any MeetingIntelligenceArtifactStoring
    private let metadataStore: any RecordingSessionMetadataStoring

    init(
        mutationGate: RecordingSessionMutationGate,
        transcriptReader: any TranscriptDocumentReading = SecureTranscriptDocumentReader(),
        artifactStore: any MeetingIntelligenceArtifactStoring,
        metadataStore: any RecordingSessionMetadataStoring = RecordingSessionMetadataStoreAdapter()
    ) {
        self.mutationGate = mutationGate
        self.transcriptReader = transcriptReader
        self.artifactStore = artifactStore
        self.metadataStore = metadataStore
    }

    func publish(
        _ request: MeetingIntelligencePublicationRequest
    ) async throws -> MeetingIntelligencePublicationOutcome {
        let folder = try normalizedFolder(for: request.session)
        try validate(request, in: folder)

        let artifact = MeetingIntelligenceArtifact(
            schemaVersion: MeetingIntelligenceArtifact.currentSchemaVersion,
            summary: request.content.summary,
            suggestedTitle: request.content.title,
            sourceTranscriptSHA256: request.sourceRevision.sha256,
            sourceTranscriptByteCount: request.sourceRevision.byteCount,
            model: request.snapshot.profile.llmModel,
            generatedAt: request.generatedAt,
            intent: request.intent
        )
        let staged = try artifactStore.stage(artifact, in: folder)
        var promoted = false
        defer {
            if !promoted {
                try? artifactStore.removeStaged(staged, in: folder)
            }
        }

        return try mutationGate.withMutation(for: folder) {
            try validate(request, in: folder)
            guard let commit = request.lease.beginCommit() else {
                throw MeetingIntelligencePublicationError.leaseInvalid
            }
            defer { commit.finish() }
            try artifactStore.promoteStaged(staged, in: folder)
            promoted = true

            var metadata = metadataStore.load(in: folder)
            // A transcript editor or retranscription may have settled while
            // metadata was loaded. Recheck immediately before any title write.
            try validateTranscript(request, in: folder)
            guard canApplyGeneratedTitle(
                current: metadata,
                capturedTitle: request.capturedTitle,
                capturedTitleOrigin: request.capturedTitleOrigin
            ) else {
                return .init(
                    artifact: artifact,
                    titleWasApplied: false,
                    titleWarning: nil
                )
            }

            metadata.applyTitleEdit(.applyMeetingIntelligence(request.content.title))
            do {
                try metadataStore.save(metadata, in: folder)
                return .init(
                    artifact: artifact,
                    titleWasApplied: true,
                    titleWarning: nil
                )
            } catch {
                // The artifact is already valid and visible. Do not leak a
                // filesystem path or provider detail through the warning.
                return .init(
                    artifact: artifact,
                    titleWasApplied: false,
                    titleWarning: MeetingIntelligencePublicationOutcome.metadataWarning
                )
            }
        }
    }

    private func validate(
        _ request: MeetingIntelligencePublicationRequest,
        in folder: URL
    ) throws {
        guard request.lease.isValid else {
            throw MeetingIntelligencePublicationError.leaseInvalid
        }
        try validateTranscript(request, in: folder)
    }

    private func validateTranscript(
        _ request: MeetingIntelligencePublicationRequest,
        in folder: URL
    ) throws {
        let snapshot = try transcriptReader.readCanonical(
            in: folder,
            allowLegacy: false
        )
        guard snapshot.revision == request.sourceRevision else {
            throw MeetingIntelligencePublicationError.transcriptChanged
        }
    }

    private func normalizedFolder(
        for session: RecordingSession
    ) throws -> URL {
        let folder = session.folderURL.standardizedFileURL
        guard folder == session.folderURL.resolvingSymlinksInPath().standardizedFileURL,
              session.id.standardizedFileURL == folder else {
            throw MeetingIntelligencePublicationError.unsafeSessionFolder
        }
        return folder
    }

    private func canApplyGeneratedTitle(
        current: RecordingSessionMetadata,
        capturedTitle: String?,
        capturedTitleOrigin: RecordingTitleOrigin
    ) -> Bool {
        switch current.titleOrigin {
        case .unset:
            return true
        case .meetingIntelligence:
            return capturedTitleOrigin == .meetingIntelligence
                && normalizedTitle(current.title) == normalizedTitle(capturedTitle)
        case .manual:
            return false
        }
    }

    private func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
