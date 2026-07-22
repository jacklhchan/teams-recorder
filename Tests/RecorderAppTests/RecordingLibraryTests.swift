import Foundation
import XCTest
@testable import RecorderApp

final class RecordingLibraryTests: XCTestCase {
    func testMetadataIsPersistedAndLoadedWithSession() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")

        try RecordingSessionMetadataStore.save(
            .init(title: "Weekly sync", tags: ["sales", "internal"], isFavorite: true),
            in: folder
        )

        let loaded = try XCTUnwrap(RecordingSessionStore.load(from: root).first)
        XCTAssertEqual(loaded.displayName, "Weekly sync")
        XCTAssertEqual(loaded.tags, ["sales", "internal"])
        XCTAssertTrue(loaded.isFavorite)
    }

    func testTranscriptDocumentImportsQwenTranscriptAndPersistsEdits() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")
        let qwenTranscript = folder.appendingPathComponent("transcript_qwen3_asr_1_7b_8bit_yue_trad.txt")
        try "first version".write(to: qwenTranscript, atomically: true, encoding: .utf8)

        XCTAssertEqual(try TranscriptDocumentStore.read(in: folder), "first version")

        try TranscriptDocumentStore.save("edited version", in: folder)
        XCTAssertEqual(try TranscriptDocumentStore.read(in: folder), "edited version")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8), "edited version")
    }

    func testTranscriptionStateCanBeCancelledAndSurvivesReload() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")
        let started = Date(timeIntervalSince1970: 1_784_700_000)

        try TranscriptionStateStore.save(.init(phase: .uploading, message: "Uploading audio", startedAt: started), in: folder)
        XCTAssertEqual(try TranscriptionStateStore.load(in: folder)?.phase, .uploading)

        try TranscriptionStateStore.markCancelled(in: folder, at: started.addingTimeInterval(4))
        let state = try XCTUnwrap(TranscriptionStateStore.load(in: folder))
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(state.finishedAt, started.addingTimeInterval(4))
    }

    func testMoveToTrashMovesOnlyTheSelectedSession() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")

        let didMove = try RecordingSessionStore.moveToTrash(folder: folder)

        XCTAssertTrue(didMove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSessionFolder(in root: URL, named name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: folder.appendingPathComponent("recording.wav"))
        return folder
    }
}
