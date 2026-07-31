import Foundation

/// The only boundary used by meeting-intelligence UI actions to mutate a
/// recording title.  All blocking filesystem work is deliberately performed
/// off the main actor while holding the same gate used by transcript and
/// artifact publication.
struct MeetingIntelligenceSuggestedTitleApplier: @unchecked Sendable {
    private let mutationGate: RecordingSessionMutationGate
    private let transcriptReader: any TranscriptDocumentReading
    private let metadataStore: any RecordingSessionMetadataStoring

    init(
        mutationGate: RecordingSessionMutationGate,
        transcriptReader: any TranscriptDocumentReading = SecureTranscriptDocumentReader(),
        metadataStore: any RecordingSessionMetadataStoring = RecordingSessionMetadataStoreAdapter()
    ) {
        self.mutationGate = mutationGate
        self.transcriptReader = transcriptReader
        self.metadataStore = metadataStore
    }

    func applySuggestedTitle(_ request: MeetingIntelligenceSuggestedTitleRequest) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
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
                try validate(request, in: folder)
                metadata.applyTitleEdit(.applyMeetingIntelligence(request.artifact.suggestedTitle))
                try validate(request, in: folder)
                try metadataStore.save(metadata, in: folder)
                return true
            }
        }.value
    }

    private func validate(
        _ request: MeetingIntelligenceSuggestedTitleRequest,
        in folder: URL
    ) throws {
        guard !Task.isCancelled, request.lease.isValid else {
            throw MeetingIntelligencePublicationError.leaseInvalid
        }
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
