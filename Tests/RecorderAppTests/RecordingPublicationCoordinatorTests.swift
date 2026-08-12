import Darwin
import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class RecordingPublicationCoordinatorTests: XCTestCase {
    @MainActor
    func testManifestSaveFailureBeforePublishingRetainsSourceAndDoesNotInvokePublisherOrCompletion() async throws {
        let fixture = try CoordinatorFixture()
        let failingManifest = FailingCoordinatorManifestStore()
        let coordinator = RecordingPublicationCoordinator(
            manifestStore: failingManifest,
            destinationStore: fixture.destination,
            publisher: fixture.publisher,
            pendingStore: fixture.pending,
            retryDelays: [1]
        )
        var presentations: [RecordingPublicationPresentation] = []
        var completions: [RecordingPublicationCompleted] = []
        coordinator.onPresentationChange = { presentations.append($0) }
        coordinator.onCompleted = { completions.append($0) }

        coordinator.enqueue(fixture.request)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.publisher.attemptCount, 0)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertEqual(presentations.last?.stateText, "Publish failed")
    }
    func testOfflineAttemptRetainsSourceAndManualRetryPublishesThenCleansUp() async throws {
        let fixture = try CoordinatorFixture(destinationAvailable: false)
        fixture.coordinator.enqueue(fixture.request)
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.coordinator.presentation.waitingCount, 1)
        XCTAssertTrue(fixture.sourceExists)

        fixture.destinationAvailable = true
        fixture.coordinator.retryNow()
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.publisher.publishedIDs, [fixture.request.id])
        XCTAssertEqual(fixture.completions.values.map(\.itemID), [fixture.request.id])
        XCTAssertFalse(fixture.sourceExists)
    }

    func testRelaunchPublishedItemDeliversCompletionAndCleansUp() async throws {
        let fixture = try CoordinatorFixture(manifestState: .published)
        fixture.coordinator.resume()
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.completions.values.map(\.itemID), [fixture.request.id])
        XCTAssertFalse(fixture.sourceExists)
        XCTAssertTrue(try fixture.manifest.loadOrRebuild(from: fixture.pending).isEmpty)
    }

    func testInvalidMediaNeedsAttentionAndDoesNotAutoRetry() async throws {
        let fixture = try CoordinatorFixture(publisherError: .invalidMedia)
        fixture.coordinator.enqueue(fixture.request)
        await fixture.waitForIdle()
        fixture.coordinator.resume()
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.publisher.attemptCount, 1)
        XCTAssertEqual(fixture.coordinator.presentation.needsAttentionCount, 1)
        XCTAssertTrue(fixture.sourceExists)
    }

    func testShutdownRejectsLatePublisherSuccessWithoutCallbackOrCleanup() async throws {
        let fixture = try CoordinatorFixture()
        fixture.publisher.suspendNextPublish = true
        fixture.coordinator.enqueue(fixture.request)
        await fixture.publisher.waitUntilSuspended()

        fixture.coordinator.shutdown()
        fixture.publisher.completeSuspendedPublish()
        await fixture.waitForIdle()

        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.completions.values.isEmpty)
        XCTAssertEqual(fixture.coordinator.presentation.pendingCount, 1)
    }

    func testSourceReplacementBeforeCleanupIsNeverDeleted() async throws {
        let fixture = try CoordinatorFixture()
        fixture.publisher.beforeSuccess = {
            let source = fixture.pending.root.appendingPathComponent(fixture.request.sessionDirectoryName)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try? Data("replacement".utf8).write(to: source.appendingPathComponent("keep"))
        }

        fixture.coordinator.enqueue(fixture.request)
        await fixture.waitForIdle()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.pending.root.appendingPathComponent("meeting/keep").path))
        XCTAssertEqual(fixture.coordinator.presentation.needsAttentionCount, 1)
    }
    func testPublishedStateRetainsDirectChildNamesForRelaunchCompletion() throws {
        let item = RecordingPublicationItem(
            id: UUID(), sessionDirectoryName: "meeting", destinationIdentity: .init(id: UUID()),
            workspaceFenceRevision: 7, recordingSource: .manual, health: .init(), metadataWarning: nil,
            createdAt: Date(), lastAttemptAt: nil, attemptCount: 1, state: .published,
            failureCategory: nil, publishedFolderName: "meeting", publishedRecordingName: "recording.m4a"
        )

        XCTAssertEqual(item.publishedFolderName, "meeting")
        XCTAssertEqual(item.publishedRecordingName, "recording.m4a")
    }

    func testPresentationIncludesRetainedLocalItems() {
        let presentation = RecordingPublicationPresentation(
            stateText: "Waiting", pendingCount: 1, waitingCount: 2, needsAttentionCount: 3
        )

        XCTAssertEqual(presentation.retainedLocalCount, 6)
    }

    func testPublishedDestinationUnavailableRemainsTerminalWaitingAndManualRetryValidatesBeforeCompleting() async throws {
        let fixture = try CoordinatorFixture(destinationAvailable: false, manifestState: .published)
        fixture.coordinator.resume()
        await fixture.waitForIdle()

        let waiting = try XCTUnwrap(fixture.persistedItems.first)
        XCTAssertEqual(waiting.state, .published)
        XCTAssertEqual(waiting.failureCategory, "destinationUnavailable")
        XCTAssertEqual(fixture.coordinator.presentation.pendingCount, 0)
        XCTAssertEqual(fixture.coordinator.presentation.waitingCount, 1)
        XCTAssertEqual(fixture.publisher.attemptCount, 0)

        fixture.destinationAvailable = true
        fixture.coordinator.retryNow()
        await fixture.waitForIdle()

        XCTAssertEqual(fixture.publisher.validationIDs, [fixture.request.id])
        XCTAssertEqual(fixture.completions.values.map(\.itemID), [fixture.request.id])
    }

    func testTransientFailureWakesForBoundedBackoffWithoutBusyLoop() async throws {
        let fixture = try CoordinatorFixture(publisherErrors: [.ioFailure("once")], retryDelays: [0.02])
        fixture.coordinator.enqueue(fixture.request)
        await fixture.wait(seconds: 0.12)

        XCTAssertEqual(fixture.publisher.attemptCount, 2)
        XCTAssertEqual(fixture.publisher.publishedIDs, [fixture.request.id])
        XCTAssertLessThan(fixture.publisher.attemptCount, 4)
    }

    func testPublishedValidationFailureNeedsAttentionBeforeCallbackOrDelete() async throws {
        let fixture = try CoordinatorFixture(manifestState: .published)
        fixture.publisher.validationError = .verificationMismatch
        fixture.coordinator.resume()
        await fixture.waitForIdle()

        XCTAssertTrue(fixture.completions.values.isEmpty)
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertEqual(fixture.coordinator.presentation.needsAttentionCount, 1)
    }

    func testLegacyPublishedItemMissingRootIdentityFailsClosedBeforeCallbackOrDelete() async throws {
        let fixture = try CoordinatorFixture(manifestState: .published)
        var item = try XCTUnwrap(fixture.persistedItems.first)
        item.publishedSourceRootDevice = nil
        try fixture.manifest.save([item])
        fixture.coordinator.resume()
        await fixture.waitForIdle()

        XCTAssertTrue(fixture.completions.values.isEmpty)
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertEqual(fixture.coordinator.presentation.needsAttentionCount, 1)
    }

    func testShutdownRejectsLatePublisherFailureWithoutTransition() async throws {
        let fixture = try CoordinatorFixture()
        fixture.publisher.suspendNextPublish = true
        fixture.coordinator.enqueue(fixture.request)
        await fixture.publisher.waitUntilSuspended()
        fixture.coordinator.shutdown()
        fixture.publisher.completeSuspendedPublish(throwing: .ioFailure("late"))
        await fixture.waitForIdle()

        XCTAssertTrue(fixture.completions.values.isEmpty)
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertEqual(fixture.coordinator.presentation.pendingCount, 1)
    }

    func testScriptedManifestPublishingTransitionSaveFailureStopsBeforePublisher() async throws {
        let fixture = try CoordinatorFixture()
        let store = ScriptedCoordinatorManifestStore(items: [], failingSaveCalls: [2])
        let coordinator = RecordingPublicationCoordinator(manifestStore: store, destinationStore: fixture.destination, publisher: fixture.publisher, pendingStore: fixture.pending, retryDelays: [1])

        coordinator.enqueue(fixture.request)
        await fixture.waitForIdle()

        XCTAssertEqual(store.saveCalls, 2)
        XCTAssertEqual(fixture.publisher.attemptCount, 0)
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertEqual(coordinator.presentation.stateText, "Publish failed")
    }

    func testPublishedRemovalPersistenceFailureStopsWithoutDuplicateCallbackAndRetryFinishes() async throws {
        let fixture = try CoordinatorFixture(manifestState: .published)
        let store = ScriptedCoordinatorManifestStore(items: fixture.persistedItems, failingSaveCalls: [1])
        let coordinator = RecordingPublicationCoordinator(manifestStore: store, destinationStore: fixture.destination, publisher: fixture.publisher, pendingStore: fixture.pending, retryDelays: [1])
        let completions = CompletionBox()
        coordinator.onCompleted = { completions.append($0) }

        coordinator.resume()
        await fixture.waitForIdle()

        XCTAssertEqual(completions.values.count, 1)
        XCTAssertEqual(fixture.destination.pruneCalls, 0)
        XCTAssertLessThanOrEqual(store.saveCalls, 1)
        XCTAssertEqual(coordinator.presentation.stateText, "Publish failed")

        store.failingSaveCalls = []
        coordinator.retryNow()
        await fixture.waitForIdle()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(completions.values.count, 1)
        XCTAssertEqual(fixture.destination.pruneCalls, 1)
    }

    func testFailedInitialLoadRemainsReloadableOnSecondResume() async throws {
        let fixture = try CoordinatorFixture(manifestState: .published)
        var item = try XCTUnwrap(fixture.persistedItems.first)
        item.state = .pending
        let store = ScriptedCoordinatorManifestStore(items: [item], failingLoads: 1)
        let coordinator = RecordingPublicationCoordinator(manifestStore: store, destinationStore: fixture.destination, publisher: fixture.publisher, pendingStore: fixture.pending, retryDelays: [1])

        coordinator.resume()
        XCTAssertEqual(coordinator.presentation.stateText, "Publish failed")
        coordinator.resume()
        await fixture.waitForIdle()

        XCTAssertEqual(store.loadCalls, 2)
        XCTAssertEqual(fixture.publisher.publishedIDs, [fixture.request.id])
    }
}

