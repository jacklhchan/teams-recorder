import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligenceSuggestedTitleApplierTests: XCTestCase {
    func testApplierPreservesUnknownMetadataAndMarksMeetingIntelligenceOrigin() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        try Data(#"{"schemaVersion":2,"title":"Old","titleOrigin":"meetingIntelligence","vendor":{"keep":[1,2]}}"#.utf8)
            .write(to: RecordingSessionMetadataStore.fileURL(in: folder))
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(
            mutationGate: RecordingSessionMutationGate(),
            transcriptReader: FixedReader(revision: transcript)
        )

        let applied = try await applier.applySuggestedTitle(request(session: session, revision: transcript))

        XCTAssertTrue(applied)
        let data = try Data(contentsOf: RecordingSessionMetadataStore.fileURL(in: folder))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Customer planning review")
        XCTAssertEqual(object["titleOrigin"] as? String, "meetingIntelligence")
        let vendor = try XCTUnwrap(object["vendor"] as? [String: Any])
        XCTAssertEqual(vendor["keep"] as? [NSNumber], [1, 2])
    }

    func testInvalidLeaseRefusesMetadataWrite() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        let store = RecordingMetadataProbe()
        let lease = MeetingIntelligenceAttemptLease()
        lease.invalidate()
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(mutationGate: .init(),
                                                                transcriptReader: FixedReader(revision: revision),
                                                                metadataStore: store)

        do {
            _ = try await applier.applySuggestedTitle(request(session: session, revision: revision, lease: lease))
            XCTFail("Expected cancelled title apply")
        } catch let error as MeetingIntelligencePublicationError {
            XCTAssertEqual(error, .leaseInvalid)
        }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testDefaultMetadataAdapterRejectsSymlinkInsteadOfWritingOutsideSession() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        let original = Data(#"{"vendor":{"nested":[1,{"keep":true}]}}"#.utf8)
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: RecordingSessionMetadataStore.fileURL(in: folder),
            withDestinationURL: outside
        )
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(
            mutationGate: .init(), transcriptReader: FixedReader(revision: revision)
        )

        do {
            _ = try await applier.applySuggestedTitle(request(session: session, revision: revision))
            XCTFail("Expected unsafe metadata rejection")
        } catch {
            XCTAssertEqual(error as? MeetingIntelligenceStoreError, .unsafeFile)
        }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testCapturedManualTitleCanBeExplicitlyReplaced() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        let metadata = RecordingMetadataProbe(metadata: .init(title: "Customer supplied", titleOrigin: .manual))
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(mutationGate: .init(),
                                                                transcriptReader: FixedReader(revision: revision),
                                                                metadataStore: metadata)
        let request = MeetingIntelligenceSuggestedTitleRequest(
            session: session,
            artifact: .init(schemaVersion: 1, summary: "Summary", suggestedTitle: "Generated title",
                            sourceTranscriptSHA256: revision.sha256, sourceTranscriptByteCount: revision.byteCount,
                            model: "model", generatedAt: .distantPast, intent: .generate),
            sourceRevision: revision, capturedTitle: "Customer supplied", capturedTitleOrigin: .manual,
            lease: .init()
        )

        let applied = try await applier.applySuggestedTitle(request)
        XCTAssertTrue(applied)
        XCTAssertEqual(metadata.saved?.title, "Generated title")
        XCTAssertEqual(metadata.saved?.titleOrigin, .meetingIntelligence)
    }

    func testLeaseInvalidatedAfterMetadataLoadPreventsSave() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        let loaded = expectation(description: "metadata loaded")
        let release = DispatchSemaphore(value: 0)
        let store = BlockingMetadataProbe(loaded: loaded, release: release)
        let lease = MeetingIntelligenceAttemptLease()
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(mutationGate: .init(),
                                                                transcriptReader: FixedReader(revision: revision),
                                                                metadataStore: store)
        let work = Task { try await applier.applySuggestedTitle(request(session: session, revision: revision, lease: lease)) }

        await fulfillment(of: [loaded], timeout: 1)
        lease.invalidate()
        release.signal()
        do { _ = try await work.value; XCTFail("Expected invalidated apply") }
        catch let error as MeetingIntelligencePublicationError { XCTAssertEqual(error, .leaseInvalid) }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testChangedMetadataAfterClickReturnsFalseWithoutSaveOffMainActor() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        let store = RecordingMetadataProbe(metadata: .init(title: "Edited after click", titleOrigin: .manual))
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(mutationGate: .init(),
                                                                transcriptReader: FixedReader(revision: revision),
                                                                metadataStore: store)

        let applied = try await applier.applySuggestedTitle(request(session: session, revision: revision))

        XCTAssertFalse(applied)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertFalse(store.loadWasOnMainThread)
    }

    func testExactAlreadyAppliedMeetingIntelligenceTitleReturnsFalseWithoutMetadataWrite() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let revision = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        let store = RecordingMetadataProbe(
            metadata: .init(title: "  Customer planning review  ", titleOrigin: .meetingIntelligence)
        )
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(
            mutationGate: .init(), transcriptReader: FixedReader(revision: revision), metadataStore: store
        )
        let request = MeetingIntelligenceSuggestedTitleRequest(
            session: session,
            artifact: .init(schemaVersion: 1, summary: "Summary", suggestedTitle: "Customer planning review",
                            sourceTranscriptSHA256: revision.sha256, sourceTranscriptByteCount: revision.byteCount,
                            model: "model", generatedAt: .distantPast, intent: .generate),
            sourceRevision: revision,
            capturedTitle: "Customer planning review",
            capturedTitleOrigin: .meetingIntelligence,
            lease: .init()
        )

        let applied = try await applier.applySuggestedTitle(request)

        XCTAssertFalse(applied)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testTranscriptChangedBetweenGateChecksPreventsTitleSave() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = TranscriptDocumentRevision(sha256: "sha256:expected", byteCount: 8)
        let changed = TranscriptDocumentRevision(sha256: "sha256:changed", byteCount: 7)
        let loaded = expectation(description: "metadata loaded")
        let release = DispatchSemaphore(value: 0)
        let store = BlockingMetadataProbe(loaded: loaded, release: release)
        let reader = MutableReader(revision: expected)
        let session = RecordingSession(id: folder, folderURL: folder,
                                       recordingURL: folder.appendingPathComponent("recording.m4a"),
                                       createdAt: .distantPast, duration: 0, fileSize: 0, metadata: .init())
        let applier = MeetingIntelligenceSuggestedTitleApplier(mutationGate: .init(), transcriptReader: reader,
                                                                metadataStore: store)
        let work = Task { try await applier.applySuggestedTitle(request(session: session, revision: expected)) }

        await fulfillment(of: [loaded], timeout: 1)
        reader.revision = changed
        release.signal()
        do { _ = try await work.value; XCTFail("Expected transcript mismatch") }
        catch let error as MeetingIntelligencePublicationError { XCTAssertEqual(error, .transcriptChanged) }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testPreparedMetadataCapabilityRejectsFolderReplacementBeforeLoad() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data(#"{"vendor":{"nested":[1,{"keep":true}]}}"#.utf8)
        try original.write(to: RecordingSessionMetadataStore.fileURL(in: folder))
        let adapter = RecordingSessionMetadataStoreAdapter()
        let capability = try adapter.prepare(in: folder)
        let swap = FolderSwap(folder: folder, replacementMetadata: Data(#"{"vendor":"replacement"}"#.utf8))
        swap.replace()

        XCTAssertThrowsError(try adapter.load(in: capability)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: RecordingSessionMetadataStore.fileURL(in: folder)), swap.replacementMetadata)
    }

    func testMetadataCapabilityBeforeCreateSwapRejectsWithoutReplacementWrite() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"vendor":"original"}"#.utf8).write(to: RecordingSessionMetadataStore.fileURL(in: folder))
        let swap = FolderSwap(folder: folder, replacementMetadata: Data(#"{"vendor":"replacement"}"#.utf8))
        let adapter = RecordingSessionMetadataStoreAdapter(beforeCreate: { swap.replace() })
        let capability = try adapter.prepare(in: folder)

        XCTAssertThrowsError(try adapter.save(.init(title: "Generated", titleOrigin: .meetingIntelligence), in: capability)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: RecordingSessionMetadataStore.fileURL(in: folder)), swap.replacementMetadata)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix(".meeting-intelligence-metadata-stage-") })
    }

    func testMetadataCapabilityBeforeRenameSwapRejectsWithoutReplacementWrite() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"vendor":"original"}"#.utf8).write(to: RecordingSessionMetadataStore.fileURL(in: folder))
        let swap = FolderSwap(folder: folder, replacementMetadata: Data(#"{"vendor":"replacement"}"#.utf8))
        let adapter = RecordingSessionMetadataStoreAdapter(beforeRename: { swap.replace() })
        let capability = try adapter.prepare(in: folder)

        XCTAssertThrowsError(try adapter.save(.init(title: "Generated", titleOrigin: .meetingIntelligence), in: capability)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: RecordingSessionMetadataStore.fileURL(in: folder)), swap.replacementMetadata)
    }

    func testMetadataCapabilityRoundTripsExactNestedUnknownObjectAndArray() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data(#"{"schemaVersion":2,"vendor":{"items":[1,{"inner":["one",false,{"deep":"value"}]}],"flag":true},"other":[{"name":"preserve"},3]}"#.utf8)
        try original.write(to: RecordingSessionMetadataStore.fileURL(in: folder))
        let adapter = RecordingSessionMetadataStoreAdapter()
        let capability = try adapter.prepare(in: folder)
        var metadata = try adapter.load(in: capability)
        metadata.applyTitleEdit(.applyMeetingIntelligence("Generated"))
        try adapter.save(metadata, in: capability)

        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let afterData = try Data(contentsOf: RecordingSessionMetadataStore.fileURL(in: folder))
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [String: Any])
        XCTAssertEqual(after["vendor"] as? NSDictionary, before["vendor"] as? NSDictionary)
        XCTAssertEqual(after["other"] as? NSArray, before["other"] as? NSArray)
    }

    private func request(session: RecordingSession, revision: TranscriptDocumentRevision,
                         lease: MeetingIntelligenceAttemptLease = .init()) -> MeetingIntelligenceSuggestedTitleRequest {
        .init(session: session,
              artifact: .init(schemaVersion: 1, summary: "Summary", suggestedTitle: "Customer planning review",
                              sourceTranscriptSHA256: revision.sha256, sourceTranscriptByteCount: revision.byteCount,
                              model: "model", generatedAt: .distantPast, intent: .generate),
              sourceRevision: revision, capturedTitle: "Old", capturedTitleOrigin: .meetingIntelligence, lease: lease)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}


