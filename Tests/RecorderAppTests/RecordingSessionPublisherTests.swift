import Darwin
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

    func testPublisherRejectsMissingAdmissionIdentityBeforeWritingDestination() async throws {
        let fixture = try PublisherFixture(admit: false)

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .invalidSource)
        }
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testPublisherRejectsMismatchedAdmissionIdentityBeforeWritingDestination() async throws {
        let fixture = try PublisherFixture()
        let wrongIdentity = RecordingPendingSessionIdentity(
            device: fixture.item.sourceIdentity!.device,
            inode: fixture.item.sourceIdentity!.inode + 1
        )
        let mismatched = RecordingPublicationItem(
            id: fixture.item.id,
            sessionDirectoryName: fixture.item.sessionDirectoryName,
            destinationIdentity: fixture.item.destinationIdentity,
            workspaceFenceRevision: fixture.item.workspaceFenceRevision,
            recordingSource: fixture.item.recordingSource,
            health: fixture.item.health,
            metadataWarning: fixture.item.metadataWarning,
            sourceIdentity: wrongIdentity,
            sourceRootIdentity: fixture.item.sourceRootIdentity,
            createdAt: fixture.item.createdAt,
            lastAttemptAt: fixture.item.lastAttemptAt,
            attemptCount: fixture.item.attemptCount,
            state: fixture.item.state,
            failureCategory: fixture.item.failureCategory
        )

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: mismatched, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .invalidSource)
        }
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testNonemptyInvalidMediaIsRejected() async throws {
        let fixture = try PublisherFixture(media: Data("not-media".utf8), mediaValidator: { _, _ in false })

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .invalidMedia)
        }
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testIntermediateDestinationSymlinkIsRejectedWithoutWritingOutside() async throws {
        let fixture = try PublisherFixture()
        let outsideParent = fixture.temporaryRoot.appendingPathComponent("outside-parent", isDirectory: true)
        let outsideDestination = outsideParent.appendingPathComponent("destination", isDirectory: true)
        let linkedParent = fixture.temporaryRoot.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDestination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outsideParent)
        let unsafeAccess = RecordingDestinationAccess(
            url: linkedParent.appendingPathComponent("destination", isDirectory: true),
            close: {}
        )

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: unsafeAccess)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .destinationUnavailable)
        }

        XCTAssertTrue(fixture.sourceExists)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideDestination.path), [])
    }

    func testMediaValidatorReadsExactOpenedFileAfterPathReplacement() async throws {
        let original = Data("original-media".utf8)
        var fixture: PublisherFixture!
        var observed = Data()
        var didReplace = false
        fixture = try PublisherFixture(media: original, mediaValidator: { descriptor, _ in
            if !didReplace {
                didReplace = true
                let moved = fixture.sourceFolder.appendingPathComponent("moved.m4a")
                try? FileManager.default.moveItem(at: fixture.recording, to: moved)
                try? Data("replacement!!".utf8).write(to: fixture.recording)
                observed = readDescriptor(descriptor)
            }
            return true
        })

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) { _ in }

        XCTAssertEqual(observed, original)
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

    func testSourceEntryIdentityChangeAfterObservationIsRejected() async throws {
        var didReplace = false
        var fixture: PublisherFixture!
        fixture = try PublisherFixture(hooks: .init(afterEntryObservation: { context, directory, name in
            guard context == .source, name == "recording.m4a", !didReplace else { return }
            didReplace = true
            XCTAssertEqual(renameat(directory, name, directory, "old-recording.m4a"), 0)
            let replacement = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(replacement, 0)
            if replacement >= 0 {
                _ = Darwin.write(replacement, [UInt8]("media".utf8), 5)
                Darwin.close(replacement)
            }
        }))

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .unsafeEntry)
        }
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testRecordingReplacedAfterInventoryBeforeMediaOpenIsRejected() async throws {
        var recordingObservations = 0
        let fixture = try PublisherFixture(hooks: .init(afterEntryObservation: { context, directory, name in
            guard context == .source, name == "recording.m4a" else { return }
            recordingObservations += 1
            guard recordingObservations == 2 else { return }
            XCTAssertEqual(renameat(directory, name, directory, "inventoried-recording.m4a"), 0)
            let replacement = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(replacement, 0)
            if replacement >= 0 {
                _ = Darwin.write(replacement, [UInt8]("media".utf8), 5)
                Darwin.close(replacement)
            }
        }))

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .invalidMedia)
        }

        XCTAssertEqual(recordingObservations, 2)
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testTraversalDeeperThanLimitIsRejected() async throws {
        let fixture = try PublisherFixture()
        var folder = fixture.sourceFolder
        for index in 0...32 {
            folder.appendPathComponent("d\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .unsafeEntry)
        }
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testDigestMismatchKeepsSourceAndRemovesExactOwnedStaging() async throws {
        let fixture = try PublisherFixture(hooks: .init(beforeStagingVerification: { staging in
            let descriptor = openat(staging, "recording.m4a", O_WRONLY | O_TRUNC | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            if descriptor >= 0 {
                _ = Darwin.write(descriptor, [UInt8]("other".utf8), 5)
                Darwin.close(descriptor)
            }
        }))

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .verificationMismatch)
        }
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertFalse(fixture.stagingExists)
    }

    func testCleanupDoesNotDeleteLateReplacementOfStagingName() async throws {
        let fixture = try PublisherFixture(hooks: .init(
            beforeStagingVerification: { staging in
                let descriptor = openat(staging, "recording.m4a", O_WRONLY | O_TRUNC | O_NOFOLLOW)
                if descriptor >= 0 { Darwin.close(descriptor) }
            },
            beforeStagingCleanup: { parent, name in
                XCTAssertEqual(renameat(parent, name, parent, ".moved-owned-staging"), 0)
                XCTAssertEqual(mkdirat(parent, name, 0o700), 0)
                let replacement = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                XCTAssertGreaterThanOrEqual(replacement, 0)
                if replacement >= 0 {
                    let sentinel = openat(replacement, "sentinel", O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    if sentinel >= 0 { Darwin.close(sentinel) }
                    Darwin.close(replacement)
                }
            }
        ))

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) { _ in }

        XCTAssertTrue(fixture.stagingExists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stagingURL.appendingPathComponent("sentinel").path))
    }

    func testExistingOriginalDestinationUsesItemIDSuffixAndPreservesExistingBytes() async throws {
        let fixture = try PublisherFixture()
        let originalFolder = fixture.destinationURL.appendingPathComponent("meeting", isDirectory: true)
        let existing = originalFolder.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: existing)

        let success = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertEqual(success.folderURL.lastPathComponent, "meeting-\(fixture.item.id.uuidString)")
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        XCTAssertEqual(fixture.publishedFolders.count, 2)
    }

    func testLateFallbackCollisionIsRejectedWithoutOverwritingEitherDestination() async throws {
        var fixture: PublisherFixture!
        fixture = try PublisherFixture(hooks: .init(beforeFinalRename: { parent, finalName in
            XCTAssertEqual(mkdirat(parent, finalName, 0o700), 0)
            let collision = openat(parent, finalName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if collision >= 0 {
                let sentinel = openat(collision, "late", O_WRONLY | O_CREAT | O_EXCL, 0o600)
                if sentinel >= 0 { Darwin.close(sentinel) }
                Darwin.close(collision)
            }
        }))
        let originalFolder = fixture.destinationURL.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: originalFolder.appendingPathComponent("existing"))

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .destinationCollision)
        }

        XCTAssertEqual(try Data(contentsOf: originalFolder.appendingPathComponent("existing")), Data("keep".utf8))
        let late = fixture.destinationURL.appendingPathComponent("meeting-\(fixture.item.id.uuidString)/late")
        XCTAssertTrue(FileManager.default.fileExists(atPath: late.path))
        XCTAssertFalse(fixture.stagingExists)
    }

    func testReplacementAtFinalRenameIsPreserved() async throws {
        let fixture = try PublisherFixture(hooks: .init(beforeFinalRename: { parent, name in
            XCTAssertEqual(mkdirat(parent, name, 0o700), 0)
            let replacement = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if replacement >= 0 { Darwin.close(replacement) }
        }))

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .destinationCollision)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationURL.appendingPathComponent("meeting").path))
        XCTAssertTrue(fixture.sourceExists)
    }

    func testMarkerWriterCompletesDeterministicShortWrites() async throws {
        let fixture = try PublisherFixture(markerWriter: { descriptor, bytes, count in
            Darwin.write(descriptor, bytes, min(2, count))
        })

        let first = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
        let second = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertEqual(second, first, "A complete marker must remain decodable and idempotent")
        XCTAssertEqual(fixture.publishedFolders.count, 1)
    }

    func testPostRenameValidationRejectsRecordingSymlinkWithoutReopeningURL() async throws {
        var validations = 0
        let fixture = try PublisherFixture(
            mediaValidator: { descriptor, _ in
                validations += 1
                return !readDescriptor(descriptor).isEmpty
            },
            hooks: .init(beforePublishedValidation: { folder, recordingName in
                XCTAssertEqual(renameat(folder, recordingName, folder, "original.m4a"), 0)
                XCTAssertEqual(symlinkat("original.m4a", folder, recordingName), 0)
            })
        )

        await XCTAssertThrowsErrorAsync(try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)) {
            XCTAssertEqual($0 as? RecordingPublicationError, .invalidMedia)
        }
        XCTAssertEqual(validations, 1, "The URL/symlink destination must never reach the validator")
    }

    func testVerifiedPublicationReturnsCanonicalDestinationAndKeepsSource() async throws {
        let fixture = try PublisherFixture()

        let success = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertEqual(success.itemID, fixture.item.id)
        XCTAssertEqual(success.recordingURL.deletingLastPathComponent(), success.folderURL)
        XCTAssertEqual(try Data(contentsOf: success.recordingURL), try Data(contentsOf: fixture.recording))
        XCTAssertTrue(fixture.sourceExists)
    }

    func testRetryAfterPublishedRenameRecomputesInventoryBeforeTrustingMarker() async throws {
        let fixture = try PublisherFixture()
        let first = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
        try Data("tampered".utf8).write(to: first.recordingURL)

        let second = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertNotEqual(second.folderURL, first.folderURL)
        XCTAssertEqual(fixture.publishedFolders.count, 2)
        XCTAssertEqual(try Data(contentsOf: second.recordingURL), Data("media".utf8))
    }

    func testRetryAfterPublishedRenameUsesVerifiedMarkerAndDoesNotDuplicateDestination() async throws {
        let fixture = try PublisherFixture()
        let first = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
        let second = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertEqual(second, first)
        XCTAssertEqual(fixture.publishedFolders.count, 1)
    }

    func testOversizedMarkerIsNotReadAsIdempotentAuthority() async throws {
        let fixture = try PublisherFixture()
        let first = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
        try Data(repeating: 0x20, count: 65_537).write(to: first.folderURL.appendingPathComponent(".lmr-publication-v1.json"))

        let second = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)

        XCTAssertNotEqual(second.folderURL, first.folderURL)
        XCTAssertEqual(fixture.publishedFolders.count, 2)
    }

    func testAllBlockedDestinationOpenWorkersRejectQueuedRetryWithoutAnotherSyscall() async throws {
        let opener = BlockingDestinationOpener()
        let fixture = try PublisherFixture(
            destinationOpenDeadline: .milliseconds(50),
            destinationOpener: opener.open
        )

        let first = Task { () -> Error? in
            do {
                _ = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
                return nil
            } catch {
                return error
            }
        }
        await fulfillment(of: [opener.firstStarted], timeout: 1)

        let second = Task { () -> Error? in
            do {
                _ = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
                return nil
            } catch {
                return error
            }
        }
        await fulfillment(of: [opener.secondStarted], timeout: 1)

        let third = Task { () -> Error? in
            do {
                _ = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
                return nil
            } catch {
                return error
            }
        }

        let firstError = await first.value
        let secondError = await second.value
        let thirdError = await third.value
        XCTAssertEqual(firstError as? RecordingPublicationError, .destinationUnavailable)
        XCTAssertEqual(secondError as? RecordingPublicationError, .destinationUnavailable)
        XCTAssertEqual(thirdError as? RecordingPublicationError, .destinationUnavailable)
        XCTAssertEqual(opener.callCount, 2)
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.destinationIsEmpty)

        opener.release()
        opener.release()
        await fulfillment(of: [opener.returned], timeout: 1)
        XCTAssertEqual(opener.callCount, 2)
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testSecondPublishedValidationSucceedsWhileFirstWorkerRemainsBlocked() async throws {
        let opener = FirstOpenBlocksThenSucceedsOpener()
        let fixture = try PublisherFixture()
        let published = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
        let validator = RecordingSessionPublisher(
            pendingStore: fixture.store,
            mediaValidator: { descriptor, _ in !readDescriptor(descriptor).isEmpty },
            destinationOpenDeadline: .milliseconds(50),
            destinationOpener: opener.open
        )
        var publishedItem = fixture.item
        publishedItem.state = .published
        publishedItem.publishedFolderName = published.folderURL.lastPathComponent
        publishedItem.publishedRecordingName = published.recordingURL.lastPathComponent
        publishedItem.publishedSourceDevice = published.sourceDevice
        publishedItem.publishedSourceInode = published.sourceInode
        publishedItem.publishedSourceRootDevice = published.sourceRootDevice
        publishedItem.publishedSourceRootInode = published.sourceRootInode

        let first = Task { () -> Error? in
            do {
                _ = try await validator.validatePublished(item: publishedItem, destination: fixture.destination)
                return nil
            } catch {
                return error
            }
        }
        await fulfillment(of: [opener.firstStarted], timeout: 1)

        let second = try await validator.validatePublished(item: publishedItem, destination: fixture.destination)
        let firstError = await first.value

        XCTAssertEqual(second.itemID, fixture.item.id)
        XCTAssertEqual(firstError as? RecordingPublicationError, .destinationUnavailable)
        XCTAssertGreaterThan(opener.callCount, 1)
        opener.release()
        await fulfillment(of: [opener.returned], timeout: 1)
    }

    func testTimedOutDestinationOpenClosesItsRetainedParentDescriptorExactlyOnce() async throws {
        let opener = BlockingDestinationOpener(expectedReturns: 1)
        let closer = DestinationCloseObserver()
        let fixture = try PublisherFixture(
            destinationOpenDeadline: .milliseconds(50),
            destinationOpener: opener.open,
            destinationCloser: closer.close
        )

        let error = await Task { () -> Error? in
            do {
                _ = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destination)
                return nil
            } catch {
                return error
            }
        }.value

        XCTAssertEqual(error as? RecordingPublicationError, .destinationUnavailable)
        XCTAssertEqual(closer.closeCount, 1)
        opener.release()
        await fulfillment(of: [opener.returned], timeout: 1)
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

    init(
        media: Data = Data("media".utf8),
        admit: Bool = true,
        mediaValidator: @escaping RecordingSessionPublisher.MediaValidator = { descriptor, _ in
            !readDescriptor(descriptor).isEmpty
        },
        hooks: RecordingSessionPublisher.Hooks = .init(),
        markerWriter: @escaping RecordingSessionPublisher.WriteOperation = { descriptor, bytes, count in
            Darwin.write(descriptor, bytes, count)
        },
        destinationOpenDeadline: Duration = .seconds(2),
        destinationOpener: @escaping RecordingSessionPublisher.DestinationOpener = { parent, name, flags in
            openat(parent, name, flags)
        },
        destinationCloser: @escaping RecordingSessionPublisher.DestinationCloser = { Darwin.close($0) }
    ) throws {
        temporaryRoot = try realDirectoryURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("publisher-\(UUID().uuidString)", isDirectory: true)
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
        let retained = admit ? try store.openSession(for: "meeting") : nil
        item = RecordingPublicationItem(id: UUID(), sessionDirectoryName: "meeting", destinationIdentity: .init(id: UUID()), workspaceFenceRevision: 1, recordingSource: .manual, health: .init(), metadataWarning: nil, sourceIdentity: retained?.identity, sourceRootIdentity: retained?.rootIdentity, createdAt: Date(), lastAttemptAt: nil, attemptCount: 0, state: .pending, failureCategory: nil)
        destination = RecordingDestinationAccess(url: destinationURL, close: {})
        publisher = RecordingSessionPublisher(
            pendingStore: store,
            mediaValidator: mediaValidator,
            hooks: hooks,
            writeOperation: markerWriter,
            destinationOpenDeadline: destinationOpenDeadline,
            destinationOpener: destinationOpener,
            destinationCloser: destinationCloser
        )
    }

    deinit { try? FileManager.default.removeItem(at: temporaryRoot) }

    var recording: URL { sourceFolder.appendingPathComponent("recording.m4a") }
    var sourceExists: Bool { FileManager.default.fileExists(atPath: sourceFolder.path) }
    var stagingURL: URL { destinationURL.appendingPathComponent(".\(item.id.uuidString).lmr-publishing", isDirectory: true) }
    var stagingExists: Bool { FileManager.default.fileExists(atPath: stagingURL.path) }
    var destinationIsEmpty: Bool { (try? FileManager.default.contentsOfDirectory(atPath: destinationURL.path).isEmpty) == true }
    var publishedFolders: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: destinationURL, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }) ?? []
    }
}

