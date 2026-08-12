import Darwin
import Foundation
import XCTest
@testable import RecorderApp

final class RecordingPendingStoreTests: XCTestCase {
    func testCreateRootUsesOwnerOnlyPermissions() throws {
        let fixture = try PendingStoreFixture()
        try fixture.store.prepareRoot()

        XCTAssertEqual(try fixture.permissions(of: fixture.root) & 0o777, 0o700)
    }

    func testCreateSessionRejectsExistingNameWithoutReusingIt() throws {
        let fixture = try PendingStoreFixture()
        let existing = try fixture.makeSession(named: "meeting-collision")

        XCTAssertThrowsError(try fixture.store.createSession(named: "meeting-collision"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    func testCreateSessionRejectsReplacementObservedBeforeOpen() throws {
        let fixture = try PendingStoreFixture()
        let name = "meeting-replaced"
        let replacement = fixture.root.appendingPathComponent(name)
        let hooks = RecordingPendingStore.Hooks(afterCreateObservation: { parent, observedName in
            XCTAssertEqual(renameat(parent, observedName, parent, "original"), 0)
            XCTAssertEqual(mkdirat(parent, observedName, 0o700), 0)
        })

        XCTAssertThrowsError(try fixture.store.createSession(named: name, hooks: hooks))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testOversizedMetadataIsRejectedWithoutChangingOriginalBytes() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.store.createSession(named: "meeting-large-metadata")
        let metadataURL = session.displayURL.appendingPathComponent(RecordingSessionMetadataStore.fileName)
        let original = Data(repeating: 0x61, count: 262_145)
        try original.write(to: metadataURL)

        XCTAssertThrowsError(try fixture.store.updateRecordingSourceMetadata(.teamsAutomatic, in: session))
        XCTAssertEqual(try Data(contentsOf: metadataURL), original)
    }

    func testUnknownTitleOriginIsRejectedWithoutChangingOriginalBytes() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.store.createSession(named: "meeting-unknown-origin")
        let metadataURL = session.displayURL.appendingPathComponent(RecordingSessionMetadataStore.fileName)
        let original = Data(#"{"schemaVersion":2,"titleOrigin":"future-origin","source":"manual"}"#.utf8)
        try original.write(to: metadataURL)

        XCTAssertThrowsError(try fixture.store.updateRecordingSourceMetadata(.teamsAutomatic, in: session))
        XCTAssertEqual(try Data(contentsOf: metadataURL), original)
    }

    func testMetadataReplacementBeforeRenameIsPreserved() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.store.createSession(named: "meeting-metadata-replacement")
        let metadataURL = session.displayURL.appendingPathComponent(RecordingSessionMetadataStore.fileName)
        let original = Data(#"{"schemaVersion":2,"titleOrigin":"unset","source":"manual"}"#.utf8)
        let replacement = Data("replacement".utf8)
        try original.write(to: metadataURL)
        let hooks = RecordingPendingStore.Hooks(beforeMetadataRename: { directory, name in
            XCTAssertEqual(renameat(directory, name, directory, "original-recording-info.json"), 0)
            let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            if descriptor >= 0 {
                replacement.withUnsafeBytes { bytes in _ = Darwin.write(descriptor, bytes.baseAddress!, bytes.count) }
                Darwin.close(descriptor)
            }
        })

        XCTAssertThrowsError(try fixture.store.updateRecordingSourceMetadata(.teamsAutomatic, in: session, hooks: hooks))
        XCTAssertEqual(try Data(contentsOf: metadataURL), replacement)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: session.displayURL.path)
                .contains { $0.hasPrefix(".recording-info-") && $0.hasSuffix(".tmp") }
        )
    }

    func testDirectChildIsAcceptedButSymlinkAndEscapeAreRejected() throws {
        let fixture = try PendingStoreFixture()
        let direct = try fixture.makeSession(named: "meeting-direct")
        let outside = try fixture.makeOutsideSession(named: "meeting-outside")
        let link = fixture.root.appendingPathComponent("meeting-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let handle = try fixture.store.openSession(for: direct.lastPathComponent)
        XCTAssertEqual(handle.displayURL, direct)
        XCTAssertThrowsError(try fixture.store.openSession(for: link.lastPathComponent))
        XCTAssertThrowsError(try fixture.store.openSession(for: "../meeting-outside"))
    }

    func testSessionHandleKeepsOriginalDirectoryAfterNameIsReplacedBySymlink() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.makeSession(named: "meeting-handle")
        let outside = try fixture.makeOutsideSession(named: "meeting-outside")
        let handle = try fixture.store.openSession(for: session.lastPathComponent)

        try FileManager.default.removeItem(at: session)
        try FileManager.default.createSymbolicLink(at: session, withDestinationURL: outside)

        XCTAssertEqual(try fixture.directoryIdentity(of: handle.fileDescriptor), handle.identity)
        XCTAssertThrowsError(try fixture.store.openSession(for: session.lastPathComponent))
    }

    func testRemovalRejectsReplacementAndDoesNotDeleteIt() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.makeSession(named: "meeting-cleanup")
        let handle = try fixture.store.openSession(for: session.lastPathComponent)
        try FileManager.default.removeItem(at: session)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        let sentinel = session.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(try fixture.store.removeRetainedSession(handle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testScanSessionsSkipsManifestAndPublisherStagingNames() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.makeSession(named: "meeting-scan")
        try fixture.store.prepareRoot()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(".publisher-staging-123"), withIntermediateDirectories: false)
        try Data().write(to: fixture.manifestURL)

        XCTAssertEqual(try fixture.store.scanSessionNames(), [session.lastPathComponent])
    }

    func testManifestRoundTripPreservesEveryHealthFieldAndResetsPublishingToPending() throws {
        let fixture = try PendingStoreFixture()
        _ = try fixture.makeSession(named: "meeting-round-trip")
        let original = fixture.item(sessionDirectoryName: "meeting-round-trip", state: .publishing)
        let manifest = RecordingPublicationManifestStore(manifestURL: fixture.manifestURL)

        try manifest.save([original])
        let loaded = try manifest.loadOrRebuild(from: fixture.store)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, original.id)
        XCTAssertEqual(loaded[0].sessionDirectoryName, original.sessionDirectoryName)
        XCTAssertEqual(loaded[0].destinationIdentity, original.destinationIdentity)
        XCTAssertEqual(loaded[0].workspaceFenceRevision, original.workspaceFenceRevision)
        XCTAssertEqual(loaded[0].recordingSource, original.recordingSource)
        XCTAssertEqual(loaded[0].health, original.health)
        XCTAssertEqual(loaded[0].metadataWarning, original.metadataWarning)
        XCTAssertEqual(loaded[0].createdAt, original.createdAt)
        XCTAssertEqual(loaded[0].lastAttemptAt, original.lastAttemptAt)
        XCTAssertEqual(loaded[0].attemptCount, original.attemptCount)
        XCTAssertEqual(loaded[0].state, .pending)
        XCTAssertEqual(loaded[0].failureCategory, original.failureCategory)
        XCTAssertEqual(try manifest.loadOrRebuild(from: fixture.store)[0].state, .pending)
    }

