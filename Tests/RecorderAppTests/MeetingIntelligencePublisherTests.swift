import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligencePublisherTests: XCTestCase {
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

    func testGeneratedTitleReplacesOnlyCapturedGeneratedTitle() async throws {
        let fixture = try PublicationFixture(
            metadata: .init(title: "Previous generated", titleOrigin: .meetingIntelligence),
            capturedTitle: "Previous generated",
            capturedTitleOrigin: .meetingIntelligence
        )
        defer { fixture.remove() }

        let outcome = try await fixture.publisher.publish(fixture.request)

        XCTAssertTrue(outcome.titleWasApplied)
        XCTAssertEqual(fixture.metadata.title, "Project decision")
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

    func testTranscriptChangeAfterPromotionOrMetadataLoadDoesNotWriteTitle() async throws {
        let afterPromotion = try PublicationFixture(metadata: .init())
        defer { afterPromotion.remove() }
        afterPromotion.artifactStore.onPromote = {
            afterPromotion.reader.revision = .init(sha256: "sha256:new", byteCount: 1)
        }
        await assertPublicationError(.transcriptChanged) {
            _ = try await afterPromotion.publisher.publish(afterPromotion.request)
        }
        XCTAssertEqual(afterPromotion.artifactStore.promotions, 1)
        XCTAssertNil(afterPromotion.metadata.title)

        let beforeMetadataWrite = try PublicationFixture(metadata: .init())
        defer { beforeMetadataWrite.remove() }
        beforeMetadataWrite.metadataStore.beforeLoad = {
            beforeMetadataWrite.reader.revision = .init(sha256: "sha256:new", byteCount: 1)
        }
        await assertPublicationError(.transcriptChanged) {
            _ = try await beforeMetadataWrite.publisher.publish(beforeMetadataWrite.request)
        }
        XCTAssertEqual(beforeMetadataWrite.artifactStore.promotions, 1)
        XCTAssertNil(beforeMetadataWrite.metadata.title)
    }

    func testLeaseInvalidatedAfterPromotionDoesNotWriteTitle() async throws {
        let fixture = try PublicationFixture(metadata: .init())
        defer { fixture.remove() }
        fixture.artifactStore.onPromote = { fixture.request.lease.invalidate() }

        await assertPublicationError(.leaseInvalid) {
            _ = try await fixture.publisher.publish(fixture.request)
        }

        XCTAssertEqual(fixture.artifactStore.promotions, 1)
        XCTAssertNil(fixture.metadata.title)
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
}

private enum TestError: Error { case saveFailed }

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
