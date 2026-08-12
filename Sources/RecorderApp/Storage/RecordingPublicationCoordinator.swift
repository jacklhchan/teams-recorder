import Foundation

struct RecordingPublicationRequest: Equatable, Sendable {
    let id: UUID
    let sessionDirectoryName: String
    let destinationIdentity: RecordingDestinationIdentity
    let workspaceFence: WorkspacePublicationFence
    let source: RecordingSource
    let health: RecordingHealthReport
    let metadataWarning: String?
}

struct RecordingPublicationCompleted: Equatable, Sendable {
    let itemID: UUID
    let folderURL: URL
    let recordingURL: URL
    let workspaceFence: WorkspacePublicationFence
    let source: RecordingSource
    let health: RecordingHealthReport
    let metadataWarning: String?
}

struct RecordingPublicationPresentation: Equatable, Sendable {
    let stateText: String
    let pendingCount: Int
    let waitingCount: Int
    let needsAttentionCount: Int
    var retainedLocalCount: Int { pendingCount + waitingCount + needsAttentionCount }
}

protocol RecordingPublicationCoordinating: AnyObject {
    var presentation: RecordingPublicationPresentation { get }
    var onPresentationChange: (@MainActor (RecordingPublicationPresentation) -> Void)? { get set }
    var onCompleted: (@MainActor (RecordingPublicationCompleted) -> Void)? { get set }
    func enqueue(_ request: RecordingPublicationRequest)
    func resume()
    func retryNow()
    func shutdown()
}

final class RecordingPublicationCoordinator: RecordingPublicationCoordinating, @unchecked Sendable {
    private let manifestStore: RecordingPublicationManifestStore
    private let destinationStore: RecordingDestinationStoring
    private let publisher: RecordingSessionPublishing
    private let pendingStore: RecordingPendingStore
    private let retryDelays: [TimeInterval]
    private let lock = NSLock()
    private var items: [RecordingPublicationItem] = []
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var loaded = false
    private var persistenceFailed = false

    var onPresentationChange: (@MainActor (RecordingPublicationPresentation) -> Void)?
    var onCompleted: (@MainActor (RecordingPublicationCompleted) -> Void)?

    init(
        manifestStore: RecordingPublicationManifestStore,
        destinationStore: RecordingDestinationStoring,
        publisher: RecordingSessionPublishing,
        pendingStore: RecordingPendingStore,
        retryDelays: [TimeInterval] = [2, 10, 30, 60, 300]
    ) {
        self.manifestStore = manifestStore
        self.destinationStore = destinationStore
        self.publisher = publisher
        self.pendingStore = pendingStore
        self.retryDelays = retryDelays.isEmpty ? [0] : retryDelays
    }

    var presentation: RecordingPublicationPresentation { lock.withLock { presentation(for: items) } }

    func enqueue(_ request: RecordingPublicationRequest) {
        lock.withLock {
            loadIfNeededLocked()
            guard !items.contains(where: { $0.id == request.id }) else { return }
            items.append(RecordingPublicationItem(
                id: request.id, sessionDirectoryName: request.sessionDirectoryName,
                destinationIdentity: request.destinationIdentity, workspaceFenceRevision: request.workspaceFence.revision,
                recordingSource: request.source, health: request.health, metadataWarning: request.metadataWarning,
                createdAt: Date(), lastAttemptAt: nil, attemptCount: 0, state: .pending, failureCategory: nil
            ))
            guard persistLocked() else { items.removeLast(); return }
        }
        publishPresentation()
        startWorker()
    }

    func resume() {
        lock.withLock { loadIfNeededLocked() }
        publishPresentation()
        startWorker()
    }

    func retryNow() {
        lock.withLock {
            loadIfNeededLocked()
            for index in items.indices where items[index].state == .waitingForDestination || items[index].state == .pending {
                items[index].state = .pending
                items[index].lastAttemptAt = nil
            }
            _ = persistLocked()
        }
        publishPresentation()
        startWorker()
    }

    func shutdown() {
        lock.withLock {
            generation &+= 1
            worker?.cancel()
            worker = nil
        }
    }

