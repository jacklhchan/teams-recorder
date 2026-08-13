import CryptoKit
import Foundation
import XCTest
@testable import RecorderApp

final class TranscriptionArtifactPublisherTests: XCTestCase {
    func testDisabledDiagnosticRedactionPersistsNoDiagnosticContent() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let publisher = TranscriptionArtifactPublisher(
            lifecyclePolicy: .init(redactGeneratedDiagnostics: false)
        )

        let artifacts = try publisher.publish(
            rawText: "raw", finalText: "final",
            manifest: .init(model: "model", language: "yue", chunkCount: 1, responseFormats: []),
            logEvents: [.started], sessionFolder: folder
        )
        _ = try publisher.publishFailureDiagnostic(
            .init(stage: .upload, errorCode: .providerTransportFailure),
            sessionFolder: folder
        )

        XCTAssertTrue(try Data(contentsOf: artifacts.logURL).isEmpty)
        XCTAssertTrue(try Data(contentsOf: folder.appendingPathComponent("transcription.failure.json")).isEmpty)
    }

    func testModeMutationFailurePreservesArtifactAndReportsFixedCapability() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var capabilities: [OwnerOnlyArtifactCapability] = []
        let publisher = TranscriptionArtifactPublisher(
            modeMutation: { _, _ in -1 },
            onOwnerOnlyCapability: { capabilities.append($0) }
        )

        let diagnostic = try publisher.publishFailureDiagnostic(
            .init(stage: .upload, errorCode: .providerTransportFailure),
            sessionFolder: folder
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostic.path))
        XCTAssertEqual(capabilities, [.ownerOnlyUnavailable])
    }
    func testPublicationLogContainsOnlyFixedSafeDiagnostic() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events: [TranscriptionLogEvent] = [
            .started,
            .preparedChunks(Int.max),
            .completedChunk(current: Int.min, total: Int.max),
            .completed
        ]

        let artifacts = try TranscriptionArtifactPublisher().publish(
            rawText: "raw",
            finalText: "final",
            manifest: .init(
                model: "asr-model",
                language: "yue",
                chunkCount: 1,
                responseFormats: ["json"]
            ),
            logEvents: events,
            sessionFolder: folder
        )

        let data = try Data(contentsOf: artifacts.logURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let diagnostic = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(diagnostic["event"] as? String, "transcription_succeeded")
        XCTAssertEqual(diagnostic["component"] as? String, "transcription")
        XCTAssertEqual(diagnostic["stage"] as? String, "publication")
        XCTAssertEqual(diagnostic["outcome"] as? String, "succeeded")
        XCTAssertEqual(diagnostic["artifactClass"] as? String, "transcription_log")
        XCTAssertFalse(text.contains("Native transcription started"))
        XCTAssertFalse(text.contains("Prepared 10000 audio chunks"))
    }

    func testNewPublicationArtifactsAreOwnerOnly() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try TranscriptionArtifactPublisher().publish(
            rawText: "old raw",
            finalText: "old final",
            manifest: .init(
                model: "asr-model",
                language: "yue",
                chunkCount: 1,
                responseFormats: ["json"]
            ),
            logEvents: [.started],
            sessionFolder: folder,
            now: Date(timeIntervalSince1970: 1)
        )
        for name in TranscriptionArtifactPublisher.canonicalNames {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: folder.appendingPathComponent(name).path
            )
        }
        let artifacts = try TranscriptionArtifactPublisher().publish(
            rawText: "raw",
            finalText: "final",
            manifest: .init(
                model: "asr-model",
                language: "yue",
                chunkCount: 1,
                responseFormats: ["json"]
            ),
            logEvents: [.completed],
            sessionFolder: folder,
            now: Date(timeIntervalSince1970: 2)
        )

        var generatedURLs = [
            artifacts.rawTranscriptURL,
            artifacts.transcriptURL,
            artifacts.manifestURL,
            artifacts.logURL
        ]
        generatedURLs += try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".previous-") }
        XCTAssertEqual(generatedURLs.count, 8)
        for url in generatedURLs {
            XCTAssertEqual(try permissions(of: url), 0o600, url.lastPathComponent)
        }
    }

    func testNewFailureDiagnosticIsOwnerOnly() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let diagnostic = try TranscriptionArtifactPublisher().publishFailureDiagnostic(
            .init(stage: .upload, errorCode: .providerTransportFailure),
            sessionFolder: folder
        )

        XCTAssertEqual(try permissions(of: diagnostic), 0o600)
    }

    func testPublicationStagingDirectoryIsOwnerOnly() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let retainingFileManager = RetainingTranscriptionStagingFileManager()

        _ = try TranscriptionArtifactPublisher(fileManager: retainingFileManager).publish(
            rawText: "raw",
            finalText: "final",
            manifest: .init(
                model: "asr-model",
                language: "yue",
                chunkCount: 1,
                responseFormats: ["json"]
            ),
            logEvents: [.completed],
            sessionFolder: folder
        )

        let staging = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".transcription-publish-") }
        )
        XCTAssertEqual(try permissions(of: staging), 0o700)
    }

    func testFailureDiagnosticPersistsOnlyAllowlistedTypedFields() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = "Bearer super-secret-api-key"
        let providerURL = "https://provider.example/v1/audio/transcriptions"
        let path = "/Users/example/private/recording.m4a"
        let transcript = "private meeting transcript"

        let diagnosticURL = try TranscriptionArtifactPublisher()
            .publishFailureDiagnostic(
                .init(
                    stage: .upload,
                    errorCode: .providerHTTPFailure,
                    httpStatus: 503
                ),
                sessionFolder: folder
            )

        let data = try Data(contentsOf: diagnosticURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertLessThanOrEqual(
            data.count,
            TranscriptionFailureDiagnostic.maximumBytes
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "transcription_failure")
        XCTAssertEqual(object["stage"] as? String, "upload")
        XCTAssertEqual(
            object["errorCode"] as? String,
            "provider_http_failure"
        )
        XCTAssertEqual(object["httpStatus"] as? Int, 503)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains(providerURL))
        XCTAssertFalse(text.contains(path))
        XCTAssertFalse(text.contains(transcript))
    }

    func testFailureDiagnosticRefusesDanglingSymlinkLeafWithoutWritingOutsideSession() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = folder.deletingLastPathComponent()
            .appendingPathComponent("outside-")
            .appendingPathComponent(UUID().uuidString)
        let destination = folder.appendingPathComponent(
            TranscriptionArtifactPublisher.failureDiagnosticFileName
        )
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try TranscriptionArtifactPublisher().publishFailureDiagnostic(
                .init(
                    stage: .preparation,
                    errorCode: .preparationFailure
                ),
                sessionFolder: folder
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: destination.path
            )
        )
    }

    func testFailureDiagnosticRefusesSymlinkedSessionFolderWithoutWritingOutside() throws {
        let parent = try makeFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let linkedFolder = parent.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)

        XCTAssertThrowsError(
            try TranscriptionArtifactPublisher().publishFailureDiagnostic(
                .init(stage: .upload, errorCode: .providerTransportFailure),
                sessionFolder: linkedFolder
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptionArtifactPublicationError, .unsafeSessionFolder)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent(
                    TranscriptionArtifactPublisher.failureDiagnosticFileName
                ).path
            )
        )
    }

    func testFailureDiagnosticRefusesDirectoryLeaf() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent(
            TranscriptionArtifactPublisher.failureDiagnosticFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try TranscriptionArtifactPublisher().publishFailureDiagnostic(
                .init(stage: .preparation, errorCode: .preparationFailure),
                sessionFolder: folder
            )
        )
    }

    func testPublicationIsCanonicalAndRetainsThreeBackups() throws {
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
                logEvents: [
                    .started,
                    .preparedChunks(2)
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
        let bytes = Data("final-4".utf8)
        XCTAssertEqual(
            artifacts?.committedTranscriptRevision,
            .init(
                sha256: "sha256:" + SHA256.hash(data: bytes)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                byteCount: bytes.count
            )
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

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private final class RetainingTranscriptionStagingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        guard !URL.lastPathComponent.hasPrefix(".transcription-publish-") else { return }
        try super.removeItem(at: URL)
    }
}