private final class FailingCoordinatorManifestStore: RecordingPublicationManifestStoring, @unchecked Sendable {
    func loadOrRebuild(from pendingStore: RecordingPendingStore) throws -> [RecordingPublicationItem] { [] }
    func save(_ items: [RecordingPublicationItem]) throws { throw RecordingPublicationManifestStoreError.writeFailed(EIO) }
}

private final class ScriptedCoordinatorManifestStore: RecordingPublicationManifestStoring, @unchecked Sendable {
    private let lock = NSLock()
    var items: [RecordingPublicationItem]
    var failingSaveCalls: Set<Int>
    private(set) var saveCalls = 0
    private(set) var loadCalls = 0
    private var failingLoads: Int

    init(items: [RecordingPublicationItem], failingSaveCalls: Set<Int> = [], failingLoads: Int = 0) {
        self.items = items; self.failingSaveCalls = failingSaveCalls; self.failingLoads = failingLoads
    }
    func loadOrRebuild(from pendingStore: RecordingPendingStore) throws -> [RecordingPublicationItem] {
        lock.lock(); defer { lock.unlock() }
        loadCalls += 1
        if failingLoads > 0 { failingLoads -= 1; throw RecordingPublicationManifestStoreError.readFailed(EIO) }
        return items
    }
    func save(_ items: [RecordingPublicationItem]) throws {
        lock.lock(); defer { lock.unlock() }
        saveCalls += 1
        if failingSaveCalls.contains(saveCalls) { throw RecordingPublicationManifestStoreError.writeFailed(EIO) }
        self.items = items
    }
}

