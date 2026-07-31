import Foundation

private actor MeetingIntelligenceFileMutationExecutor {
    func run<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        try operation()
    }
}

/// The only boundary used by meeting-intelligence UI actions to mutate a
/// recording title.  All blocking filesystem work is deliberately performed
/// off the main actor while holding the same gate used by transcript and
/// artifact publication.
struct MeetingIntelligenceSuggestedTitleApplier: @unchecked Sendable {
    private let mutationGate: RecordingSessionMutationGate
    private let transcriptReader: any TranscriptDocumentReading
    private let metadataStore: any RecordingSessionMetadataStoring
    private let executor: MeetingIntelligenceFileMutationExecutor

    init(
        mutationGate: RecordingSessionMutationGate,
        transcriptReader: any TranscriptDocumentReading = SecureTranscriptDocumentReader(),
        metadataStore: any RecordingSessionMetadataStoring = RecordingSessionMetadataStoreAdapter()
    ) {
        self.mutationGate = mutationGate
        self.transcriptReader = transcriptReader
        self.metadataStore = metadataStore
        executor = .init()
    }

    func applySuggestedTitle(_ request: MeetingIntelligenceSuggestedTitleRequest) async throws -> Bool {
        try await executor.run {
            let folder = try normalizedFolder(for: request.session)
            return try mutationGate.withMutation(for: folder) {
                try validate(request, in: folder)
                var metadata = metadataStore.load(in: folder)
                guard metadataMatchesCapturedValue(metadata, request: request) else {
                    return false
                }
                // The reader check is intentionally repeated immediately
                // before the metadata write: a manually edited transcript
                // must never receive a title generated from old bytes.
                try validateTranscript(request, in: folder)
                guard let commit = request.lease.beginCommit() else {
                    throw MeetingIntelligencePublicationError.leaseInvalid
                }
                defer { commit.finish() }
                metadata.applyTitleEdit(.applyMeetingIntelligence(request.artifact.suggestedTitle))
                try validateTranscript(request, in: folder)
                try metadataStore.save(metadata, in: folder)
                return true
            }
        }
    }

    private func validate(
        _ request: MeetingIntelligenceSuggestedTitleRequest,
        in folder: URL
    ) throws {
        guard !Task.isCancelled, request.lease.isValid else {
            throw MeetingIntelligencePublicationError.leaseInvalid
        }
        try validateTranscript(request, in: folder)
    }

    private func validateTranscript(
        _ request: MeetingIntelligenceSuggestedTitleRequest,
        in folder: URL
    ) throws {
        let current = try transcriptReader.readCanonical(in: folder, allowLegacy: false)
        guard current.revision == request.sourceRevision,
              request.artifact.sourceTranscriptSHA256 == current.revision.sha256,
              request.artifact.sourceTranscriptByteCount == current.revision.byteCount else {
            throw MeetingIntelligencePublicationError.transcriptChanged
        }
    }

    private func normalizedFolder(for session: RecordingSession) throws -> URL {
        let folder = session.folderURL.standardizedFileURL
        guard folder == session.folderURL.resolvingSymlinksInPath().standardizedFileURL,
              session.id.standardizedFileURL == folder else {
            throw MeetingIntelligencePublicationError.unsafeSessionFolder
        }
        return folder
    }

    private func metadataMatchesCapturedValue(
        _ metadata: RecordingSessionMetadata,
        request: MeetingIntelligenceSuggestedTitleRequest
    ) -> Bool {
        metadata.titleOrigin == request.capturedTitleOrigin &&
            normalizedTitle(metadata.title) == normalizedTitle(request.capturedTitle)
    }

    private func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
