import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligencePublisherTests: XCTestCase {
    func testLeaseInvalidatedBeforeCommitReservationRejectsButAfterReservationCommitWins() throws {
        let lease = MeetingIntelligenceAttemptLease()
        lease.invalidate()
        XCTAssertNil(lease.beginCommit())

        let committed = MeetingIntelligenceAttemptLease()
        let reservation = try XCTUnwrap(committed.beginCommit())
        committed.invalidate()
        XCTAssertFalse(committed.isValid)
        XCTAssertTrue(reservation.isCurrent)
        reservation.finish()
    }

    func testDefaultArtifactStageRejectsReplacementAfterMetadataCapabilityWithoutWritingReplacementFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = folder.appendingPathComponent("transcript.txt")
        let transcriptData = Data("Transcript text".utf8)
        try transcriptData.write(to: transcript)
        let metadataURL = RecordingSessionMetadataStore.fileURL(in: folder)
        try Data(#"{"vendor":"original"}"#.utf8).write(to: metadataURL)
        let replacement = Data(#"{"vendor":"replacement"}"#.utf8)
        let swap = PublisherFolderSwap(folder: folder, replacementMetadata: replacement)
        let revision = TranscriptDocumentRevision(
            sha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            byteCount: transcriptData.count
        )
        let reader = PublisherTranscriptReader(url: transcript, data: transcriptData, revision: revision)
        let artifactStore = MeetingIntelligenceArtifactStore(
            mutationGate: .init(),
            beforeStageCreate: { swap.replace() }
        )
        let publisher = MeetingIntelligencePublisher(
            mutationGate: .init(), transcriptReader: reader, artifactStore: artifactStore
        )
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let snapshot = try OpenAICompatibleProviderSnapshot.validated(
            profile: .validated(baseURLText: "http://127.0.0.1:8080", asrModel: "asr", llmModel: "llm", language: "en", prompt: ""),
            apiKey: nil
        )
        let request = MeetingIntelligencePublicationRequest(
            session: session, sourceRevision: revision, capturedTitle: nil, capturedTitleOrigin: .unset,
            content: .init(title: "Project decision", summary: "Decision summary"), snapshot: snapshot,
            intent: .generate, generatedAt: .distantPast, lease: .init()
        )

        await assertStoreError(.identityChanged) { _ = try await publisher.publish(request) }
        XCTAssertEqual(try Data(contentsOf: metadataURL), replacement)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(MeetingIntelligenceArtifactStore.fileName).path
        ))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix(".meeting-intelligence-stage-") })
    }
    func testUnsetTitlePublishesArtifactAndAppliesGeneratedTitle() async throws {
        let fixture = try PublicationFixture(metadata: .init(title: nil, titleOrigin: .unset))
        defer { fixture.remove() }

        let outcome = try await fixture.publisher.publish(fixture.request)

        XCTAssertTrue(outcome.titleWasApplied)
        XCTAssertNil(outcome.titleWarning)
        XCTAssertEqual(outcome.artifact.summary, "Decision summary")
        XCTAssertEqual(fixture.metadata.title, "Project decision")
        XCTAssertEqual(fixture.metadata.titleOrigin, .meetingIntelligence)
        XCTAssertEqual(fixture.artifactStore.promotions, 1)
        XCTAssertEqual(fixture.artifactStore.cleanups, 0)
        XCTAssertEqual(fixture.artifactStore.visibleArtifact?.summary, "Decision summary")
    }

    func testMeetingIntelligenceOwnedTitleIsReplacedByNextCapturedMeetingIntelligenceTitle() async throws {
        let fixture = try PublicationFixture(metadata: .init(title: nil, titleOrigin: .unset))
        defer { fixture.remove() }

        let first = try await fixture.publisher.publish(fixture.request)
        let next = fixture.request.replacing(
            capturedTitle: fixture.metadata.title,
            capturedTitleOrigin: fixture.metadata.titleOrigin,
            content: .init(title: "Follow-up decision", summary: "Follow-up summary")
        )
        let second = try await fixture.publisher.publish(next)

        XCTAssertTrue(first.titleWasApplied)
        XCTAssertTrue(second.titleWasApplied)
        XCTAssertEqual(fixture.metadata.title, "Follow-up decision")
        XCTAssertEqual(fixture.metadata.titleOrigin, .meetingIntelligence)
    }

    func testManualTitleAndManualClearStoreSuggestionWithoutOverwriting() async throws {
        for metadata in [
            RecordingSessionMetadata(title: "Customer title", titleOrigin: .manual),
            RecordingSessionMetadata(title: nil, titleOrigin: .manual)
        ] {
            let fixture = try PublicationFixture(metadata: metadata)
            defer { fixture.remove() }

            let outcome = try await fixture.publisher.publish(fixture.request)

            XCTAssertFalse(outcome.titleWasApplied)
            XCTAssertNil(outcome.titleWarning)
            XCTAssertEqual(fixture.metadata, metadata)
            XCTAssertEqual(outcome.artifact.suggestedTitle, "Project decision")
        }
    }

    func testInvalidLeaseOrChangedDigestDoesNotPromoteArtifact() async throws {
        let invalidLease = try PublicationFixture(metadata: .init())
        defer { invalidLease.remove() }
        invalidLease.request.lease.invalidate()
        await assertPublicationError(.leaseInvalid) {
            _ = try await invalidLease.publisher.publish(invalidLease.request)
        }
        XCTAssertEqual(invalidLease.artifactStore.promotions, 0)

        let changedDigest = try PublicationFixture(metadata: .init())
        defer { changedDigest.remove() }
        changedDigest.reader.revision = .init(sha256: "sha256:changed", byteCount: 1)
        await assertPublicationError(.transcriptChanged) {
            _ = try await changedDigest.publisher.publish(changedDigest.request)
        }
        XCTAssertEqual(changedDigest.artifactStore.promotions, 0)
    }

    func testPostStageRejectionAndPromotionFailureRemoveCandidate() async throws {
        let rejected = try PublicationFixture(metadata: .init())
        defer { rejected.remove() }
        rejected.artifactStore.onStage = { rejected.request.lease.invalidate() }

        await assertPublicationError(.leaseInvalid) {
            _ = try await rejected.publisher.publish(rejected.request)
        }
        XCTAssertEqual(rejected.artifactStore.promotions, 0)
        XCTAssertEqual(rejected.artifactStore.cleanups, 1)
        XCTAssertNil(rejected.artifactStore.stagedArtifact)
        XCTAssertNil(rejected.artifactStore.visibleArtifact)

        let promotionFailure = try PublicationFixture(metadata: .init())
        defer { promotionFailure.remove() }
        promotionFailure.artifactStore.promoteError = TestError.saveFailed

        do {
            _ = try await promotionFailure.publisher.publish(promotionFailure.request)
            XCTFail("Expected promotion failure")
        } catch {}
        XCTAssertEqual(promotionFailure.artifactStore.promotions, 0)
        XCTAssertEqual(promotionFailure.artifactStore.cleanups, 1)
        XCTAssertNil(promotionFailure.artifactStore.stagedArtifact)
        XCTAssertNil(promotionFailure.artifactStore.visibleArtifact)
    }

    func testManualRenameAtMetadataBarrierCannotBeOverwritten() async throws {
        let fixture = try PublicationFixture(metadata: .init(title: nil, titleOrigin: .unset))
        defer { fixture.remove() }
        fixture.metadataStore.beforeLoad = {
            fixture.metadata = .init(title: "Customer-owned title", titleOrigin: .manual)
        }

        let outcome = try await fixture.publisher.publish(fixture.request)

        XCTAssertFalse(outcome.titleWasApplied)
        XCTAssertEqual(fixture.metadata.title, "Customer-owned title")
        XCTAssertEqual(fixture.metadata.titleOrigin, .manual)
    }

    func testTranscriptChangeAtMetadataLoadBeforeCommitDoesNotPromoteArtifact() async throws {
        let fixture = try PublicationFixture(metadata: .init())
        defer { fixture.remove() }
        fixture.metadataStore.beforeLoad = {
            fixture.reader.revision = .init(sha256: "sha256:new", byteCount: 1)
        }

        await assertPublicationError(.transcriptChanged) {
            _ = try await fixture.publisher.publish(fixture.request)
        }
        XCTAssertEqual(fixture.artifactStore.promotions, 0)
        XCTAssertNil(fixture.metadata.title)
    }

    func testMalformedSecureMetadataDoesNotPromoteArtifact() async throws {
        let fixture = try SecureMetadataPublicationFixture(metadataData: Data("not json".utf8))
        defer { fixture.remove() }

        do {
            _ = try await fixture.publisher.publish(fixture.request)
            XCTFail("Expected secure metadata decoding failure")
        } catch is DecodingError {
            // The secure adapter deliberately preserves its JSON decoder category.
        } catch {
            XCTFail("Expected DecodingError, got \(error)")
        }

        XCTAssertEqual(fixture.artifactStore.promotions, 0)
        XCTAssertEqual(fixture.artifactStore.cleanups, 1)
        XCTAssertNil(fixture.artifactStore.stagedArtifact)
        XCTAssertNil(fixture.artifactStore.visibleArtifact)
    }

    func testLeaseInvalidatedAfterCommitReservationCompletesPublication() async throws {
        let fixture = try PublicationFixture(metadata: .init())
        defer { fixture.remove() }
        fixture.artifactStore.onPromote = { fixture.request.lease.invalidate() }

        let outcome = try await fixture.publisher.publish(fixture.request)

        XCTAssertEqual(fixture.artifactStore.promotions, 1)
        XCTAssertTrue(outcome.titleWasApplied)
        XCTAssertEqual(fixture.metadata.title, "Project decision")
    }

    func testMetadataSaveFailurePreservesPublishedArtifactAndReturnsWarning() async throws {
        let fixture = try PublicationFixture(metadata: .init(title: nil, titleOrigin: .unset))
        defer { fixture.remove() }
        fixture.metadataStore.saveError = TestError.saveFailed

        let outcome = try await fixture.publisher.publish(fixture.request)

        XCTAssertFalse(outcome.titleWasApplied)
        XCTAssertEqual(outcome.titleWarning, MeetingIntelligencePublicationOutcome.metadataWarning)
        XCTAssertEqual(fixture.artifactStore.promotions, 1)
        XCTAssertEqual(fixture.metadata.title, nil)
    }

    private func assertPublicationError(
        _ expected: MeetingIntelligencePublicationError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected publication failure")
        } catch {
            XCTAssertEqual(error as? MeetingIntelligencePublicationError, expected)
        }
    }

    private func assertStoreError(
        _ expected: MeetingIntelligenceStoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected store failure")
        } catch {
            XCTAssertEqual(error as? MeetingIntelligenceStoreError, expected)
        }
    }
}

