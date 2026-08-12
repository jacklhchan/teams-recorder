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
    let rootFileDescriptor: Int32
    let rootIdentity: RecordingPendingSessionIdentity
    let identity: RecordingPendingSessionIdentity
    let directoryName: String
    let displayURL: URL

    init(fileDescriptor: Int32, rootFileDescriptor: Int32, rootIdentity: RecordingPendingSessionIdentity, identity: RecordingPendingSessionIdentity, directoryName: String, displayURL: URL) {
        self.fileDescriptor = fileDescriptor
        self.rootFileDescriptor = rootFileDescriptor
        self.rootIdentity = rootIdentity
        self.identity = identity
        self.directoryName = directoryName
        self.displayURL = displayURL
    }

    deinit { Darwin.close(fileDescriptor); Darwin.close(rootFileDescriptor) }
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
        let rootIdentity = try directoryIdentity(of: rootDescriptor)
        let descriptor = openat(rootDescriptor, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordingPendingStoreError.unsafeSession }
        do {
            let identity = try directoryIdentity(of: descriptor)
            return RecordingPendingSession(
                fileDescriptor: descriptor,
                rootFileDescriptor: rootDescriptor,
                rootIdentity: rootIdentity,
                identity: identity,
                directoryName: directoryName,
                displayURL: root.appendingPathComponent(directoryName, isDirectory: true)
            )
        } catch {
            Darwin.close(descriptor)
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    func scanSessionNames() throws -> [String] {
        try prepareRoot()
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return contents
            .filter { $0.lastPathComponent != manifestURL.lastPathComponent }
            .compactMap { url in
                let name = url.lastPathComponent
                return (try? openSession(for: name)) == nil ? nil : name
            }
            .sorted()
    }

    func openRootDescriptor() throws -> Int32 {
        try prepareRoot()
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordingPendingStoreError.rootIsNotDirectory }
        return descriptor
    }

    /// Removes only the exact direct child represented by an already-open handle.
    /// URL paths are intentionally not accepted as deletion authority.
    func removeRetainedSession(_ session: RecordingPendingSession) throws {
        let rootDescriptor = session.rootFileDescriptor
        guard try directoryIdentity(of: rootDescriptor) == session.rootIdentity else {
            throw RecordingPendingStoreError.unsafeSession
        }
        var rootEntry = stat()
        guard fstatat(rootDescriptor, session.directoryName, &rootEntry, AT_SYMLINK_NOFOLLOW) == 0,
              matches(rootEntry, session.identity),
              (rootEntry.st_mode & S_IFMT) == S_IFDIR else {
            throw RecordingPendingStoreError.unsafeSession
        }
        try validateTree(directory: session.fileDescriptor)
        try removeTree(directory: session.fileDescriptor)
        var current = stat()
        guard fstatat(rootDescriptor, session.directoryName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              matches(current, session.identity),
              unlinkat(rootDescriptor, session.directoryName, AT_REMOVEDIR) == 0 else {
            throw RecordingPendingStoreError.unsafeSession
        }
    }

    func isSessionAbsent(named directoryName: String) throws -> Bool {
        guard isSafeDirectoryName(directoryName) else { throw RecordingPendingStoreError.invalidSessionName }
        let rootDescriptor = try openRootDescriptor()
        defer { Darwin.close(rootDescriptor) }
        var value = stat()
        guard fstatat(rootDescriptor, directoryName, &value, AT_SYMLINK_NOFOLLOW) != 0 else { return false }
        if errno == ENOENT { return true }
        throw RecordingPendingStoreError.unsafeSession
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

    private func matches(_ value: stat, _ identity: RecordingPendingSessionIdentity) -> Bool {
        Int64(value.st_dev) == identity.device && Int64(value.st_ino) == identity.inode
    }

    private func validateTree(directory: Int32) throws {
        for name in try entryNames(in: directory) {
            var observed = stat()
            guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw RecordingPendingStoreError.unsafeSession
            }
            switch observed.st_mode & S_IFMT {
            case S_IFREG:
                let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw RecordingPendingStoreError.unsafeSession }
                defer { Darwin.close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, sameEntry(observed, opened) else {
                    throw RecordingPendingStoreError.unsafeSession
                }
            case S_IFDIR:
                let descriptor = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw RecordingPendingStoreError.unsafeSession }
                defer { Darwin.close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, sameEntry(observed, opened) else {
                    throw RecordingPendingStoreError.unsafeSession
                }
                try validateTree(directory: descriptor)
            default:
                throw RecordingPendingStoreError.unsafeSession
            }
        }
    }

    private func removeTree(directory: Int32) throws {
        for name in try entryNames(in: directory) {
            var observed = stat()
            guard fstatat(directory, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw RecordingPendingStoreError.unsafeSession
            }
            switch observed.st_mode & S_IFMT {
            case S_IFREG:
                var current = stat()
                guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      sameEntry(current, observed), unlinkat(directory, name, 0) == 0 else {
                    throw RecordingPendingStoreError.unsafeSession
                }
            case S_IFDIR:
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw RecordingPendingStoreError.unsafeSession }
                defer { Darwin.close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, sameEntry(observed, opened) else {
                    throw RecordingPendingStoreError.unsafeSession
                }
                try removeTree(directory: child)
                var current = stat()
                guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      sameEntry(current, opened), unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
                    throw RecordingPendingStoreError.unsafeSession
                }
            default:
                throw RecordingPendingStoreError.unsafeSession
            }
        }
    }

    private func entryNames(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw RecordingPendingStoreError.unsafeSession
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private func sameEntry(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }
}
