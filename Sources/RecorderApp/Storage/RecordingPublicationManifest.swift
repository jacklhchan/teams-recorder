import Darwin
import Foundation

enum RecordingPublicationState: String, Codable, Equatable, Sendable {
    case pending
    case publishing
    case waitingForDestination
    case needsAttention
}

struct RecordingPublicationItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionDirectoryName: String
    let destinationIdentity: RecordingDestinationIdentity
    let workspaceFenceRevision: UInt64
    let recordingSource: RecordingSource
    let health: RecordingHealthReport
    let metadataWarning: String?
    let createdAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var state: RecordingPublicationState
    var failureCategory: String?
}

struct RecordingPublicationManifest: Codable, Equatable, Sendable {
    let version: Int
    var items: [RecordingPublicationItem]
}

struct RecordingPublicationManifestStore: Sendable {
    private static let version = 1
    let manifestURL: URL

    init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    func save(_ items: [RecordingPublicationItem]) throws {
        let manifest = RecordingPublicationManifest(version: Self.version, items: items)
        try writeAtomically(JSONEncoder().encode(manifest))
    }

    func loadOrRebuild(from pendingStore: RecordingPendingStore) throws -> [RecordingPublicationItem] {
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(RecordingPublicationManifest.self, from: data),
              manifest.version == Self.version else {
            return try rebuild(from: pendingStore)
        }
        var didResetPublishing = false
        for index in manifest.items.indices where manifest.items[index].state == .publishing {
            manifest.items[index].state = .pending
            didResetPublishing = true
        }
        if didResetPublishing {
            try save(manifest.items)
        }
        return manifest.items
    }

    private func rebuild(from pendingStore: RecordingPendingStore) throws -> [RecordingPublicationItem] {
        try pendingStore.scanSessions().map { session in
            RecordingPublicationItem(
                id: UUID(),
                sessionDirectoryName: session.lastPathComponent,
                destinationIdentity: RecordingDestinationIdentity(id: UUID()),
                workspaceFenceRevision: WorkspacePublicationFence.initial.revision,
                recordingSource: .manual,
                health: RecordingHealthReport(),
                metadataWarning: nil,
                createdAt: Date(),
                lastAttemptAt: nil,
                attemptCount: 0,
                state: .needsAttention,
                failureCategory: "manifestRecovery"
            )
        }
    }

    private func writeAtomically(_ data: Data) throws {
        let directory = manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporaryURL = directory.appendingPathComponent(".publication-queue-v1-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer {
            close(descriptor)
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        let count = try data.withUnsafeBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            let written = Darwin.write(descriptor, baseAddress, buffer.count)
            guard written == buffer.count else { throw CocoaError(.fileWriteUnknown) }
            return written
        }
        guard count == data.count, fsync(descriptor) == 0, rename(temporaryURL.path, manifestURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