    private func startWorker() {
        let start: UInt64? = lock.withLock {
            guard worker == nil else { return nil }
            generation &+= 1
            let current = generation
            worker = Task { [weak self] in await self?.drain(generation: current) }
            return current
        }
        _ = start
    }

    private func drain(generation workerGeneration: UInt64) async {
        while !Task.isCancelled {
            guard let item = lock.withLock({ nextEligibleItemLocked() }) else {
                guard let delay = lock.withLock({ nextRetryDelayLocked() }) else { break }
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                continue
            }
            if item.state == .published {
                await finishPublished(item, generation: workerGeneration)
                continue
            }
            lock.withLock {
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                items[index].state = .publishing
                items[index].lastAttemptAt = Date()
                items[index].attemptCount += 1
                guard persistLocked() else { return }
            }
            publishPresentation()
            do {
                let access: RecordingDestinationAccess
                do { access = try destinationStore.access(identity: item.destinationIdentity) }
                catch { recordWaiting(item.id); continue }
                defer { access.close() }
                let success = try await publisher.publish(item: item, destination: access)
                guard isCurrent(workerGeneration) else { return }
                guard simpleName(success.folderURL.lastPathComponent), simpleName(success.recordingURL.lastPathComponent) else {
                    markNeedsAttention(item.id, category: "unsafePublishedName")
                    continue
                }
                let saved = lock.withLock { () -> RecordingPublicationItem? in
                    guard generation == workerGeneration, let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
                    items[index].state = .published
                    items[index].failureCategory = nil
                    items[index].publishedFolderName = success.folderURL.lastPathComponent
                    items[index].publishedRecordingName = success.recordingURL.lastPathComponent
                    items[index].publishedSourceDevice = success.sourceDevice
                    items[index].publishedSourceInode = success.sourceInode
                    guard persistLocked() else { return nil }
                    return items[index]
                }
                guard let saved else { return }
                await finishPublished(saved, generation: workerGeneration)
            } catch {
                guard isCurrent(workerGeneration) else { return }
                recordFailure(item.id, error: error)
            }
        }
        lock.withLock {
            if generation == workerGeneration { worker = nil }
        }
        publishPresentation()
    }

    private func finishPublished(_ item: RecordingPublicationItem, generation workerGeneration: UInt64) async {
        guard let folderName = item.publishedFolderName, let recordingName = item.publishedRecordingName,
              simpleName(folderName), simpleName(recordingName) else {
            markNeedsAttention(item.id, category: "unsafePublishedName")
            return
        }
        do {
            let access: RecordingDestinationAccess
            do { access = try destinationStore.access(identity: item.destinationIdentity) }
            catch { recordPublishedWaiting(item.id); return }
            defer { access.close() }
            let validated = try await publisher.validatePublished(item: item, destination: access)
            guard isCurrent(workerGeneration) else { return }
            guard validated.itemID == item.id,
                  validated.folderURL.lastPathComponent == folderName,
                  validated.recordingURL.lastPathComponent == recordingName else {
                throw RecordingPublicationError.verificationMismatch
            }
            let folder = validated.folderURL
            let completed = RecordingPublicationCompleted(
                itemID: item.id, folderURL: folder, recordingURL: folder.appendingPathComponent(recordingName).standardizedFileURL,
                workspaceFence: .init(revision: item.workspaceFenceRevision), source: item.recordingSource,
                health: item.health, metadataWarning: item.metadataWarning
            )
            guard isCurrent(workerGeneration) else { return }
            if let callback = onCompleted { await callback(completed) }
            guard isCurrent(workerGeneration) else { return }
            guard let sourceDevice = item.publishedSourceDevice, let sourceInode = item.publishedSourceInode else {
                markNeedsAttention(item.id, category: "missingSourceIdentity")
                return
            }
            if try !pendingStore.isSessionAbsent(named: item.sessionDirectoryName) {
                let session = try pendingStore.openSession(for: item.sessionDirectoryName)
                guard session.identity == .init(device: sourceDevice, inode: sourceInode) else {
                    markNeedsAttention(item.id, category: "sourceReplacement")
                    return
                }
                try pendingStore.removeRetainedSession(session)
            }
            guard isCurrent(workerGeneration) else { return }
            lock.withLock {
                guard generation == workerGeneration else { return }
                let prior = items
                items.removeAll { $0.id == item.id }
                guard persistLocked() else { items = prior; return }
                destinationStore.prune(keeping: Set(items.map(\.destinationIdentity)))
            }
            publishPresentation()
        } catch {
            recordFailure(item.id, error: error)
        }
    }