@MainActor
private final class CoordinatorFixture {
    let temporaryRoot: URL
    let pending: RecordingPendingStore
    let manifest: RecordingPublicationManifestStore
    let destination = CoordinatorDestinationStore()
    let publisher: CoordinatorPublisher
    let request: RecordingPublicationRequest
    let completions = CompletionBox()
    let coordinator: RecordingPublicationCoordinator

    var destinationAvailable: Bool { get { destination.available } set { destination.available = newValue } }
    var sourceExists: Bool { FileManager.default.fileExists(atPath: pending.root.appendingPathComponent(request.sessionDirectoryName).path) }

    var persistedItems: [RecordingPublicationItem] { (try? manifest.loadOrRebuild(from: pending)) ?? [] }

    init(destinationAvailable: Bool = true, manifestState: RecordingPublicationState? = nil, publisherError: RecordingPublicationError? = nil, publisherErrors: [RecordingPublicationError] = [], retryDelays: [TimeInterval] = [0]) throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temporaryRoot.appendingPathComponent("pending", isDirectory: true)
        pending = RecordingPendingStore(root: root)
        try pending.prepareRoot()
        let name = "meeting"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        let identity = RecordingDestinationIdentity(id: UUID())
        request = .init(id: UUID(), sessionDirectoryName: name, destinationIdentity: identity, workspaceFence: .init(revision: 3), source: .manual, health: .init(), metadataWarning: nil)
        manifest = RecordingPublicationManifestStore(manifestURL: pending.manifestURL)
        destination.available = destinationAvailable
        destination.identity = identity
        destination.url = temporaryRoot.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.url, withIntermediateDirectories: true)
        publisher = CoordinatorPublisher(error: publisherError, errors: publisherErrors, destination: destination.url, pending: pending)
        if let manifestState {
            let session = try pending.openSession(for: name)
            try manifest.save([.init(id: request.id, sessionDirectoryName: name, destinationIdentity: identity, workspaceFenceRevision: 3, recordingSource: .manual, health: .init(), metadataWarning: nil, createdAt: Date(), lastAttemptAt: nil, attemptCount: 0, state: manifestState, failureCategory: nil, publishedFolderName: manifestState == .published ? "meeting" : nil, publishedRecordingName: manifestState == .published ? "recording.m4a" : nil, publishedSourceDevice: manifestState == .published ? session.identity.device : nil, publishedSourceInode: manifestState == .published ? session.identity.inode : nil, publishedSourceRootDevice: manifestState == .published ? session.rootIdentity.device : nil, publishedSourceRootInode: manifestState == .published ? session.rootIdentity.inode : nil)])
        } else {
            try manifest.save([])
        }
        coordinator = .init(manifestStore: manifest, destinationStore: destination, publisher: publisher, pendingStore: pending, retryDelays: retryDelays)
        coordinator.onCompleted = { [completions] completion in completions.append(completion) }
    }

    deinit { try? FileManager.default.removeItem(at: temporaryRoot) }

    func waitForIdle() async {
        for _ in 0..<30 { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func wait(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await waitForIdle()
    }
}

private final class CoordinatorDestinationStore: RecordingDestinationStoring, @unchecked Sendable {
    private let lock = NSLock()
    var identity: RecordingDestinationIdentity!
    var url: URL!
    var available = true
    var currentIdentity: RecordingDestinationIdentity? { identity }
    func restore(defaultURL: URL) -> RecordingDestinationSelection { .init(identity: identity, url: url, state: .ready) }
    func save(_ url: URL) throws { self.url = url }
    func access(identity: RecordingDestinationIdentity) throws -> RecordingDestinationAccess {
        lock.lock(); defer { lock.unlock() }
        guard available, identity == self.identity else { throw RecordingPublicationError.destinationUnavailable }
        return .init(url: url, close: {})
    }
    private(set) var pruneCalls = 0
    func prune(keeping identities: Set<RecordingDestinationIdentity>) { lock.lock(); pruneCalls += 1; lock.unlock() }
}

private final class CoordinatorPublisher: RecordingSessionPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private let error: RecordingPublicationError?
    private var errors: [RecordingPublicationError]
    private let destination: URL
    private let pending: RecordingPendingStore
    private(set) var publishedIDs: [UUID] = []
    private(set) var attemptCount = 0
    private(set) var validationIDs: [UUID] = []
    var beforeSuccess: (() -> Void)?
    var validationError: RecordingPublicationError?
    var suspendNextPublish = false
    private var suspendedContinuation: CheckedContinuation<RecordingPublicationSuccess, Error>?
    init(error: RecordingPublicationError?, errors: [RecordingPublicationError], destination: URL, pending: RecordingPendingStore) { self.error = error; self.errors = errors; self.destination = destination; self.pending = pending }
    func publish(item: RecordingPublicationItem, destination: RecordingDestinationAccess) async throws -> RecordingPublicationSuccess {
        withLock { attemptCount += 1 }
        if let error { throw error }
        if let error = withLockResult({ errors.isEmpty ? nil : errors.removeFirst() }) { throw error }
        let source = try pending.openSession(for: item.sessionDirectoryName)
        withLock { publishedIDs.append(item.id) }
        if suspendNextPublish {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock(); suspendedContinuation = continuation; lock.unlock()
            }
        }
        beforeSuccess?()
        let folder = self.destination.appendingPathComponent("meeting", isDirectory: true)
        return .init(itemID: item.id, folderURL: folder, recordingURL: folder.appendingPathComponent("recording.m4a"), sourceDevice: source.identity.device, sourceInode: source.identity.inode, sourceRootDevice: source.rootIdentity.device, sourceRootInode: source.rootIdentity.inode)
    }
    func waitUntilSuspended() async {
        for _ in 0..<100 where suspendedContinuation == nil { await Task.yield() }
    }
    func completeSuspendedPublish() {
        completeSuspendedPublish(throwing: nil)
    }
    func completeSuspendedPublish(throwing failure: RecordingPublicationError?) {
        lock.lock()
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        lock.unlock()
        guard let continuation else { return }
        if let failure { continuation.resume(throwing: failure); return }
        let folder = destination.appendingPathComponent("meeting", isDirectory: true)
        do {
            let source = try pending.openSession(for: "meeting")
            continuation.resume(returning: .init(itemID: publishedIDs.last!, folderURL: folder, recordingURL: folder.appendingPathComponent("recording.m4a"), sourceDevice: source.identity.device, sourceInode: source.identity.inode, sourceRootDevice: source.rootIdentity.device, sourceRootInode: source.rootIdentity.inode))
        } catch { continuation.resume(throwing: error) }
    }
    func validatePublished(item: RecordingPublicationItem, destination: RecordingDestinationAccess) async throws -> RecordingPublicationSuccess {
        withLock { validationIDs.append(item.id) }
        if let validationError { throw validationError }
        guard let device = item.publishedSourceDevice, let inode = item.publishedSourceInode,
              let rootDevice = item.publishedSourceRootDevice, let rootInode = item.publishedSourceRootInode,
              let folder = item.publishedFolderName, let recording = item.publishedRecordingName else { throw RecordingPublicationError.verificationMismatch }
        return .init(itemID: item.id, folderURL: destination.url.appendingPathComponent(folder), recordingURL: destination.url.appendingPathComponent(folder).appendingPathComponent(recording), sourceDevice: device, sourceInode: inode, sourceRootDevice: rootDevice, sourceRootInode: rootInode)
    }
    private func withLock(_ operation: () -> Void) { lock.lock(); defer { lock.unlock() }; operation() }
    private func withLockResult<T>(_ operation: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation() }
}

private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [RecordingPublicationCompleted] = []
    var values: [RecordingPublicationCompleted] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: RecordingPublicationCompleted) { lock.lock(); storage.append(value); lock.unlock() }
}
