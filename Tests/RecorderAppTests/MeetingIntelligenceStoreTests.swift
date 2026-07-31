import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligenceStoreTests: XCTestCase {
    func testStagesAndPromotesValidV1Artifact() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let store = MeetingIntelligenceArtifactStore()
        let artifact = fixture.artifact(summary: "Customer migration")

        let staged = try store.stage(artifact, in: fixture.folder)
        XCTAssertTrue(staged.lastPathComponent.hasPrefix(".meeting-intelligence-stage-"))
        XCTAssertEqual(try store.load(in: fixture.folder), nil)

        try store.promoteStaged(staged, in: fixture.folder)
        XCTAssertEqual(try store.load(in: fixture.folder), artifact)
    }

    func testV1ArtifactIgnoresUnknownFields() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let data = Data(#"""
        {"schemaVersion":1,"summary":"Summary","suggestedTitle":"Title","sourceTranscriptSHA256":"sha256:abc","sourceTranscriptByteCount":3,"model":"model","generatedAt":"2026-07-31T00:00:00Z","intent":"generate","future":{"nested":[1,true]}}
        """#.utf8)
        try data.write(to: fixture.artifactURL)

        XCTAssertEqual(
            try MeetingIntelligenceArtifactStore().load(in: fixture.folder)?.summary,
            "Summary"
        )
    }

    func testFutureArtifactIsPreservedAndNotDecodedAsCurrent() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let future = Data(#"{"schemaVersion":2,"summary":"future"}"#.utf8)
        try future.write(to: fixture.artifactURL)

        XCTAssertThrowsError(
            try MeetingIntelligenceArtifactStore().load(in: fixture.folder)
        ) {
            XCTAssertEqual(
                $0 as? MeetingIntelligenceStoreError,
                .unsupportedSchemaVersion(2)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), future)
    }

    func testRejectsMalformedAndOversizedArtifactsWithoutReplacingExistingResult() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let original = try fixture.writeExistingArtifact()
        try Data("not json".utf8).write(to: fixture.artifactURL)

        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore().load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .malformed)
        }

        try original.write(to: fixture.artifactURL)
        let oversized = Data(repeating: 0x61, count: MeetingIntelligenceArtifactStore.maximumBytes + 1)
        try oversized.write(to: fixture.artifactURL)
        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore().load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .tooLarge)
        }
    }

    func testRejectsSymlinkAndDirectoryArtifacts() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.artifactURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore().load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsafeFile)
        }

        try FileManager.default.removeItem(at: fixture.artifactURL)
        try FileManager.default.createDirectory(at: fixture.artifactURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MeetingIntelligenceArtifactStore().load(in: fixture.folder)) {
            XCTAssertEqual($0 as? MeetingIntelligenceStoreError, .unsafeFile)
        }
    }

    func testFailedPromotionPreservesExistingArtifactBytes() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let original = try fixture.writeExistingArtifact()
        let missingStage = fixture.folder.appendingPathComponent(".meeting-intelligence-stage-missing")

        XCTAssertThrowsError(
            try MeetingIntelligenceArtifactStore().promoteStaged(
                missingStage,
                in: fixture.folder
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), original)
    }

    func testActiveStateLoadsAsInterruptedAndTerminalStateIsRetained() throws {
        let fixture = try MeetingIntelligenceStoreFixture()
        let store = MeetingIntelligenceStateStore()
        let started = Date(timeIntervalSince1970: 1_785_427_200)
        try store.save(
            .init(
                schemaVersion: 1,
                phase: .generating,
                message: "Generating",
                sourceTranscriptSHA256: "sha256:abc",
                startedAt: started,
                finishedAt: nil
            ),
            in: fixture.folder
        )

        let interrupted = try XCTUnwrap(try store.load(in: fixture.folder))
        XCTAssertEqual(interrupted.phase, .interrupted)
        XCTAssertEqual(interrupted.startedAt, started)
        XCTAssertNotNil(interrupted.finishedAt)

        try store.save(
            .init(
                schemaVersion: 1,
                phase: .completed,
                message: "Completed",
                sourceTranscriptSHA256: nil,
                startedAt: started,
                finishedAt: started.addingTimeInterval(1)
            ),
            in: fixture.folder
        )
        XCTAssertEqual(try store.load(in: fixture.folder)?.phase, .completed)
        try store.remove(in: fixture.folder)
        XCTAssertNil(try store.load(in: fixture.folder))
    }
}

private final class MeetingIntelligenceStoreFixture {
    let root: URL
    let folder: URL
    let artifactURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-intelligence-store-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("meeting", isDirectory: true)
        artifactURL = folder.appendingPathComponent(MeetingIntelligenceArtifactStore.fileName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func artifact(summary: String = "Summary") -> MeetingIntelligenceArtifact {
        .init(
            schemaVersion: 1,
            summary: summary,
            suggestedTitle: "Title",
            sourceTranscriptSHA256: "sha256:abc",
            sourceTranscriptByteCount: 3,
            model: "model",
            generatedAt: Date(timeIntervalSince1970: 1_785_427_200),
            intent: .generate
        )
    }

    func writeExistingArtifact() throws -> Data {
        let data = try JSONEncoder.meetingIntelligence.encode(artifact())
        try data.write(to: artifactURL)
        return data
    }
}

private extension JSONEncoder {
    static var meetingIntelligence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