    private func recordFailure(_ id: UUID, error: Error) {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            guard let publicationError = error as? RecordingPublicationError else {
                items[index].state = .pending
                items[index].failureCategory = "transient"
                _ = persistLocked()
                return
            }
            switch publicationError {
            case .destinationUnavailable:
                items[index].state = .waitingForDestination
                items[index].failureCategory = "destinationUnavailable"
            case .invalidSource, .unsafeEntry, .invalidMedia, .verificationMismatch:
                items[index].state = .needsAttention
                items[index].failureCategory = "invalidSource"
            case .destinationCollision:
                items[index].state = .needsAttention
                items[index].failureCategory = "destinationCollision"
            case .ioFailure:
                items[index].state = .pending
                items[index].failureCategory = "transient"
            }
            _ = persistLocked()
        }
        publishPresentation()
    }

    private func markNeedsAttention(_ id: UUID, category: String) {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].state = .needsAttention
            items[index].failureCategory = category
            _ = persistLocked()
        }
        publishPresentation()
    }

    private func nextEligibleItemLocked() -> RecordingPublicationItem? {
        if let published = items.first(where: { $0.state == .published }) { return published }
        let now = Date()
        return items.first { item in
            guard item.state == .pending else { return false }
            guard let last = item.lastAttemptAt else { return true }
            let delay = retryDelays[min(max(item.attemptCount - 1, 0), retryDelays.count - 1)]
            return now.timeIntervalSince(last) >= delay
        }
    }

    private func nextRetryDelayLocked() -> TimeInterval? {
        let now = Date()
        let delays = items.compactMap { item -> TimeInterval? in
            guard item.state == .pending, let last = item.lastAttemptAt else { return nil }
            let delay = retryDelays[min(max(item.attemptCount - 1, 0), retryDelays.count - 1)]
            return max(0, delay - now.timeIntervalSince(last))
        }
        return delays.min()
    }

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        do { items = try manifestStore.loadOrRebuild(from: pendingStore) }
        catch { items = []; persistenceFailed = true }
        loaded = true
    }

    @discardableResult private func persistLocked() -> Bool {
        do { try manifestStore.save(items); persistenceFailed = false; return true }
        catch { persistenceFailed = true; return false }
    }
    private func recordWaiting(_ id: UUID) {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].state = .waitingForDestination
            items[index].failureCategory = "destinationUnavailable"
            _ = persistLocked()
        }
        publishPresentation()
    }
    private func recordPublishedWaiting(_ id: UUID) {
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].failureCategory = "destinationUnavailable"
            _ = persistLocked()
        }
        publishPresentation()
    }
    private func isCurrent(_ candidate: UInt64) -> Bool { lock.withLock { generation == candidate && !Task.isCancelled } }
    private func presentation(for items: [RecordingPublicationItem]) -> RecordingPublicationPresentation {
        let pending = items.filter { $0.state == .pending || $0.state == .publishing }.count
        let waiting = items.filter { $0.state == .waitingForDestination }.count
        let attention = items.filter { $0.state == .needsAttention }.count
        let text = attention > 0 ? "Needs attention" : waiting > 0 ? "Waiting for destination" : pending > 0 ? "Publishing" : "Up to date"
        return .init(stateText: text, pendingCount: pending, waitingCount: waiting, needsAttentionCount: attention)
    }
    private func publishPresentation() {
        let value = presentation
        if let callback = onPresentationChange { Task { @MainActor in callback(value) } }
    }
    private func simpleName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".")
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T { lock(); defer { unlock() }; return operation() }
}
