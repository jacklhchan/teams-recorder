import Foundation

struct RecordingPublicationRequest: Equatable, Sendable {
    let id: UUID
    let sessionDirectoryName: String
    let destinationIdentity: RecordingDestinationIdentity
    let workspaceFence: WorkspacePublicationFence
    let source: RecordingSource
    let health: RecordingHealthReport
    let metadataWarning: String?
    let sourceIdentity: RecordingPendingSessionIdentity?
    let sourceRootIdentity: RecordingPendingSessionIdentity?

    init(id: UUID, sessionDirectoryName: String, destinationIdentity: RecordingDestinationIdentity, workspaceFence: WorkspacePublicationFence, source: RecordingSource, health: RecordingHealthReport, metadataWarning: String?, sourceIdentity: RecordingPendingSessionIdentity? = nil, sourceRootIdentity: RecordingPendingSessionIdentity? = nil) {
        self.id = id; self.sessionDirectoryName = sessionDirectoryName; self.destinationIdentity = destinationIdentity; self.workspaceFence = workspaceFence; self.source = source; self.health = health; self.metadataWarning = metadataWarning; self.sourceIdentity = sourceIdentity; self.sourceRootIdentity = sourceRootIdentity
    }
}

struct RecordingPublicationCompleted: Equatable, Sendable {
    let itemID: UUID
    let destinationIdentity: RecordingDestinationIdentity
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

@MainActor
protocol RecordingPublicationCoordinating: AnyObject {
    var presentation: RecordingPublicationPresentation { get }
    var onPresentationChange: ((RecordingPublicationPresentation) -> Void)? { get set }
    var onCompleted: ((RecordingPublicationCompleted) -> Void)? { get set }
    func enqueue(_ request: RecordingPublicationRequest)
    func resume()
    func retryNow()
    func shutdown()
}

@MainActor
final class RecordingPublicationCoordinator: RecordingPublicationCoordinating {
    private let manifestStore: any RecordingPublicationManifestStoring
    private let destinationStore: RecordingDestinationStoring
    private let publisher: RecordingSessionPublishing
    private let pendingStore: RecordingPendingStore
    private let retryDelays: [TimeInterval]
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private var items: [RecordingPublicationItem] = []
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var loaded = false
    private var persistenceFailed = false
    private var deliveredIDs = Set<UUID>()

    var onPresentationChange: ((RecordingPublicationPresentation) -> Void)?
    var onCompleted: ((RecordingPublicationCompleted) -> Void)?

    init(manifestStore: any RecordingPublicationManifestStoring, destinationStore: RecordingDestinationStoring, publisher: RecordingSessionPublishing, pendingStore: RecordingPendingStore, retryDelays: [TimeInterval] = [2, 10, 30, 60, 300], sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }) {
        self.manifestStore = manifestStore
        self.destinationStore = destinationStore
        self.publisher = publisher
        self.pendingStore = pendingStore
        self.retryDelays = retryDelays.filter { $0 > 0 }.isEmpty ? [1] : retryDelays.filter { $0 > 0 }
        self.sleeper = sleeper
    }

    var presentation: RecordingPublicationPresentation { presentation(for: items) }

    func enqueue(_ request: RecordingPublicationRequest) {
        guard loadIfNeeded(), !items.contains(where: { $0.id == request.id }) else { publishPresentation(); return }
        let item = RecordingPublicationItem(id: request.id, sessionDirectoryName: request.sessionDirectoryName, destinationIdentity: request.destinationIdentity, workspaceFenceRevision: request.workspaceFence.revision, recordingSource: request.source, health: request.health, metadataWarning: request.metadataWarning, sourceIdentity: request.sourceIdentity, sourceRootIdentity: request.sourceRootIdentity, createdAt: Date(), lastAttemptAt: nil, attemptCount: 0, state: .pending, failureCategory: nil)
        items.append(item)
        guard persist() else { items.removeLast(); publishPresentation(); return }
        publishPresentation(); startWorker()
    }

    func resume() { if loadIfNeeded() { startWorker() }; publishPresentation() }

    func retryNow() {
        guard loadIfNeeded() else { publishPresentation(); return }
        generation &+= 1; worker?.cancel(); worker = nil
        let old = items
        let retryable = items.filter { $0.state == .waitingForDestination || ($0.state == .pending && $0.failureCategory == "transient") || ($0.state == .published && $0.failureCategory == "destinationUnavailable") }
        let retained = items.filter { item in !retryable.contains(where: { $0.id == item.id }) }
        items = retryable + retained
        for index in items.indices where items[index].state == .waitingForDestination || (items[index].state == .pending && items[index].failureCategory == "transient") {
            items[index].state = .pending
            items[index].failureCategory = nil
            items[index].lastAttemptAt = nil
        }
        for index in items.indices where items[index].state == .published && items[index].failureCategory == "destinationUnavailable" {
            items[index].lastAttemptAt = nil
        }
        guard persist() else { items = old; publishPresentation(); return }
        publishPresentation(); startWorker()
    }

