import Foundation
import XCTest
@testable import RecorderApp

final class RecordingRetentionScannerTests: XCTestCase {
    func testDisabledPolicyDoesNotProduceOrDeleteCandidates() throws {
        let fixture = try RetentionFixture()
        let session = try fixture.session(named: "published")
        let log = session.displayURL.appendingPathComponent("transcription.log")
        try Data("diagnostic".utf8).write(to: log)
        try fixture.makeOld(log)

        let result = RecordingRetentionScanner().scan(
            policy: .safeDefault,
            publicationSnapshot: .init(publishedSessionDirectoryNames: ["published"]),
            pendingStore: fixture.store,
            now: fixture.now
        )

        XCTAssertEqual(result.candidates.count, 0)
        XCTAssertEqual(result.aggregate, .init())
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
    }

    func testProtectedFavoriteUnknownAndLinkedArtifactsAreSkipped() throws {
        let fixture = try RetentionFixture()
        let favorite = try fixture.session(named: "favorite", favorite: true)
        let recovered = try fixture.session(
            named: "recovered",
            recoveryState: .recoveredAfterInterruption
        )
        let unknown = try fixture.session(named: "unknown")
        let linked = try fixture.session(named: "linked")
        for session in [favorite, recovered, unknown, linked] {
            let log = session.displayURL.appendingPathComponent("transcription.log")
            try Data("diagnostic".utf8).write(to: log)
            try fixture.makeOld(log)
        }
        let outside = fixture.root.appendingPathComponent("outside.log")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: linked.displayURL.appendingPathComponent("transcription.log"))
        try FileManager.default.createSymbolicLink(
            at: linked.displayURL.appendingPathComponent("transcription.log"),
            withDestinationURL: outside
        )

        let result = RecordingRetentionScanner().scan(
            policy: fixture.enabledPolicy,
            publicationSnapshot: .init(publishedSessionDirectoryNames: ["favorite", "recovered", "linked"]),
            pendingStore: fixture.store,
            now: fixture.now
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.aggregate.skipped, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testReplacementBetweenScanAndDeleteIsRejected() throws {
        let fixture = try RetentionFixture()
        let session = try fixture.session(named: "published")
        let log = session.displayURL.appendingPathComponent("transcription.log")
        try Data("original".utf8).write(to: log)
        try fixture.makeOld(log)
        let scanner = RecordingRetentionScanner()
        let candidate = try XCTUnwrap(scanner.scan(
            policy: fixture.enabledPolicy,
            publicationSnapshot: .init(publishedSessionDirectoryNames: ["published"]),
            pendingStore: fixture.store,
            now: fixture.now
        ).candidates.first)
        try FileManager.default.removeItem(at: log)
        try Data("replacement".utf8).write(to: log)

        XCTAssertEqual(scanner.delete(candidate), .rejected)
        XCTAssertEqual(try Data(contentsOf: log), Data("replacement".utf8))
    }

    func testEligiblePublishedDiagnosticDeletesOnlyExactInode() throws {
        let fixture = try RetentionFixture()
        let session = try fixture.session(named: "published")
        let log = session.displayURL.appendingPathComponent("transcription.log")
        let media = session.displayURL.appendingPathComponent("recording.m4a")
        try Data("diagnostic".utf8).write(to: log)
        try Data("media".utf8).write(to: media)
        try fixture.makeOld(log)
        try fixture.makeOld(media)
        let scanner = RecordingRetentionScanner()
        let candidate = try XCTUnwrap(scanner.scan(
            policy: fixture.enabledPolicy,
            publicationSnapshot: .init(publishedSessionDirectoryNames: ["published"]),
            pendingStore: fixture.store,
            now: fixture.now
        ).candidates.first)

        XCTAssertEqual(scanner.delete(candidate), .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }
}

private final class RetentionFixture {
    let root: URL
    let store: RecordingPendingStore
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    let enabledPolicy = RecordingDataLifecyclePolicy(
        retention: .enabled(eligibleClasses: [.transcriptionLog], olderThanDays: 30)
    )

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = RecordingPendingStore(root: root)
        try store.prepareRoot()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func session(
        named name: String,
        favorite: Bool = false,
        recoveryState: RecordingRecoveryState = .none
    ) throws -> RecordingPendingSession {
        let session = try store.createSession(named: name)
        try store.saveRecordingMetadata(
            .init(isFavorite: favorite, recoveryState: recoveryState),
            in: session
        )
        return session
    }

    func makeOld(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-31 * 86_400)],
            ofItemAtPath: url.path
        )
    }
}