    func testCorruptManifestPreservesSessionsAndRebuildsNeedsAttentionItems() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.makeSession(named: "meeting-recover")
        try Data("broken".utf8).write(to: fixture.manifestURL)
        XCTAssertEqual(chmod(fixture.manifestURL.path, 0o600), 0)
        let manifest = RecordingPublicationManifestStore(manifestURL: fixture.manifestURL)

        let items = try manifest.loadOrRebuild(from: fixture.store)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(items.map(\.state), [.needsAttention])
        XCTAssertEqual(items.map(\.sessionDirectoryName), [session.lastPathComponent])
        let relaunched = try manifest.loadOrRebuild(from: fixture.store)
        XCTAssertEqual(relaunched, items)
    }

    func testUnsafeManifestModeIsPreservedAndRecoveredWithoutFollowingIt() throws {
        let fixture = try PendingStoreFixture()
        _ = try fixture.makeSession(named: "meeting-unsafe-manifest")
        try Data("broken".utf8).write(to: fixture.manifestURL)
        XCTAssertEqual(chmod(fixture.manifestURL.path, 0o644), 0)

        let items = try RecordingPublicationManifestStore(manifestURL: fixture.manifestURL)
            .loadOrRebuild(from: fixture.store)

        XCTAssertEqual(items.map(\.state), [.needsAttention])
        XCTAssertEqual(try fixture.permissions(of: fixture.manifestURL) & 0o777, 0o644)
    }

    func testSaveRejectsUnsafeExistingManifestWithoutReplacingIt() throws {
        let fixture = try PendingStoreFixture()
        let original = Data("unsafe exact manifest".utf8)
        try fixture.store.prepareRoot()
        try original.write(to: fixture.manifestURL)
        XCTAssertEqual(chmod(fixture.manifestURL.path, 0o644), 0)

        XCTAssertThrowsError(
            try RecordingPublicationManifestStore(manifestURL: fixture.manifestURL)
                .save([fixture.item(sessionDirectoryName: "meeting", state: .pending)])
        )
        XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), original)
        XCTAssertEqual(try fixture.permissions(of: fixture.manifestURL) & 0o777, 0o644)
    }

    func testManifestParentSymlinkIsRejectedWithoutFollowingIt() throws {
        let fixture = try PendingStoreFixture()
        let outside = fixture.temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let linkedRoot = fixture.temporaryRoot.appendingPathComponent("linked-pending", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

        XCTAssertThrowsError(
            try RecordingPublicationManifestStore(
                manifestURL: linkedRoot.appendingPathComponent("publication-queue-v1.json")
            ).save([])
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("publication-queue-v1.json").path))
    }

    func testUnsupportedManifestVersionPreservesSessionsAndRebuildsNeedsAttentionItems() throws {
        let fixture = try PendingStoreFixture()
        let session = try fixture.makeSession(named: "meeting-version-recover")
        try Data("{\"version\": 2, \"items\": []}".utf8).write(to: fixture.manifestURL)
        XCTAssertEqual(chmod(fixture.manifestURL.path, 0o600), 0)

        let items = try RecordingPublicationManifestStore(manifestURL: fixture.manifestURL)
            .loadOrRebuild(from: fixture.store)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(items.map(\.state), [.needsAttention])
        let relaunched = try RecordingPublicationManifestStore(manifestURL: fixture.manifestURL)
            .loadOrRebuild(from: fixture.store)
        XCTAssertEqual(relaunched, items)
    }
}

