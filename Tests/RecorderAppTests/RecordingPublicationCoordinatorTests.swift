import Foundation
import XCTest
@testable import RecorderApp

final class RecordingPublicationCoordinatorTests: XCTestCase {
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
}

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

    init(destinationAvailable: Bool = true, manifestState: RecordingPublicationState? = nil, publisherError: RecordingPublicationError? = nil) throws {
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
        publisher = CoordinatorPublisher(error: publisherError, destination: destination.url)
        if let manifestState {
            try manifest.save([.init(id: request.id, sessionDirectoryName: name, destinationIdentity: identity, workspaceFenceRevision: 3, recordingSource: .manual, health: .init(), metadataWarning: nil, createdAt: Date(), lastAttemptAt: nil, attemptCount: 0, state: manifestState, failureCategory: nil, publishedFolderName: manifestState == .published ? "meeting" : nil, publishedRecordingName: manifestState == .published ? "recording.m4a" : nil)])
        } else {
            try manifest.save([])
        }
        coordinator = .init(manifestStore: manifest, destinationStore: destination, publisher: publisher, pendingStore: pending, retryDelays: [0])
        coordinator.onCompleted = { [completions] completion in completions.append(completion) }
    }

    deinit { try? FileManager.default.removeItem(at: temporaryRoot) }

    func waitForIdle() async {
        for _ in 0..<30 { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
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
    func prune(keeping identities: Set<RecordingDestinationIdentity>) {}
}

private final class CoordinatorPublisher: RecordingSessionPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private let error: RecordingPublicationError?
    private let destination: URL
    private(set) var publishedIDs: [UUID] = []
    private(set) var attemptCount = 0
    var beforeSuccess: (() -> Void)?
    init(error: RecordingPublicationError?, destination: URL) { self.error = error; self.destination = destination }
    func publish(item: RecordingPublicationItem, destination: RecordingDestinationAccess) async throws -> RecordingPublicationSuccess {
        withLock { attemptCount += 1 }
        if let error { throw error }
        withLock { publishedIDs.append(item.id) }
        beforeSuccess?()
        let folder = self.destination.appendingPathComponent("meeting", isDirectory: true)
        return .init(itemID: item.id, folderURL: folder, recordingURL: folder.appendingPathComponent("recording.m4a"))
    }
    private func withLock(_ operation: () -> Void) { lock.lock(); defer { lock.unlock() }; operation() }
}

private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [RecordingPublicationCompleted] = []
    var values: [RecordingPublicationCompleted] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: RecordingPublicationCompleted) { lock.lock(); storage.append(value); lock.unlock() }
}