private final class BlockingDestinationOpener: @unchecked Sendable {
    let firstStarted = XCTestExpectation(description: "first destination open started")
    let secondStarted = XCTestExpectation(description: "second destination open started")
    let returned: XCTestExpectation
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var calls = 0

    init(expectedReturns: Int = 2) {
        returned = XCTestExpectation(description: "blocked destination opens returned")
        returned.expectedFulfillmentCount = expectedReturns
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func open(parent: Int32, name: String, flags: Int32) -> Int32 {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == 1 { firstStarted.fulfill() }
        if call == 2 { secondStarted.fulfill() }
        releaseSignal.wait()
        returned.fulfill()
        return openat(parent, name, flags)
    }

    func release() { releaseSignal.signal() }
}

private final class FirstOpenBlocksThenSucceedsOpener: @unchecked Sendable {
    let firstStarted = XCTestExpectation(description: "first destination open started")
    let returned = XCTestExpectation(description: "first blocked destination open returned")
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func open(parent: Int32, name: String, flags: Int32) -> Int32 {
        lock.lock()
        calls += 1
        let isFirst = calls == 1
        lock.unlock()
        if isFirst {
            firstStarted.fulfill()
            releaseSignal.wait()
            returned.fulfill()
        }
        return openat(parent, name, flags)
    }

    func release() { releaseSignal.signal() }
}

private final class DestinationCloseObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var closes = 0

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    func close(_ descriptor: Int32) -> Int32 {
        lock.lock()
        closes += 1
        lock.unlock()
        return Darwin.close(descriptor)
    }
}

private func realDirectoryURL(_ url: URL) throws -> URL {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    let succeeded = url.path.withCString { realpath($0, &resolved) != nil }
    guard succeeded else { throw CocoaError(.fileReadNoSuchFile) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private func readDescriptor(_ descriptor: Int32) -> Data {
    let copy = dup(descriptor)
    guard copy >= 0 else { return Data() }
    defer { Darwin.close(copy) }
    guard lseek(copy, 0, SEEK_SET) >= 0 else { return Data() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = Darwin.read(copy, &buffer, buffer.count)
        guard count > 0 else { return result }
        result.append(buffer, count: count)
    }
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
