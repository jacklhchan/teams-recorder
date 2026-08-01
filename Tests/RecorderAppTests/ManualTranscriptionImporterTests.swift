import Foundation
import XCTest
@testable import RecorderApp

final class ManualTranscriptionImporterTests: XCTestCase {
    func testImportedAudioFileAppearsAsManualRecordingSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-import-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)

        let imported = try ManualTranscriptionImporter.importAudioFile(
            source,
            into: root,
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )

        XCTAssertTrue(imported.folderURL.lastPathComponent.hasPrefix("manual-"))
        XCTAssertEqual(imported.recordingURL.lastPathComponent, "recording.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.recordingURL.path))

        let sessions = RecordingSessionStore.load(from: root)
        let importedFolderPath = imported.folderURL.standardizedFileURL.path
        let importedRecordingPath = imported.recordingURL.standardizedFileURL.path
        XCTAssertTrue(sessions.contains {
            $0.folderURL.standardizedFileURL.path == importedFolderPath
                && $0.recordingURL.standardizedFileURL.path == importedRecordingPath
        })
    }

    func testImportsInSameSecondUseDistinctOwnedSessionFoldersWithoutOverwritingExistingFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let existingFolder = root.appendingPathComponent("manual-2026-05-18-154000", isDirectory: true)
        let existingRecording = existingFolder.appendingPathComponent("recording.wav")
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: existingRecording)

        let first = try ManualTranscriptionImporter.importAudioFile(source, into: root, now: now)
        let second = try ManualTranscriptionImporter.importAudioFile(source, into: root, now: now)

        XCTAssertNotEqual(first.folderURL.standardizedFileURL, second.folderURL.standardizedFileURL)
        XCTAssertNotEqual(first.folderURL.standardizedFileURL, existingFolder.standardizedFileURL)
        XCTAssertNotEqual(second.folderURL.standardizedFileURL, existingFolder.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: existingRecording), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: first.recordingURL), Data([0x52, 0x49, 0x46, 0x46]))
        XCTAssertEqual(try Data(contentsOf: second.recordingURL), Data([0x52, 0x49, 0x46, 0x46]))
    }

    func testImportedAudioUsesSourceStemForVisibleAndSearchNameWhileKeepingOwnedFoldersUnique() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quarterly Review 2026.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        let first = try ManualTranscriptionImporter.importAudioFile(source, into: root, now: now)
        let second = try ManualTranscriptionImporter.importAudioFile(source, into: root, now: now)

        XCTAssertNotEqual(first.folderURL.standardizedFileURL, second.folderURL.standardizedFileURL)
        XCTAssertEqual(first.displayName, "Quarterly Review 2026")
        XCTAssertEqual(second.displayName, "Quarterly Review 2026")
        XCTAssertFalse(first.displayName.contains("manual-"))
        XCTAssertFalse(second.displayName.contains("manual-"))
        XCTAssertTrue(first.searchDocument.metadataText.contains("Quarterly Review 2026"))
        XCTAssertFalse(first.searchDocument.metadataText.contains(first.folderURL.lastPathComponent))
    }

    func testImportedAudioKeepsUnsetTitleOriginForMeetingIntelligence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Customer Discovery.m4a")
        try Data([0x00]).write(to: source)

        let imported = try ManualTranscriptionImporter.importAudioFile(source, into: root)

        XCTAssertEqual(imported.metadata.source, .imported)
        XCTAssertEqual(imported.metadata.title, "Customer Discovery")
        XCTAssertEqual(imported.metadata.titleOrigin, .unset)
        XCTAssertFalse(imported.metadata.titleOrigin == .manual)
    }

    func testLegacyImportedSessionWithoutTitleUsesSafeSharedDisplayAndSearchFallback() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(
            "manual-2026-05-29-042640-D2D97D65-2939-4637-A54E-19047B52E491",
            isDirectory: true
        )
        let recordingURL = folder.appendingPathComponent("recording.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: recordingURL)
        try RecordingSessionMetadataStore.save(
            .init(source: .imported),
            in: folder
        )

        let imported = RecordingSessionStore.session(
            for: folder,
            recordingURL: recordingURL
        )

        XCTAssertEqual(imported.displayName, "Imported recording")
        XCTAssertTrue(imported.searchDocument.metadataText.contains("Imported recording"))
        XCTAssertFalse(imported.displayName.contains("manual-"))
        XCTAssertFalse(imported.searchDocument.metadataText.contains(folder.lastPathComponent))
        XCTAssertEqual(imported.metadata.titleOrigin, .unset)
    }

    func testExistingExactDestinationIsRejectedBeforeCopyOrMetadataAndPreservesMarker() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data([0x52]).write(to: source)
        let existingFolder = root.appendingPathComponent("manual-existing", isDirectory: true)
        let marker = existingFolder.appendingPathComponent("marker.txt")
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        try Data("preserve me".utf8).write(to: marker)
        var copyCalled = false
        var saveMetadataCalled = false
        let operations = ManualTranscriptionImporter.ImportOperations(
            makeFolderName: { _ in "manual-existing" },
            copyItem: { _, _ in copyCalled = true },
            saveMetadata: { _, _ in saveMetadataCalled = true }
        )

        XCTAssertThrowsError(
            try ManualTranscriptionImporter.importAudioFile(
                source,
                into: root,
                now: .distantPast,
                operations: operations
            )
        )
        XCTAssertFalse(copyCalled)
        XCTAssertFalse(saveMetadataCalled)
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve me".utf8))
    }

    func testCopyFailureRollsBackOnlyNewFolderAndPreservesPreexistingDirectChild() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data([0x52]).write(to: source)
        let existingFolder = root.appendingPathComponent("manual-existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true)

        let operations = ManualTranscriptionImporter.ImportOperations(
            makeFolderName: { _ in "manual-new-copy-failure" },
            copyItem: { _, _ in throw CocoaError(.fileWriteUnknown) },
            saveMetadata: { _, _ in XCTFail("Metadata save must not run after copy failure") }
        )

        XCTAssertThrowsError(
            try ManualTranscriptionImporter.importAudioFile(
                source,
                into: root,
                now: .distantPast,
                operations: operations
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("manual-new-copy-failure", isDirectory: true).path
        ))
    }

    func testMetadataFailureRollsBackOnlyNewFolderAndPreservesPreexistingDirectChild() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try Data([0x52]).write(to: source)
        let existingFolder = root.appendingPathComponent("manual-existing", isDirectory: true)
        let existingMarker = existingFolder.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existingMarker)

        let operations = ManualTranscriptionImporter.ImportOperations(
            makeFolderName: { _ in "manual-new-metadata-failure" },
            copyItem: { source, destination in try FileManager.default.copyItem(at: source, to: destination) },
            saveMetadata: { _, _ in throw CocoaError(.fileWriteUnknown) }
        )

        XCTAssertThrowsError(
            try ManualTranscriptionImporter.importAudioFile(
                source,
                into: root,
                now: .distantPast,
                operations: operations
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingFolder.path))
        XCTAssertEqual(try Data(contentsOf: existingMarker), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("manual-new-metadata-failure", isDirectory: true).path
        ))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
