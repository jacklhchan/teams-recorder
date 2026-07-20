import Foundation
import XCTest
@testable import RecorderApp

final class ManualTranscriptionImporterTests: XCTestCase {
    func testImportedAudioFileAppearsAsManualRecordingSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-import-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
}