private final class PendingStoreFixture {
    let temporaryRoot: URL
    let root: URL
    let manifestURL: URL
    let store: RecordingPendingStore

    init() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = temporaryRoot.appendingPathComponent("Pending Recordings", isDirectory: true)
        manifestURL = root.appendingPathComponent("publication-queue-v1.json")
        store = RecordingPendingStore(root: root, manifestURL: manifestURL)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func makeSession(named name: String) throws -> URL {
        try store.prepareRoot()
        let session = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        return session
    }

    func makeOutsideSession(named name: String) throws -> URL {
        let session = temporaryRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        return session
    }

    func permissions(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
    }

    func directoryIdentity(of descriptor: Int32) throws -> RecordingPendingSessionIdentity {
        var value = stat()
        XCTAssertEqual(fstat(descriptor, &value), 0)
        return RecordingPendingSessionIdentity(device: Int64(value.st_dev), inode: Int64(value.st_ino))
    }

    func item(sessionDirectoryName: String, state: RecordingPublicationState) -> RecordingPublicationItem {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let endedAt = Date(timeIntervalSinceReferenceDate: 200)
        let health = RecordingHealthReport(
            systemSignalSeen: true,
            micSignalSeen: true,
            clippingEvents: 1,
            droppedBuffers: 2,
            conversionFailures: 3,
            lateFrames: 4,
            systemDisconnects: 5,
            microphoneDisconnects: 6,
            streamFailures: 7,
            timelineDiscontinuities: 8,
            videoDroppedFrames: 9,
            videoInvalidTimestamps: 10,
            videoStallEvents: 11,
            videoFilterFailures: 12,
            muxFallbackEvents: 13,
            metadataWriteFailures: 14,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return RecordingPublicationItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionDirectoryName: sessionDirectoryName,
            destinationIdentity: RecordingDestinationIdentity(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            workspaceFenceRevision: 42,
            recordingSource: .teamsAutomatic,
            health: health,
            metadataWarning: "metadata warning",
            createdAt: Date(timeIntervalSinceReferenceDate: 300),
            lastAttemptAt: Date(timeIntervalSinceReferenceDate: 400),
            attemptCount: 5,
            state: state,
            failureCategory: "network"
        )
    }
}