    func shutdown() { generation &+= 1; worker?.cancel(); worker = nil }

    private func startWorker() {
        guard worker == nil else { return }
        generation &+= 1
        let workerGeneration = generation
        worker = Task { [weak self] in await self?.drain(generation: workerGeneration) }
    }

    private func drain(generation workerGeneration: UInt64) async {
        defer { if generation == workerGeneration { worker = nil; publishPresentation() } }
        while current(workerGeneration) && !persistenceFailed {
            guard let item = nextEligibleItem() else {
                guard let delay = nextRetryDelay() else { return }
                do { try await sleeper(delay) } catch { return }
                continue
            }
            if item.state == .published { await finishPublished(item, generation: workerGeneration); continue }
            guard item.sourceIdentity != nil, item.sourceRootIdentity != nil else {
                _ = transition(item.id, to: .needsAttention, category: "missingSourceIdentity")
                continue
            }
            guard transitionToPublishing(item.id, generation: workerGeneration) else { return }
            do {
                let access: RecordingDestinationAccess
                do { access = try destinationStore.access(identity: item.destinationIdentity) }
                catch { guard transition(item.id, to: .waitingForDestination, category: "destinationUnavailable") else { return }; continue }
                defer { access.close() }
                let success = try await publisher.publish(item: item, destination: access)
                guard current(workerGeneration), simpleName(success.folderURL.lastPathComponent), simpleName(success.recordingURL.lastPathComponent) else { return }
                guard markPublished(item.id, success: success, generation: workerGeneration) else { return }
            } catch {
                guard current(workerGeneration), recordFailure(item.id, error: error) else { return }
            }
        }
    }

    private func finishPublished(_ item: RecordingPublicationItem, generation workerGeneration: UInt64) async {
        guard let folder = item.publishedFolderName, let recording = item.publishedRecordingName, simpleName(folder), simpleName(recording) else { _ = transition(item.id, to: .needsAttention, category: "unsafePublishedName"); return }
        do {
            let access: RecordingDestinationAccess
            do { access = try destinationStore.access(identity: item.destinationIdentity) }
            catch { guard current(workerGeneration) else { return }; _ = recordPublishedDestinationUnavailable(item.id); return }
            defer { access.close() }
            let validated = try await publisher.validatePublished(item: item, destination: access)
            guard current(workerGeneration), validated.itemID == item.id, validated.folderURL.lastPathComponent == folder, validated.recordingURL.lastPathComponent == recording else { return }
            guard let sourceDevice = item.publishedSourceDevice, let sourceInode = item.publishedSourceInode,
                  let rootDevice = item.publishedSourceRootDevice, let rootInode = item.publishedSourceRootInode else {
                _ = transition(item.id, to: .needsAttention, category: "missingSourceIdentity")
                return
            }
            if try !pendingStore.isSessionAbsent(named: item.sessionDirectoryName) {
                let session = try pendingStore.openSession(for: item.sessionDirectoryName)
                guard session.rootIdentity == .init(device: rootDevice, inode: rootInode),
                      session.identity == .init(device: sourceDevice, inode: sourceInode) else {
                    _ = transition(item.id, to: .needsAttention, category: "sourceReplacement")
                    return
                }
                try pendingStore.removeRetainedSession(session)
            }
            guard current(workerGeneration) else { return }
            let completed = RecordingPublicationCompleted(itemID: item.id, destinationIdentity: item.destinationIdentity, folderURL: validated.folderURL, recordingURL: validated.folderURL.appendingPathComponent(recording).standardizedFileURL, workspaceFence: .init(revision: item.workspaceFenceRevision), source: item.recordingSource, health: item.health, metadataWarning: item.metadataWarning)
            if deliveredIDs.insert(item.id).inserted { onCompleted?(completed) }
            guard current(workerGeneration) else { return }
            let old = items; items.removeAll { $0.id == item.id }
            guard persist() else { items = old; return }
            destinationStore.prune(keeping: Set(items.map(\.destinationIdentity))); publishPresentation()
        } catch {
            guard current(workerGeneration) else { return }
            if case RecordingPublicationError.destinationUnavailable = error {
                _ = recordPublishedDestinationUnavailable(item.id)
            } else {
                _ = recordFailure(item.id, error: error)
            }
        }
    }