private struct FixedReader: TranscriptDocumentReading {
    let revision: TranscriptDocumentRevision
    func readCanonical(in folder: URL, allowLegacy _: Bool) throws -> TranscriptDocumentSnapshot {
        .init(url: folder.appendingPathComponent("transcript.txt"), data: Data("contents".utf8), revision: revision)
    }
}

private final class RecordingMetadataProbe: RecordingSessionMetadataStoring, @unchecked Sendable {
    private(set) var saveCount = 0
    private let metadata: RecordingSessionMetadata
    private(set) var saved: RecordingSessionMetadata?
    private(set) var loadWasOnMainThread = false
    init(metadata: RecordingSessionMetadata = .init()) { self.metadata = metadata }
    func load(in _: URL) -> RecordingSessionMetadata { loadWasOnMainThread = Thread.isMainThread; return metadata }
    func save(_ metadata: RecordingSessionMetadata, in _: URL) throws { saveCount += 1; saved = metadata }
}

private final class BlockingMetadataProbe: RecordingSessionMetadataStoring, @unchecked Sendable {
    let loaded: XCTestExpectation
    let release: DispatchSemaphore
    private(set) var saveCount = 0
    init(loaded: XCTestExpectation, release: DispatchSemaphore) { self.loaded = loaded; self.release = release }
    func load(in _: URL) -> RecordingSessionMetadata { loaded.fulfill(); release.wait(); return .init(title: "Old", titleOrigin: .meetingIntelligence) }
    func save(_: RecordingSessionMetadata, in _: URL) throws { saveCount += 1 }
}

private final class MutableReader: TranscriptDocumentReading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRevision: TranscriptDocumentRevision
    init(revision: TranscriptDocumentRevision) { storedRevision = revision }
    var revision: TranscriptDocumentRevision {
        get { lock.withLock { storedRevision } }
        set { lock.withLock { storedRevision = newValue } }
    }
    func readCanonical(in folder: URL, allowLegacy _: Bool) throws -> TranscriptDocumentSnapshot {
        let revision = self.revision
        return .init(url: folder.appendingPathComponent("transcript.txt"), data: Data("contents".utf8), revision: revision)
    }
}

private final class FolderSwap: @unchecked Sendable {
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
