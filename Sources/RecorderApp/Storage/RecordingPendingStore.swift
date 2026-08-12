import Darwin
import Foundation

enum RecordingPendingStoreError: Error, Equatable, Sendable {
    case rootIsNotDirectory
    case invalidSessionName
    case unsafeSession
}

struct RecordingPendingSessionIdentity: Equatable, Sendable {
    let device: Int64
    let inode: Int64
}

final class RecordingPendingSession: @unchecked Sendable {
    let fileDescriptor: Int32
    let identity: RecordingPendingSessionIdentity
    let directoryName: String
    let displayURL: URL

    init(fileDescriptor: Int32, identity: RecordingPendingSessionIdentity, directoryName: String, displayURL: URL) {
        self.fileDescriptor = fileDescriptor
        self.identity = identity
        self.directoryName = directoryName
        self.displayURL = displayURL
    }

    deinit { Darwin.close(fileDescriptor) }
}

struct RecordingPendingStore: Sendable {
    let root: URL
    let manifestURL: URL

    init(root: URL, manifestURL: URL? = nil) {
        self.root = root
        self.manifestURL = manifestURL ?? root.appendingPathComponent("publication-queue-v1.json")
    }

    func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordingPendingStoreError.rootIsNotDirectory }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// This is the security boundary for consumers of a pending session.
    /// The returned descriptor stays bound to the directory that was opened.
    func openSession(for directoryName: String) throws -> RecordingPendingSession {
        try prepareRoot()
        guard isSafeDirectoryName(directoryName) else { throw RecordingPendingStoreError.invalidSessionName }
        let rootDescriptor = try openRootDescriptor()
        defer { Darwin.close(rootDescriptor) }
        let descriptor = openat(rootDescriptor, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordingPendingStoreError.unsafeSession }
        do {
            let identity = try directoryIdentity(of: descriptor)
            return RecordingPendingSession(
                fileDescriptor: descriptor,
                identity: identity,
                directoryName: directoryName,
                displayURL: root.appendingPathComponent(directoryName, isDirectory: true)
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Compatibility display-path API. Use `openSession(for:)` for file operations.
    func sessionURL(for directoryName: String) throws -> URL {
        try openSession(for: directoryName).displayURL
    }

    func scanSessions() throws -> [URL] {
        try prepareRoot()
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return contents
            .filter { $0.lastPathComponent != manifestURL.lastPathComponent }
            .compactMap { url in try? openSession(for: url.lastPathComponent).displayURL }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func openRootDescriptor() throws -> Int32 {
        try prepareRoot()
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordingPendingStoreError.rootIsNotDirectory }
        return descriptor
    }

    private func isSafeDirectoryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".")
    }

    private func directoryIdentity(of descriptor: Int32) throws -> RecordingPendingSessionIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
            throw RecordingPendingStoreError.unsafeSession
        }
        return RecordingPendingSessionIdentity(device: Int64(value.st_dev), inode: Int64(value.st_ino))
    }
}