    private func transitionToPublishing(_ id: UUID, generation: UInt64) -> Bool {
        guard current(generation), let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let old = items[index]; items[index].state = .publishing; items[index].lastAttemptAt = Date(); items[index].attemptCount += 1
        guard persist() else { items[index] = old; return false }; publishPresentation(); return true
    }
    private func markPublished(_ id: UUID, success: RecordingPublicationSuccess, generation: UInt64) -> Bool {
        guard current(generation), let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let old = items[index]; items[index].state = .published; items[index].failureCategory = nil; items[index].publishedFolderName = success.folderURL.lastPathComponent; items[index].publishedRecordingName = success.recordingURL.lastPathComponent; items[index].publishedSourceDevice = success.sourceDevice; items[index].publishedSourceInode = success.sourceInode; items[index].publishedSourceRootDevice = success.sourceRootDevice; items[index].publishedSourceRootInode = success.sourceRootInode
        guard persist() else { items[index] = old; return false }; return true
    }
    private func transition(_ id: UUID, to state: RecordingPublicationState, category: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }; let old = items[index]; items[index].state = state; items[index].failureCategory = category
        guard persist() else { items[index] = old; return false }; publishPresentation(); return true
    }
    private func recordFailure(_ id: UUID, error: Error) -> Bool {
        let publicationError = error as? RecordingPublicationError
        switch publicationError {
        case .some(.destinationUnavailable): return transition(id, to: .waitingForDestination, category: "destinationUnavailable")
        case .some(.invalidSource), .some(.unsafeEntry), .some(.invalidMedia), .some(.verificationMismatch): return transition(id, to: .needsAttention, category: "invalidSource")
        case .some(.destinationCollision): return transition(id, to: .needsAttention, category: "destinationCollision")
        default: return transition(id, to: .pending, category: "transient")
        }
    }
    private func recordPublishedDestinationUnavailable(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let old = items[index]
        items[index].state = .published
        items[index].failureCategory = "destinationUnavailable"
        items[index].lastAttemptAt = Date()
        items[index].attemptCount += 1
        guard persist() else { items[index] = old; return false }
        publishPresentation()
        return true
    }
    private func nextEligibleItem() -> RecordingPublicationItem? {
        let now = Date()
        return items.first { item in
            guard item.state == .pending || item.state == .published else { return false }
            guard item.state == .pending || item.failureCategory == "destinationUnavailable" else { return true }
            return isEligible(item, now: now)
        }
    }
    private func nextRetryDelay() -> TimeInterval? {
        let now = Date()
        let deadlines = items.compactMap { item -> TimeInterval? in
            guard (item.state == .pending && item.failureCategory == "transient") || (item.state == .published && item.failureCategory == "destinationUnavailable"), let last = item.lastAttemptAt else { return nil }
            return max(0, retryDelay(for: item) - now.timeIntervalSince(last))
        }
        return deadlines.min()
    }
    private func isEligible(_ item: RecordingPublicationItem, now: Date) -> Bool { guard let last = item.lastAttemptAt else { return true }; return now.timeIntervalSince(last) >= retryDelay(for: item) }
    private func retryDelay(for item: RecordingPublicationItem) -> TimeInterval { retryDelays[min(max(item.attemptCount - 1, 0), retryDelays.count - 1)] }
    private func loadIfNeeded() -> Bool { guard !loaded else { return true }; do { items = try manifestStore.loadOrRebuild(from: pendingStore); loaded = true; persistenceFailed = false; return true } catch { persistenceFailed = true; return false } }
    private func persist() -> Bool { do { try manifestStore.save(items); persistenceFailed = false; return true } catch { persistenceFailed = true; return false } }
    private func current(_ candidate: UInt64) -> Bool { generation == candidate && !Task.isCancelled }
    private func presentation(for items: [RecordingPublicationItem]) -> RecordingPublicationPresentation { let pending = items.filter { $0.state == .pending || $0.state == .publishing || ($0.state == .published && $0.failureCategory != "destinationUnavailable") }.count; let waiting = items.filter { $0.state == .waitingForDestination || ($0.state == .published && $0.failureCategory == "destinationUnavailable") }.count; let attention = items.filter { $0.state == .needsAttention }.count; let text = persistenceFailed ? "Publish failed" : attention > 0 ? "Needs attention" : waiting > 0 ? "Waiting for destination" : pending > 0 ? "Publishing" : "Up to date"; return .init(stateText: text, pendingCount: pending, waitingCount: waiting, needsAttentionCount: attention) }
    private func publishPresentation() { onPresentationChange?(presentation) }
    private func simpleName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") }
}