private enum TestError: Error { case saveFailed }

private extension MeetingIntelligencePublicationRequest {
    func replacing(
        capturedTitle: String?,
        capturedTitleOrigin: RecordingTitleOrigin,
        content: MeetingIntelligenceGeneratedContent
    ) -> Self {
        .init(session: session, sourceRevision: sourceRevision, capturedTitle: capturedTitle,
              capturedTitleOrigin: capturedTitleOrigin, content: content, snapshot: snapshot,
              intent: intent, generatedAt: generatedAt, lease: .init())
    }
}

private final class SecureMetadataPublicationFixture: @unchecked Sendable {
    let root: URL
    let folder: URL
    let reader: PublisherTranscriptReader
    let artifactStore = PublisherArtifactStore()
    let publisher: MeetingIntelligencePublisher
    let request: MeetingIntelligencePublicationRequest

    init(metadataData: Data) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("secure-session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("transcript.txt")
        let data = Data("Transcript text".utf8)
        try data.write(to: transcript)
        try metadataData.write(to: RecordingSessionMetadataStore.fileURL(in: folder))
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: data.count)
        reader = PublisherTranscriptReader(url: transcript, data: data, revision: revision)
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        publisher = .init(mutationGate: .init(), transcriptReader: reader, artifactStore: artifactStore,
                          metadataStore: RecordingSessionMetadataStoreAdapter())
        request = .init(session: session, sourceRevision: revision, capturedTitle: nil, capturedTitleOrigin: .unset,
                        content: .init(title: "Project decision", summary: "Decision summary"),
                        snapshot: try .validated(profile: .validated(baseURLText: "http://127.0.0.1:8080", asrModel: "asr", llmModel: "llm", language: "en", prompt: ""), apiKey: nil),
                        intent: .generate, generatedAt: .distantPast, lease: .init())
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class PublicationFixture: @unchecked Sendable {
    let root: URL
    let folder: URL
    let session: RecordingSession
    let reader: PublisherTranscriptReader
    let artifactStore = PublisherArtifactStore()
    let metadataStore: PublisherMetadataStore
    let publisher: MeetingIntelligencePublisher
    var metadata: RecordingSessionMetadata {
        get { metadataStore.metadata }
        set { metadataStore.metadata = newValue }
    }
    let request: MeetingIntelligencePublicationRequest

    init(
        metadata: RecordingSessionMetadata,
        capturedTitle: String? = nil,
        capturedTitleOrigin: RecordingTitleOrigin = .unset
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("manual-session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("transcript.txt")
        let data = Data("Transcript text".utf8)
        try data.write(to: transcript)
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: data.count)
        reader = PublisherTranscriptReader(url: transcript, data: data, revision: revision)
        metadataStore = PublisherMetadataStore(metadata: metadata)
        session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 0,
            fileSize: 0,
            metadata: metadata
        )
        let gate = RecordingSessionMutationGate()
        publisher = MeetingIntelligencePublisher(
            mutationGate: gate,
            transcriptReader: reader,
            artifactStore: artifactStore,
            metadataStore: metadataStore
        )
        request = .init(
            session: session,
            sourceRevision: revision,
            capturedTitle: capturedTitle,
            capturedTitleOrigin: capturedTitleOrigin,
            content: .init(title: "Project decision", summary: "Decision summary"),
            snapshot: try .validated(profile: .validated(baseURLText: "http://127.0.0.1:8080", asrModel: "asr", llmModel: "llm", language: "en", prompt: ""), apiKey: nil),
            intent: .generate,
            generatedAt: .distantPast,
            lease: .init()
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class PublisherTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    let url: URL
    let data: Data
    var revision: TranscriptDocumentRevision

    init(url: URL, data: Data, revision: TranscriptDocumentRevision) {
        self.url = url
        self.data = data
        self.revision = revision
    }

    func readCanonical(in _: URL, allowLegacy _: Bool) throws -> TranscriptDocumentSnapshot {
        .init(url: url, data: data, revision: revision)
    }
}

private final class PublisherArtifactStore: MeetingIntelligenceArtifactStoring, @unchecked Sendable {
    private(set) var stagedArtifact: MeetingIntelligenceArtifact?
    private(set) var visibleArtifact: MeetingIntelligenceArtifact?
    private(set) var promotions = 0
    private(set) var cleanups = 0
    var onStage: (() -> Void)?
    var onPromote: (() -> Void)?
    var promoteError: Error?

    func load(in _: URL) throws -> MeetingIntelligenceArtifact? { nil }
    func stage(_ artifact: MeetingIntelligenceArtifact, in folder: URL) throws -> URL {
        stagedArtifact = artifact
        onStage?()
        onStage = nil
        return folder.appendingPathComponent(".meeting-intelligence-stage-test")
    }
    func promoteStaged(_: URL, in _: URL) throws {
        if let promoteError { throw promoteError }
        promotions += 1
        visibleArtifact = stagedArtifact
        stagedArtifact = nil
        onPromote?()
        onPromote = nil
    }
    func removeStaged(_: URL, in _: URL) throws {
        cleanups += 1
        stagedArtifact = nil
    }
}

private final class PublisherMetadataStore: RecordingSessionMetadataStoring, @unchecked Sendable {
    var metadata: RecordingSessionMetadata
    var saveError: Error?
    var beforeLoad: (() -> Void)?

    init(metadata: RecordingSessionMetadata) { self.metadata = metadata }
    func load(in _: URL) -> RecordingSessionMetadata {
        beforeLoad?()
        beforeLoad = nil
        return metadata
    }
    func save(_ metadata: RecordingSessionMetadata, in _: URL) throws {
        if let saveError { throw saveError }
        self.metadata = metadata
    }
}

private final class PublisherFolderSwap: @unchecked Sendable {
    let folder: URL
    let replacementMetadata: Data
    private let lock = NSLock()
    private var didSwap = false

    init(folder: URL, replacementMetadata: Data) {
        self.folder = folder
        self.replacementMetadata = replacementMetadata
    }

    func replace() {
        lock.withLock {
            guard !didSwap else { return }
            didSwap = true
            let moved = folder.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.moveItem(at: folder, to: moved)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try replacementMetadata.write(to: RecordingSessionMetadataStore.fileURL(in: folder))
            } catch {
                XCTFail("Could not replace test session folder: \(error)")
            }
        }
    }
}
