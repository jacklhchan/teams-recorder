import CryptoKit
import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligenceArtifactEditorTests: XCTestCase {
    func testSavesEditedArtifactWithV2ProvenanceAndPreservesMetadataTitle() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        let editedAt = Date(timeIntervalSince1970: 1_775_000_123)

        let result = try await fixture.editor.save(
            fixture.request(
                summary: "  Edited summary  ",
                title: "  Edited title  ",
                editedAt: editedAt
            )
        )

        XCTAssertEqual(result.schemaVersion, MeetingIntelligenceArtifact.currentSchemaVersion)
        XCTAssertEqual(result.summary, "Edited summary")
        XCTAssertEqual(result.suggestedTitle, "Edited title")
        XCTAssertEqual(result.sourceTranscriptSHA256, fixture.capturedArtifact.sourceTranscriptSHA256)
        XCTAssertEqual(result.sourceTranscriptByteCount, fixture.capturedArtifact.sourceTranscriptByteCount)
        XCTAssertEqual(result.model, fixture.capturedArtifact.model)
        XCTAssertEqual(result.generatedAt, fixture.capturedArtifact.generatedAt)
        XCTAssertEqual(result.intent, fixture.capturedArtifact.intent)
        XCTAssertEqual(result.contentOrigin, .edited)
        XCTAssertEqual(result.editedAt, editedAt)
        XCTAssertEqual(try fixture.store.load(in: fixture.folder), result)
        try fixture.assertMetadataUnchanged(beforeMetadata)
        XCTAssertTrue(try fixture.stageFiles().isEmpty)
    }

    func testRepeatedEditPreservesOriginalGenerationAndSourceFields() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        let firstEditedAt = Date(timeIntervalSince1970: 1_775_000_100)
        let secondEditedAt = Date(timeIntervalSince1970: 1_775_000_200)

        let first = try await fixture.editor.save(
            fixture.request(summary: "First edit", title: "First title", editedAt: firstEditedAt)
        )
        let second = try await fixture.editor.save(
            fixture.request(
                capturedArtifact: first,
                summary: "Second edit",
                title: "Second title",
                editedAt: secondEditedAt
            )
        )

        XCTAssertEqual(second.summary, "Second edit")
        XCTAssertEqual(second.suggestedTitle, "Second title")
        XCTAssertEqual(second.sourceTranscriptSHA256, fixture.capturedArtifact.sourceTranscriptSHA256)
        XCTAssertEqual(second.sourceTranscriptByteCount, fixture.capturedArtifact.sourceTranscriptByteCount)
        XCTAssertEqual(second.model, fixture.capturedArtifact.model)
        XCTAssertEqual(second.generatedAt, fixture.capturedArtifact.generatedAt)
        XCTAssertEqual(second.intent, fixture.capturedArtifact.intent)
        XCTAssertEqual(second.contentOrigin, .edited)
        XCTAssertEqual(second.editedAt, secondEditedAt)
        XCTAssertNotEqual(first.editedAt, second.editedAt)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testNormalizesSummaryAndTitleWithCanonicalValidator() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()

        let result = try await fixture.editor.save(
            fixture.request(
                summary: " \u{00E9} summary\n\t ",
                title: "  Canonical \u{00E9} title  "
            )
        )

        XCTAssertEqual(result.summary, "\u{00E9} summary")
        XCTAssertEqual(result.suggestedTitle, "Canonical \u{00E9} title")
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testAcceptsExactSummaryByteAndTitleGraphemeBoundaries() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        let summary = String(repeating: "s", count: MeetingIntelligenceArtifactValidator.maximumSummaryBytes)
        let title = String(repeating: "t", count: MeetingIntelligenceArtifactValidator.maximumTitleGraphemes)

        let result = try await fixture.editor.save(fixture.request(summary: summary, title: title))

        XCTAssertEqual(result.summary.utf8.count, MeetingIntelligenceArtifactValidator.maximumSummaryBytes)
        XCTAssertEqual(result.suggestedTitle.count, MeetingIntelligenceArtifactValidator.maximumTitleGraphemes)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testRejectsInvalidSummaryDraftsWithoutWriting() async throws {
        let cases = [
            " \n\t ",
            "unsafe\u{202E}summary",
            String(repeating: "s", count: MeetingIntelligenceArtifactValidator.maximumSummaryBytes + 1)
        ]

        for proposedSummary in cases {
            let fixture = try ArtifactEditorFixture()
            let beforeMetadata = try fixture.metadataBytes()
            let beforeArtifact = try XCTUnwrap(try fixture.store.load(in: fixture.folder))

            await assertError(.invalidSummary) {
                return try await fixture.editor.save(
                    fixture.request(summary: proposedSummary, title: "Valid title")
                )
            }

            XCTAssertEqual(try fixture.store.load(in: fixture.folder), beforeArtifact)
            try fixture.assertMetadataUnchanged(beforeMetadata)
            XCTAssertTrue(try fixture.stageFiles().isEmpty)
            fixture.remove()
        }
    }

    func testRejectsInvalidSuggestedTitleDraftsWithoutWriting() async throws {
        let cases = [
            " \n\t ",
            "2026-08-02",
            "folder/name",
            "unsafe\u{200B}title",
            String(repeating: "t", count: MeetingIntelligenceArtifactValidator.maximumTitleGraphemes + 1)
        ]

        for proposedTitle in cases {
            let fixture = try ArtifactEditorFixture()
            let beforeMetadata = try fixture.metadataBytes()
            let beforeArtifact = try XCTUnwrap(try fixture.store.load(in: fixture.folder))

            await assertError(.invalidSuggestedTitle) {
                return try await fixture.editor.save(
                    fixture.request(summary: "Valid summary", title: proposedTitle)
                )
            }

            XCTAssertEqual(try fixture.store.load(in: fixture.folder), beforeArtifact)
            try fixture.assertMetadataUnchanged(beforeMetadata)
            XCTAssertTrue(try fixture.stageFiles().isEmpty)
            fixture.remove()
        }
    }

    func testRejectsStaleCapturedArtifactAndLeavesNewArtifactVisible() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        let newer = fixture.artifact(
            summary: "Newer generated summary",
            title: "Newer generated title",
            intent: .regenerate,
            generatedAt: Date(timeIntervalSince1970: 1_775_000_300)
        )
        let staged = try fixture.store.stage(newer, in: fixture.folder)
        try fixture.store.promoteStaged(staged, in: fixture.folder)

        await assertError(.conflict) {
            return try await fixture.editor.save(
                fixture.request(summary: "Stale summary", title: "Stale title")
            )
        }

        XCTAssertEqual(try fixture.store.load(in: fixture.folder), newer)
        try fixture.assertMetadataUnchanged(beforeMetadata)
        XCTAssertTrue(try fixture.stageFiles().isEmpty)
    }

    func testRejectsTranscriptDigestRevisionChange() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        fixture.reader.revision = .init(
            sha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            byteCount: fixture.capturedArtifact.sourceTranscriptByteCount
        )

        await assertError(.transcriptChanged) {
            return try await fixture.editor.save(
                fixture.request(summary: "Changed digest", title: "Changed digest title")
            )
        }

        XCTAssertEqual(try fixture.store.load(in: fixture.folder), fixture.capturedArtifact)
        try fixture.assertMetadataUnchanged(beforeMetadata)
        XCTAssertTrue(try fixture.stageFiles().isEmpty)
    }

    func testRejectsTranscriptByteCountChangeEvenWhenDigestDiffers() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        fixture.reader.revision = .init(sha256: fixture.capturedArtifact.sourceTranscriptSHA256, byteCount: 1)

        await assertError(.transcriptChanged) {
            return try await fixture.editor.save(
                fixture.request(summary: "Changed byte count", title: "Changed byte count title")
            )
        }

        XCTAssertEqual(try fixture.store.load(in: fixture.folder), fixture.capturedArtifact)
        try fixture.assertMetadataUnchanged(beforeMetadata)
        XCTAssertTrue(try fixture.stageFiles().isEmpty)
    }

    func testInvalidLeaseBeforeSaveDoesNotStage() async throws {
        let fixture = try ArtifactEditorFixture(useSpyStore: true)
        defer { fixture.remove() }
        let lease = MeetingIntelligenceAttemptLease()
        lease.invalidate()
        let beforeMetadata = try fixture.metadataBytes()

        await assertError(.leaseInvalid) {
            return try await fixture.editor.save(fixture.request(lease: lease))
        }

        XCTAssertEqual(fixture.spyStore?.stageCalls ?? 0, 0)
        XCTAssertEqual(try fixture.store.load(in: fixture.folder), fixture.capturedArtifact)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testLeaseInvalidatedBeforeReservationCleansStageAndPreservesArtifact() async throws {
        let fixture = try ArtifactEditorFixture(useSpyStore: true)
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        fixture.spyStore?.onStage = { fixture.leaseForCurrentRequest?.invalidate() }
        let lease = MeetingIntelligenceAttemptLease()
        fixture.leaseForCurrentRequest = lease

        await assertError(.leaseInvalid) {
            return try await fixture.editor.save(fixture.request(lease: lease))
        }

        XCTAssertEqual(fixture.spyStore?.stageCalls, 1)
        XCTAssertEqual(fixture.spyStore?.promoteCalls, 0)
        XCTAssertEqual(fixture.spyStore?.removeCalls, 1)
        XCTAssertEqual(fixture.spyStore?.visibleArtifact, fixture.capturedArtifact)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testLeaseInvalidatedAfterReservationStillReportsDurableSuccess() async throws {
        let fixture = try ArtifactEditorFixture(useSpyStore: true)
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        let lease = MeetingIntelligenceAttemptLease()
        fixture.spyStore?.onPromote = { lease.invalidate() }

        let result = try await fixture.editor.save(
            fixture.request(summary: "Reserved summary", title: "Reserved title", lease: lease)
        )

        XCTAssertEqual(result.summary, "Reserved summary")
        XCTAssertEqual(fixture.spyStore?.promoteCalls, 1)
        XCTAssertEqual(fixture.spyStore?.removeCalls, 0)
        XCTAssertEqual(fixture.spyStore?.visibleArtifact, result)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testFolderReplacementBeforeCommitIsUnsafeAndCannotRemoveReplacementStage() async throws {
        let fixture = try ArtifactEditorFixture(useSpyStore: true)
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        fixture.spyStore?.onStage = {
            do {
                try FileManager.default.moveItem(at: fixture.folder, to: fixture.movedFolder)
                try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: fixture.movedFolder.appendingPathComponent(".meeting-intelligence-stage-test"),
                    to: fixture.folder.appendingPathComponent(".meeting-intelligence-stage-test")
                )
            } catch {
                XCTFail("Could not replace test folder")
            }
        }

        await assertError(.unsafeSessionFolder) {
            return try await fixture.editor.save(
                fixture.request(summary: "Folder replacement", title: "Folder replacement title")
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.folder.appendingPathComponent(".meeting-intelligence-stage-test").path
        ))
        XCTAssertEqual(
            try Data(contentsOf: fixture.movedFolder.appendingPathComponent(RecordingSessionMetadataStore.fileName)),
            beforeMetadata
        )
        XCTAssertEqual(fixture.spyStore?.removeCalls, 0)
    }

    func testSymlinkAliasIsRejectedBeforeStaging() async throws {
        let fixture = try ArtifactEditorFixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("session-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.folder)
        let session = fixture.session.replacing(folderURL: alias)
        let beforeMetadata = try fixture.metadataBytes()
        let request = fixture.request(session: session)

        await assertError(.unsafeSessionFolder) {
            return try await fixture.editor.save(request)
        }

        XCTAssertTrue(try fixture.stageFiles().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.metadataURL), beforeMetadata)
        XCTAssertEqual(try fixture.store.load(in: fixture.folder), fixture.capturedArtifact)
    }

    func testRemovedSessionCannotRecreateArtifact() async throws {
        let fixture = try ArtifactEditorFixture()
        let moved = fixture.root.appendingPathComponent("removed-session", isDirectory: true)
        let beforeArtifact = try Data(contentsOf: fixture.artifactURL)
        try FileManager.default.moveItem(at: fixture.folder, to: moved)
        defer { fixture.remove() }

        await assertError(.unsafeSessionFolder) {
            return try await fixture.editor.save(fixture.request(summary: "Removed", title: "Removed title"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(MeetingIntelligenceArtifactStore.fileName)), beforeArtifact)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent(".meeting-intelligence-stage-test").path
        ))
    }

    func testTrashedSessionCannotRecreateArtifact() async throws {
        let fixture = try ArtifactEditorFixture()
        let trash = fixture.root.appendingPathComponent("Trash", isDirectory: true)
        let trashed = trash.appendingPathComponent("meeting-test", isDirectory: true)
        let beforeArtifact = try Data(contentsOf: fixture.artifactURL)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.folder, to: trashed)
        defer { fixture.remove() }

        await assertError(.unsafeSessionFolder) {
            return try await fixture.editor.save(fixture.request(summary: "Trashed", title: "Trashed title"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertEqual(
            try Data(contentsOf: trashed.appendingPathComponent(MeetingIntelligenceArtifactStore.fileName)),
            beforeArtifact
        )
    }

    func testStagingFailureMapsToRedactedStorageFailure() async throws {
        let fixture = try ArtifactEditorFixture(useSpyStore: true)
        defer { fixture.remove() }
        fixture.spyStore?.stageError = EditorStorageTestError.failed
        let beforeMetadata = try fixture.metadataBytes()

        await assertError(.storageFailure) {
            return try await fixture.editor.save(
                fixture.request(summary: "Stage failure", title: "Stage failure title")
            )
        }

        XCTAssertEqual(fixture.spyStore?.stageCalls, 1)
        XCTAssertEqual(fixture.spyStore?.promoteCalls, 0)
        XCTAssertEqual(fixture.spyStore?.removeCalls, 0)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testPromotionFailurePreservesOldArtifactAndCleansStage() async throws {
        let fixture = try ArtifactEditorFixture(useSpyStore: true)
        defer { fixture.remove() }
        fixture.spyStore?.promoteError = EditorStorageTestError.failed
        let beforeMetadata = try fixture.metadataBytes()

        await assertError(.storageFailure) {
            return try await fixture.editor.save(
                fixture.request(summary: "Promotion failure", title: "Promotion failure title")
            )
        }

        XCTAssertEqual(fixture.spyStore?.promoteCalls, 1)
        XCTAssertEqual(fixture.spyStore?.removeCalls, 1)
        XCTAssertEqual(fixture.spyStore?.visibleArtifact, fixture.capturedArtifact)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testVisibleArtifactIsAlwaysOldOrNewAndNeverMetadataTitle() async throws {
        let fixture = try ArtifactEditorFixture(useSpyStore: true)
        defer { fixture.remove() }
        let beforeMetadata = try fixture.metadataBytes()
        let old = fixture.capturedArtifact
        let new = try await fixture.editor.save(
            fixture.request(summary: "Atomic new summary", title: "Atomic new title")
        )

        XCTAssertTrue(fixture.spyStore?.observedArtifacts.allSatisfy { $0 == old || $0 == new } == true)
        XCTAssertEqual(fixture.spyStore?.visibleArtifact, new)
        try fixture.assertMetadataUnchanged(beforeMetadata)
    }

    func testAllPublicErrorsAreTypedAndRedacted() {
        let sensitive = [
            "/private/secret/session",
            "Transcript private body",
            "provider-response-body",
            "api-key-value"
        ]
        let errors: [MeetingIntelligenceArtifactEditError] = [
            .invalidSummary,
            .invalidSuggestedTitle,
            .conflict,
            .transcriptChanged,
            .leaseInvalid,
            .unsafeSessionFolder,
            .storageFailure
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            let description = error.localizedDescription
            for value in sensitive {
                XCTAssertFalse(description.contains(value))
            }
            XCTAssertEqual(error, error)
        }
    }

    private func assertError(
        _ expected: MeetingIntelligenceArtifactEditError,
        operation: () async throws -> MeetingIntelligenceArtifact
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected editor failure")
        } catch {
            XCTAssertEqual(error as? MeetingIntelligenceArtifactEditError, expected)
            XCTAssertFalse(String(describing: error).contains("/private/secret"))
        }
    }
}

private final class ArtifactEditorFixture: @unchecked Sendable {
    let root: URL
    let folder: URL
    let movedFolder: URL
    let transcriptURL: URL
    let artifactURL: URL
    let metadataURL: URL
    let session: RecordingSession
    let capturedArtifact: MeetingIntelligenceArtifact
    let reader: EditorTranscriptReader
    let gate: RecordingSessionMutationGate
    let store: MeetingIntelligenceArtifactStore
    let editor: any MeetingIntelligenceArtifactEditing
    var spyStore: EditorArtifactStore? = nil
    var leaseForCurrentRequest: MeetingIntelligenceAttemptLease?

    init(useSpyStore: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-intelligence-editor-\(UUID().uuidString)", isDirectory: true
        )
        folder = root.appendingPathComponent("meeting-test", isDirectory: true)
        movedFolder = root.appendingPathComponent("moved-session", isDirectory: true)
        transcriptURL = folder.appendingPathComponent("transcript.txt")
        artifactURL = folder.appendingPathComponent(MeetingIntelligenceArtifactStore.fileName)
        metadataURL = folder.appendingPathComponent(RecordingSessionMetadataStore.fileName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transcript = Data("canonical transcript bytes".utf8)
        try transcript.write(to: transcriptURL)
        let digest = SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()
        let revision = TranscriptDocumentRevision(sha256: "sha256:\(digest)", byteCount: transcript.count)
        reader = EditorTranscriptReader(revision: revision, data: transcript)
        gate = RecordingSessionMutationGate()
        store = MeetingIntelligenceArtifactStore(mutationGate: gate)
        capturedArtifact = .init(
            schemaVersion: MeetingIntelligenceArtifact.currentSchemaVersion,
            summary: "Generated summary",
            suggestedTitle: "Generated title",
            sourceTranscriptSHA256: revision.sha256,
            sourceTranscriptByteCount: revision.byteCount,
            model: "meeting-model",
            generatedAt: Date(timeIntervalSince1970: 1_775_000_000),
            intent: .regenerate,
            contentOrigin: .generated,
            editedAt: nil
        )
        let metadata = RecordingSessionMetadata(
            title: "Manual recording title",
            titleOrigin: .manual,
            tags: ["keep"],
            isFavorite: true,
            meetingType: "planning"
        )
        try RecordingSessionMetadataStore.save(metadata, in: folder)
        session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 60,
            fileSize: 123,
            metadata: metadata
        )
        let initialStage = try store.stage(capturedArtifact, in: folder)
        try store.promoteStaged(initialStage, in: folder)

        if useSpyStore {
            let spy = EditorArtifactStore(folder: folder, visibleArtifact: capturedArtifact)
            spyStore = spy
            editor = MeetingIntelligenceArtifactEditor(
                mutationGate: gate,
                transcriptReader: reader,
                artifactStore: spy
            )
        } else {
            editor = MeetingIntelligenceArtifactEditor(
                mutationGate: gate,
                transcriptReader: reader,
                artifactStore: store
            )
        }
    }

    func artifact(
        summary: String,
        title: String,
        intent: MeetingIntelligenceIntent,
        generatedAt: Date
    ) -> MeetingIntelligenceArtifact {
        .init(
            schemaVersion: MeetingIntelligenceArtifact.currentSchemaVersion,
            summary: summary,
            suggestedTitle: title,
            sourceTranscriptSHA256: capturedArtifact.sourceTranscriptSHA256,
            sourceTranscriptByteCount: capturedArtifact.sourceTranscriptByteCount,
            model: capturedArtifact.model,
            generatedAt: generatedAt,
            intent: intent,
            contentOrigin: .generated,
            editedAt: nil
        )
    }

    func request(
        session: RecordingSession? = nil,
        capturedArtifact: MeetingIntelligenceArtifact? = nil,
        summary: String = "Edited summary",
        title: String = "Edited title",
        editedAt: Date = Date(timeIntervalSince1970: 1_775_000_001),
        lease: MeetingIntelligenceAttemptLease? = nil
    ) -> MeetingIntelligenceArtifactEditRequest {
        .init(
            session: session ?? self.session,
            capturedArtifact: capturedArtifact ?? self.capturedArtifact,
            proposedSummary: summary,
            proposedSuggestedTitle: title,
            editedAt: editedAt,
            lease: lease ?? MeetingIntelligenceAttemptLease()
        )
    }

    func metadataBytes() throws -> Data { try Data(contentsOf: metadataURL) }

    func assertMetadataUnchanged(_ original: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try metadataBytes(), original, file: file, line: line)
        XCTAssertEqual(
            RecordingSessionMetadataStore.load(in: folder).title,
            "Manual recording title",
            file: file,
            line: line
        )
        XCTAssertEqual(session.displayName, "Manual recording title", file: file, line: line)
    }

    func stageFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".meeting-intelligence-stage-") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class EditorTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    var revision: TranscriptDocumentRevision
    let data: Data

    init(revision: TranscriptDocumentRevision, data: Data) {
        self.revision = revision
        self.data = data
    }

    func readCanonical(in folder: URL, allowLegacy: Bool) throws -> TranscriptDocumentSnapshot {
        .init(url: folder.appendingPathComponent("transcript.txt"), data: data, revision: revision)
    }
}

