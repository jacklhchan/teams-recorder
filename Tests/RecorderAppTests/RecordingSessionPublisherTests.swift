import Foundation
import XCTest
@testable import RecorderApp

final class RecordingSessionPublisherTests: XCTestCase {
    func testZeroByteMediaNeedsAttentionWithoutDestinationCopy() async throws {
        let fixture = try PublisherFixture(media: Data())

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .invalidMedia)
        }
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testSymlinkInSessionTreeIsRejectedWithoutFollowingIt() async throws {
        let fixture = try PublisherFixture()
        try FileManager.default.createSymbolicLink(
            at: fixture.sourceFolder.appendingPathComponent("transcript.txt"),
            withDestinationURL: fixture.outsideFile
        )

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .unsafeEntry)
        }
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testVerifiedPublicationReturnsCanonicalDestinationAndKeepsSource() async throws {
        let fixture = try PublisherFixture()

        let success = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertEqual(success.itemID, fixture.item.id)
        XCTAssertEqual(success.recordingURL.deletingLastPathComponent(), success.folderURL)
        XCTAssertEqual(try Data(contentsOf: success.recordingURL), try Data(contentsOf: fixture.recording))
        XCTAssertTrue(fixture.sourceExists)
    }

    func testRetryAfterPublishedRenameUsesMarkerAndDoesNotDuplicateDestination() async throws {
        let fixture = try PublisherFixture()
        let first = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
        let second = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: fixture.destinationURL, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }.count, 1)
    }
}

private final class PublisherFixture {
    let temporaryRoot: URL
    let pendingRoot: URL
    let sourceFolder: URL
    let destinationURL: URL
    let outsideFile: URL
    let store: RecordingPendingStore
    let item: RecordingPublicationItem
    let destination: RecordingDestinationAccess
    let publisher: RecordingSessionPublisher

    init(media: Data = Data("media".utf8)) throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-\(UUID().uuidString)", isDirectory: true)
        pendingRoot = temporaryRoot.appendingPathComponent("pending", isDirectory: true)
        destinationURL = temporaryRoot.appendingPathComponent("destination", isDirectory: true)
        outsideFile = temporaryRoot.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)
        store = RecordingPendingStore(root: pendingRoot)
        try store.prepareRoot()
        sourceFolder = pendingRoot.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: false)
        try media.write(to: sourceFolder.appendingPathComponent("recording.m4a"))
        item = RecordingPublicationItem(id: UUID(), sessionDirectoryName: "meeting", destinationIdentity: .init(id: UUID()), workspaceFenceRevision: 1, recordingSource: .manual, health: .init(), metadataWarning: nil, createdAt: Date(), lastAttemptAt: nil, attemptCount: 0, state: .pending, failureCategory: nil)
        destination = RecordingDestinationAccess(url: destinationURL, close: {})
        publisher = RecordingSessionPublisher(pendingStore: store, mediaValidator: { url in
            (try? Data(contentsOf: url).isEmpty == false) == true
        })
    }

    deinit { try? FileManager.default.removeItem(at: temporaryRoot) }

    var recording: URL { sourceFolder.appendingPathComponent("recording.m4a") }
    var sourceExists: Bool { FileManager.default.fileExists(atPath: sourceFolder.path) }
    var destinationIsEmpty: Bool { (try? FileManager.default.contentsOfDirectory(atPath: destinationURL.path).isEmpty) == true }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
