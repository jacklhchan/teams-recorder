import Darwin
import Foundation

enum RecordingPublicationState: String, Codable, Equatable, Sendable {
    case pending, publishing, waitingForDestination, needsAttention
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

enum RecordingPublicationManifestStoreError: Error, Equatable, Sendable {
    case unsafeManifest
    case readFailed(Int32)
    case writeFailed(Int32)
}

struct RecordingPublicationManifestStore: Sendable {
    private static let version = 1
    private static let fileName = "publication-queue-v1.json"
    let manifestURL: URL
    private let pendingStore: RecordingPendingStore

    init(manifestURL: URL) {
        self.manifestURL = manifestURL
        self.pendingStore = RecordingPendingStore(root: manifestURL.deletingLastPathComponent(), manifestURL: manifestURL)
    }

    func save(_ items: [RecordingPublicationItem]) throws {
        try validateManifestName()
        let descriptor = try pendingStore.openRootDescriptor()
        defer { Darwin.close(descriptor) }
        try writeAtomically(JSONEncoder().encode(RecordingPublicationManifest(version: Self.version, items: items)), relativeTo: descriptor)
    }

    func loadOrRebuild(from pendingStore: RecordingPendingStore) throws -> [RecordingPublicationItem] {
        try validateManifestName()
        guard pendingStore.root.standardizedFileURL == self.pendingStore.root.standardizedFileURL else {
            throw RecordingPublicationManifestStoreError.unsafeManifest
        }
        let descriptor = try pendingStore.openRootDescriptor()
        defer { Darwin.close(descriptor) }
        do {
            guard let data = try readValidatedManifest(relativeTo: descriptor) else {
                return try rebuild(from: pendingStore, persistRelativeTo: descriptor)
            }
            guard var manifest = try? JSONDecoder().decode(RecordingPublicationManifest.self, from: data), manifest.version == Self.version else {
                return try rebuild(from: pendingStore, persistRelativeTo: descriptor)
            }
            if manifest.items.indices.contains(where: { manifest.items[$0].state == .publishing }) {
                for index in manifest.items.indices where manifest.items[index].state == .publishing { manifest.items[index].state = .pending }
                try writeAtomically(JSONEncoder().encode(RecordingPublicationManifest(version: Self.version, items: manifest.items)), relativeTo: descriptor)
            }
            return manifest.items
        } catch RecordingPublicationManifestStoreError.unsafeManifest {
            // Never replace or follow an unsafe entry; recover only in memory.
            return try rebuild(from: pendingStore, persistRelativeTo: nil)
        }
    }

    private func rebuild(from pendingStore: RecordingPendingStore, persistRelativeTo descriptor: Int32?) throws -> [RecordingPublicationItem] {
        let items = try pendingStore.scanSessionNames().map { name in
            RecordingPublicationItem(id: UUID(), sessionDirectoryName: name, destinationIdentity: RecordingDestinationIdentity(id: UUID()), workspaceFenceRevision: WorkspacePublicationFence.initial.revision, recordingSource: .manual, health: RecordingHealthReport(), metadataWarning: nil, createdAt: Date(), lastAttemptAt: nil, attemptCount: 0, state: .needsAttention, failureCategory: "manifestRecovery")
        }
        if let descriptor { try writeAtomically(JSONEncoder().encode(RecordingPublicationManifest(version: Self.version, items: items)), relativeTo: descriptor) }
        return items
    }

    private func validateManifestName() throws {
        guard manifestURL.lastPathComponent == Self.fileName else { throw RecordingPublicationManifestStoreError.unsafeManifest }
    }

    private func readValidatedManifest(relativeTo directory: Int32) throws -> Data? {
        var attributes = stat()
        guard fstatat(directory, Self.fileName, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw RecordingPublicationManifestStoreError.readFailed(errno)
        }
        guard (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_uid == getuid(),
              (attributes.st_mode & 0o077) == 0 else { throw RecordingPublicationManifestStoreError.unsafeManifest }
        let descriptor = openat(directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordingPublicationManifestStoreError.readFailed(errno) }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == getuid(),
              (opened.st_mode & 0o077) == 0 else { throw RecordingPublicationManifestStoreError.unsafeManifest }
        return try readAll(from: descriptor)
    }

    private func writeAtomically(_ data: Data, relativeTo directory: Int32) throws {
        let name = ".publication-queue-v1-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RecordingPublicationManifestStoreError.writeFailed(errno) }
        defer { Darwin.close(descriptor); _ = unlinkat(directory, name, 0) }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw RecordingPublicationManifestStoreError.writeFailed(errno) }
        try validateExistingManifestForReplacement(relativeTo: directory)
        guard renameat(directory, name, directory, Self.fileName) == 0 else { throw RecordingPublicationManifestStoreError.writeFailed(errno) }
        guard fsync(directory) == 0 else { throw RecordingPublicationManifestStoreError.writeFailed(errno) }
    }

    private func validateExistingManifestForReplacement(relativeTo directory: Int32) throws {
        var attributes = stat()
        guard fstatat(directory, Self.fileName, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw RecordingPublicationManifestStoreError.writeFailed(errno)
        }
        guard (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_uid == getuid(),
              (attributes.st_mode & 0o777) == 0o600 else {
            throw RecordingPublicationManifestStoreError.unsafeManifest
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 { throw RecordingPublicationManifestStoreError.readFailed(errno) }
            if count == 0 { return data }
            data.append(bytes, count: Int(count))
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count <= 0 { throw RecordingPublicationManifestStoreError.writeFailed(errno) }
                offset += Int(count)
            }
        }
    }
}