private enum EditorStorageTestError: Error { case failed }

private final class EditorArtifactStore: MeetingIntelligenceArtifactSecureStoring, @unchecked Sendable {
    let folder: URL
    var visibleArtifact: MeetingIntelligenceArtifact?
    var stagedArtifact: MeetingIntelligenceArtifact?
    var stageError: Error?
    var promoteError: Error?
    var onStage: (() -> Void)?
    var onPromote: (() -> Void)?
    private(set) var stageCalls = 0
    private(set) var promoteCalls = 0
    private(set) var removeCalls = 0
    private(set) var observedArtifacts: [MeetingIntelligenceArtifact?] = []

    init(folder: URL, visibleArtifact: MeetingIntelligenceArtifact) {
        self.folder = folder
        self.visibleArtifact = visibleArtifact
    }

    func load(in _: URL) throws -> MeetingIntelligenceArtifact? {
        visibleArtifact
    }

    func stage(
        _ artifact: MeetingIntelligenceArtifact,
        in folder: URL,
        expectedDirectory: MeetingIntelligenceStoreDirectoryIdentity
    ) throws -> URL {
        stageCalls += 1
        guard try MeetingIntelligenceStoreFileIO.folderIdentity(in: folder) == expectedDirectory else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        if let stageError { throw stageError }
        stagedArtifact = artifact
        try Data("staged artifact".utf8).write(
            to: folder.appendingPathComponent(".meeting-intelligence-stage-test")
        )
        onStage?()
        onStage = nil
        return folder.appendingPathComponent(".meeting-intelligence-stage-test")
    }

    func stage(_: MeetingIntelligenceArtifact, in _: URL) throws -> URL {
        XCTFail("Editor must use secure artifact staging")
        throw EditorStorageTestError.failed
    }

    func promoteStaged(_: URL, in _: URL) throws {
        promoteCalls += 1
        observedArtifacts.append(visibleArtifact)
        if let promoteError { throw promoteError }
        visibleArtifact = stagedArtifact
        stagedArtifact = nil
        observedArtifacts.append(visibleArtifact)
        onPromote?()
        onPromote = nil
    }

    func removeStaged(_: URL, in _: URL) throws {
        removeCalls += 1
        stagedArtifact = nil
    }
}

private extension RecordingSession {
    func replacing(folderURL: URL) -> RecordingSession {
        .init(
            id: id,
            folderURL: folderURL,
            recordingURL: recordingURL,
            createdAt: createdAt,
            duration: duration,
            fileSize: fileSize,
            metadata: metadata,
            searchDocument: searchDocument
        )
    }
}
