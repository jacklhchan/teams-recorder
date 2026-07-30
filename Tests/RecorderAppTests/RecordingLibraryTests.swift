import Foundation
import XCTest
@testable import RecorderApp

final class RecordingLibraryTests: XCTestCase {
    func testLegacyMetadataDefaultsToCurrentSchemaVersionAndManualSource() throws {
        let metadata = try JSONDecoder().decode(
            RecordingSessionMetadata.self,
            from: Data(#"{"title":"Legacy"}"#.utf8)
        )

        XCTAssertEqual(
            metadata.schemaVersion,
            RecordingSessionMetadata.currentSchemaVersion
        )
        XCTAssertEqual(metadata.source, .manual)
        XCTAssertEqual(metadata.participants, [])
        XCTAssertNil(metadata.meetingType)
    }

    func testUnknownCrossPlatformFieldsSurviveLoadEditAndSave() throws {
        let root = try makeRoot()
        let folder = try makeEmptySessionFolder(
            in: root,
            named: "meeting-contract"
        )
        try Data(
            #"""
            {
              "schemaVersion": 1,
              "title": "Old",
              "windowsCapture": {
                "device": "default",
                "exclusive": false,
                "routes": [
                  {
                    "kind": "communications",
                    "channels": [1, 2, {"label": "mixed"}]
                  },
                  ["fallback", true, null]
                ]
              }
            }
            """#.utf8
        ).write(to: RecordingSessionMetadataStore.fileURL(in: folder))

        var metadata = RecordingSessionMetadataStore.load(in: folder)
        metadata.title = "Edited"
        try RecordingSessionMetadataStore.save(metadata, in: folder)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: RecordingSessionMetadataStore.fileURL(
                        in: folder
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["title"] as? String, "Edited")
        XCTAssertEqual(
            (object["windowsCapture"] as? [String: Any])?["device"]
                as? String,
            "default"
        )
        let routes = try XCTUnwrap(
            (object["windowsCapture"] as? [String: Any])?["routes"]
                as? [Any]
        )
        let primary = try XCTUnwrap(routes.first as? [String: Any])
        let channels = try XCTUnwrap(primary["channels"] as? [Any])
        XCTAssertEqual(channels[0] as? Int, 1)
        XCTAssertEqual(
            (channels[2] as? [String: Any])?["label"] as? String,
            "mixed"
        )
        let fallback = try XCTUnwrap(routes.last as? [Any])
        XCTAssertEqual(fallback[0] as? String, "fallback")
        XCTAssertEqual(fallback[1] as? Bool, true)
        XCTAssertTrue(fallback[2] is NSNull)
    }

    func testMetadataEncodingIncludesVersionedSearchFields() throws {
        let metadata = RecordingSessionMetadata(
            source: .teamsAutomatic,
            meetingType: "Technical Workshop",
            participants: ["Alex Chan", " Sam Lee "]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(metadata)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            object["schemaVersion"] as? Int,
            RecordingSessionMetadata.currentSchemaVersion
        )
        XCTAssertEqual(object["source"] as? String, "teamsAutomatic")
        XCTAssertEqual(object["meetingType"] as? String, "Technical Workshop")
        XCTAssertEqual(
            object["participants"] as? [String],
            ["Alex Chan", "Sam Lee"]
        )
    }

    func testLegacyMetadataAndIndependentlyMalformedNewFieldsKeepValidLegacyFields() throws {
        let legacy = """
        {"title":" Weekly sync ","tags":["sales"],"isFavorite":true,
         "mediaKind":17,"screenIntervals":"bad","capturedTeamsWindow":42,"recoveryState":false}
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(RecordingSessionMetadata.self, from: legacy)

        XCTAssertEqual(metadata.title, "Weekly sync")
        XCTAssertEqual(metadata.tags, ["sales"])
        XCTAssertTrue(metadata.isFavorite)
        XCTAssertEqual(metadata.mediaKind, .audio)
        XCTAssertEqual(metadata.screenIntervals, [])
        XCTAssertNil(metadata.capturedTeamsWindow)
        XCTAssertEqual(metadata.recoveryState, .none)
    }

    func testMetadataEncodingWritesAllScreenAndRecoveryFields() throws {
        let metadata = RecordingSessionMetadata(
            title: "Call",
            tags: ["team"],
            isFavorite: true,
            mediaKind: .video,
            screenIntervals: [.init(startSeconds: 1, endSeconds: 2)],
            capturedTeamsWindow: .init(processID: 8, windowID: 9, title: "Teams"),
            recoveryState: .recoveredAfterInterruption
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])

        XCTAssertEqual(object["mediaKind"] as? String, "video")
        XCTAssertNotNil(object["screenIntervals"])
        XCTAssertNotNil(object["capturedTeamsWindow"])
        XCTAssertEqual(object["recoveryState"] as? String, "recoveredAfterInterruption")
    }

    func testExactRegularFilePrecedenceAndMediaProjection() throws {
        let root = try makeRoot()
        let folder = try makeEmptySessionFolder(in: root, named: "meeting-2026-07-22-090000")
        try Data([1]).write(to: folder.appendingPathComponent("recording.m4a"))
        try Data([2]).write(to: folder.appendingPathComponent("recording.mp4"))
        try Data([3]).write(to: folder.appendingPathComponent("recording.wav"))
        try RecordingSessionMetadataStore.save(
            .init(
                mediaKind: .video,
                capturedTeamsWindow: .init(processID: 1, windowID: 2, title: "Stale Teams")
            ),
            in: folder
        )

        var session = try XCTUnwrap(RecordingSessionStore.load(from: root).first)
        XCTAssertEqual(session.recordingURL.lastPathComponent, "recording.mp4")
        XCTAssertEqual(session.mediaKind, .audio)
        XCTAssertNil(session.capturedTeamsWindow)

        try RecordingSessionMetadataStore.save(
            .init(screenIntervals: [.init(startSeconds: 0, endSeconds: 1)]), in: folder
        )
        session = try XCTUnwrap(RecordingSessionStore.load(from: root).first)
        XCTAssertEqual(session.mediaKind, .video)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("recording.mp4"))
        try RecordingSessionMetadataStore.save(
            .init(
                mediaKind: .video,
                screenIntervals: [.init(startSeconds: 0, endSeconds: 1)],
                capturedTeamsWindow: .init(processID: 7, windowID: 8, title: "Teams")
            ),
            in: folder
        )
        session = try XCTUnwrap(RecordingSessionStore.load(from: root).first)
        XCTAssertEqual(session.recordingURL.lastPathComponent, "recording.m4a")
        XCTAssertEqual(session.mediaKind, .audio)
        XCTAssertEqual(session.screenIntervals, [])
        XCTAssertNil(session.capturedTeamsWindow)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("recording.m4a"))
        session = try XCTUnwrap(RecordingSessionStore.load(from: root).first)
        XCTAssertEqual(session.recordingURL.lastPathComponent, "recording.wav")
        XCTAssertEqual(session.mediaKind, .audio)
        XCTAssertEqual(session.screenIntervals, [])
        XCTAssertNil(session.capturedTeamsWindow)
    }

    func testIgnoresPartialBackupLookalikeWrongCaseDirectoriesAndSymlinks() throws {
        let root = try makeRoot()
        let folder = try makeEmptySessionFolder(in: root, named: "meeting-2026-07-22-090000")
        let regular = folder.appendingPathComponent("recording.wav")
        try Data([1]).write(to: regular)
        try Data([2]).write(to: folder.appendingPathComponent("recording.partial.mp4"))
        try Data([3]).write(to: folder.appendingPathComponent("recording.audio-backup.m4a"))
        try Data([4]).write(to: folder.appendingPathComponent("recording.MP4"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("recording.m4a"), withDestinationURL: regular)

        let session = try XCTUnwrap(RecordingSessionStore.load(from: root).first)
        XCTAssertEqual(session.recordingURL.lastPathComponent, "recording.wav")

        let directoryFolder = try makeEmptySessionFolder(in: root, named: "meeting-directory")
        try Data([5]).write(to: directoryFolder.appendingPathComponent("recording.wav"))
        try FileManager.default.createDirectory(at: directoryFolder.appendingPathComponent("recording.mp4"), withIntermediateDirectories: true)
        let directorySession = try XCTUnwrap(RecordingSessionStore.load(from: root).first {
            $0.folderURL.standardizedFileURL.path == directoryFolder.standardizedFileURL.path
        })
        XCTAssertEqual(directorySession.recordingURL.lastPathComponent, "recording.wav")
    }
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

    func testCanonicalTranscriptWinsOverLegacyFile() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")
        try "canonical".write(
            to: folder.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "legacy".write(
            to: folder.appendingPathComponent("transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(try TranscriptDocumentStore.read(in: folder), "canonical")
    }

    func testLegacyProviderSpecificTranscriptRemainsReadable() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")
        let legacy = folder.appendingPathComponent("transcript_qwen3_asr_1_7b_8bit_yue_trad.txt")
        try "legacy".write(to: legacy, atomically: true, encoding: .utf8)

        XCTAssertEqual(TranscriptDocumentStore.resolvedURL(in: folder), legacy)
    }

    func testCanonicalLogWinsAndLegacyLogFallsBack() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")
        let legacy = folder.appendingPathComponent("transcription_qwen_asr.log")
        try Data().write(to: legacy)
        XCTAssertEqual(TranscriptDocumentStore.logURL(in: folder), legacy)

        let canonical = folder.appendingPathComponent("transcription.log")
        try Data().write(to: canonical)
        XCTAssertEqual(TranscriptDocumentStore.logURL(in: folder), canonical)
    }

    func testTranscriptAndLogResolutionIgnoreCanonicalAndLegacyDirectories() throws {
        let root = try makeRoot()
        let folder = try makeSessionFolder(in: root, named: "meeting-2026-07-22-090000")
        let names = [
            "transcript.txt",
            "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt",
            "transcription.log",
            "transcription_qwen_asr.log"
        ]
        for name in names {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        XCTAssertNil(TranscriptDocumentStore.resolvedURL(in: folder))
        XCTAssertNil(TranscriptDocumentStore.logURL(in: folder))
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
        let folder = try makeEmptySessionFolder(in: root, named: name)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: folder.appendingPathComponent("recording.wav"))
        return folder
    }

    private func makeEmptySessionFolder(in root: URL, named name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
