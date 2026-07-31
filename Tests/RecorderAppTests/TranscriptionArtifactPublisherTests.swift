import Foundation
import XCTest
@testable import RecorderApp

final class TranscriptionArtifactPublisherTests: XCTestCase {
    func testPublicationIsCanonicalSanitizedAndRetainsThreeBackups() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let publisher = TranscriptionArtifactPublisher(
            maximumBackupsPerArtifact: 3
        )

        var artifacts: PublishedTranscriptionArtifacts?
        for index in 0..<5 {
            artifacts = try publisher.publish(
                rawText: "raw-\(index)",
                finalText: "final-\(index)",
                manifest: .init(
                    model: "asr-model",
                    language: "yue",
                    chunkCount: 2,
                    responseFormats: ["verbose_json", "json"]
                ),
                logLines: [
                    "Started",
                    "Completed 2 chunks"
                ],
                sessionFolder: folder,
                now: Date(timeIntervalSince1970: Double(index))
            )
        }

        XCTAssertEqual(
            try String(
                contentsOf: folder.appendingPathComponent("transcript.txt"),
                encoding: .utf8
            ),
            "final-4"
        )
        let names = try FileManager.default.contentsOfDirectory(
            atPath: folder.path
        )
        for canonical in [
            "transcript.txt",
            "transcript.raw.txt",
            "transcription.json",
            "transcription.log"
        ] {
            XCTAssertLessThanOrEqual(
                names.filter {
                    $0.hasPrefix("\(canonical).previous-")
                }.count,
                3
            )
        }
        XCTAssertFalse(
            names.contains {
                $0.hasPrefix(".transcription-publish-")
            }
        )
        let manifest = try String(
            contentsOf: folder.appendingPathComponent("transcription.json"),
            encoding: .utf8
        )
        XCTAssertFalse(manifest.contains("apiKey"))
        XCTAssertFalse(manifest.contains("baseURL"))
        XCTAssertEqual(
            artifacts?.committedTranscriptRevision.byteCount,
            Data("final-4".utf8).count
        )
    }

    func testExpiredLegacyRunsAreRemovedButRecentRunRemains() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runs = folder.appendingPathComponent(
            ".transcription-runs",
            isDirectory: true
        )
        let old = runs.appendingPathComponent("old", isDirectory: true)
        let recent = runs.appendingPathComponent(
            "recent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: old,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recent,
            withIntermediateDirectories: true
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86_400)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-6 * 86_400)],
            ofItemAtPath: recent.path
        )

        try TranscriptionArtifactPublisher().expireLegacyRuns(
            in: folder,
            olderThan: 7 * 86_400,
            now: now
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: old.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recent.path)
        )
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "transcription-publisher-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder
    }
}
