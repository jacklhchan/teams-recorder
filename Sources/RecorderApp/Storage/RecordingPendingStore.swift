import Darwin
import Foundation

enum RecordingPendingStoreError: Error, Equatable, Sendable {
    case rootIsNotDirectory
    case invalidSessionName
    case unsafeSession
}

struct RecordingPendingSessionIdentity: Codable, Equatable, Sendable {
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
    struct Hooks: Sendable {
        var afterCreateObservation: (@Sendable (Int32, String) -> Void)? = nil
        var beforeMetadataRename: (@Sendable (Int32, String) -> Void)? = nil
    }
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
        guard descriptor >= 0 else {
            Darwin.close(rootDescriptor)
            throw RecordingPendingStoreError.unsafeSession
        }
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

    func createSession(named directoryName: String, hooks: Hooks = .init()) throws -> RecordingPendingSession {
        guard isSafeDirectoryName(directoryName) else { throw RecordingPendingStoreError.invalidSessionName }
        let rootDescriptor = try openRootDescriptor()
        let rootIdentity = try directoryIdentity(of: rootDescriptor)
        guard mkdirat(rootDescriptor, directoryName, 0o700) == 0 else { Darwin.close(rootDescriptor); throw RecordingPendingStoreError.unsafeSession }
        var observed = stat()
        guard fstatat(rootDescriptor, directoryName, &observed, AT_SYMLINK_NOFOLLOW) == 0, (observed.st_mode & S_IFMT) == S_IFDIR else { Darwin.close(rootDescriptor); throw RecordingPendingStoreError.unsafeSession }
        hooks.afterCreateObservation?(rootDescriptor, directoryName)
        let descriptor = openat(rootDescriptor, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { Darwin.close(rootDescriptor); throw RecordingPendingStoreError.unsafeSession }
        do {
            let identity = try directoryIdentity(of: descriptor)
            guard matches(observed, identity) else { throw RecordingPendingStoreError.unsafeSession }
            return .init(fileDescriptor: descriptor, rootFileDescriptor: rootDescriptor, rootIdentity: rootIdentity, identity: identity, directoryName: directoryName, displayURL: root.appendingPathComponent(directoryName, isDirectory: true))
        } catch { Darwin.close(descriptor); Darwin.close(rootDescriptor); throw error }
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
        try validateRetainedSession(session)
        let rootDescriptor = session.rootFileDescriptor
        try validateTree(directory: session.fileDescriptor)
        try removeTree(directory: session.fileDescriptor)
        var current = stat()
        guard fstatat(rootDescriptor, session.directoryName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              matches(current, session.identity),
              unlinkat(rootDescriptor, session.directoryName, AT_REMOVEDIR) == 0 else {
            throw RecordingPendingStoreError.unsafeSession
        }
    }

    /// Confirms both the currently reachable pending root and its direct child
    /// still name the descriptors retained when the session was admitted.
    func validateRetainedSession(_ session: RecordingPendingSession) throws {
        guard try directoryIdentity(of: session.rootFileDescriptor) == session.rootIdentity,
              try directoryIdentity(of: session.fileDescriptor) == session.identity else {
            throw RecordingPendingStoreError.unsafeSession
        }
        let currentRoot = try openRootDescriptor()
        defer { Darwin.close(currentRoot) }
        guard try directoryIdentity(of: currentRoot) == session.rootIdentity else {
            throw RecordingPendingStoreError.unsafeSession
        }
        var rootEntry = stat()
        guard fstatat(currentRoot, session.directoryName, &rootEntry, AT_SYMLINK_NOFOLLOW) == 0,
              matches(rootEntry, session.identity),
              (rootEntry.st_mode & S_IFMT) == S_IFDIR else {
            throw RecordingPendingStoreError.unsafeSession
        }
    }

    func duplicateRetainedSession(_ session: RecordingPendingSession) throws -> RecordingPendingSession {
        let rootDescriptor = dup(session.rootFileDescriptor)
        guard rootDescriptor >= 0 else { throw RecordingPendingStoreError.unsafeSession }
        let descriptor = dup(session.fileDescriptor)
        guard descriptor >= 0 else { Darwin.close(rootDescriptor); throw RecordingPendingStoreError.unsafeSession }
        return .init(
            fileDescriptor: descriptor,
            rootFileDescriptor: rootDescriptor,
            rootIdentity: session.rootIdentity,
            identity: session.identity,
            directoryName: session.directoryName,
            displayURL: session.displayURL
        )
    }

    /// Updates source metadata through the admitted directory descriptor, never
    /// through the visible session path.
    func updateRecordingSourceMetadata(
        _ source: RecordingSource,
        in session: RecordingPendingSession,
        hooks: Hooks = .init()
    ) throws {
        try validateRetainedSession(session)
        let loaded = try loadMetadata(in: session)
        var metadata = loaded.metadata
        metadata.source = source
        try replaceMetadata(metadata, expected: loaded.observation, in: session, hooks: hooks)
    }

    func saveRecordingMetadata(
        _ metadata: RecordingSessionMetadata,
        in session: RecordingPendingSession,
        hooks: Hooks = .init()
    ) throws {
        try validateRetainedSession(session)
        let loaded = try loadMetadata(in: session)
        try loaded.metadata.validateForPersistence()
        try replaceMetadata(metadata, expected: loaded.observation, in: session, hooks: hooks)
    }

    /// Retention may inspect metadata only through an already-admitted pending
    /// session. Missing or malformed metadata is deliberately not treated as a
    /// default value by this query: callers must skip that session.
    func retentionMetadata(in session: RecordingPendingSession) throws -> RecordingSessionMetadata {
        try validateRetainedSession(session)
        var observed = stat()
        let name = RecordingSessionMetadataStore.fileName
        guard fstatat(session.fileDescriptor, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw RecordingPendingStoreError.unsafeSession
        }
        let metadata = try loadMetadata(in: session).metadata
        guard metadata.schemaVersion == RecordingSessionMetadata.currentSchemaVersion else {
            throw RecordingPendingStoreError.unsafeSession
        }
        return metadata
    }

    private func replaceMetadata(
        _ value: RecordingSessionMetadata,
        expected: stat?,
        in session: RecordingPendingSession,
        hooks: Hooks
    ) throws {
        var metadata = value
        metadata.schemaVersion = max(metadata.schemaVersion, 2)
        try metadata.validateForPersistence()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        guard data.count <= 262_144 else { throw RecordingPendingStoreError.unsafeSession }
        let name = RecordingSessionMetadataStore.fileName
        let temporary = ".recording-info-\(UUID().uuidString).tmp"
        let descriptor = openat(session.fileDescriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RecordingPendingStoreError.unsafeSession }
        defer { Darwin.close(descriptor); _ = unlinkat(session.fileDescriptor, temporary, 0) }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw RecordingPendingStoreError.unsafeSession }
        hooks.beforeMetadataRename?(session.fileDescriptor, name)
        guard metadataTargetMatches(expected, named: name, in: session.fileDescriptor),
              renameat(session.fileDescriptor, temporary, session.fileDescriptor, name) == 0,
              fsync(session.fileDescriptor) == 0 else { throw RecordingPendingStoreError.unsafeSession }
    }

    private func loadMetadata(in session: RecordingPendingSession) throws -> (metadata: RecordingSessionMetadata, observation: stat?) {
        let name = RecordingSessionMetadataStore.fileName
        var observed = stat()
        guard fstatat(session.fileDescriptor, name, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return (RecordingSessionMetadata(), nil) }
            throw RecordingPendingStoreError.unsafeSession
        }
        guard (observed.st_mode & S_IFMT) == S_IFREG, observed.st_nlink == 1, observed.st_size <= 262_144 else { throw RecordingPendingStoreError.unsafeSession }
        let existing = openat(session.fileDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard existing >= 0 else { throw RecordingPendingStoreError.unsafeSession }
        defer { Darwin.close(existing) }
        var opened = stat()
        guard fstat(existing, &opened) == 0, sameEntry(observed, opened), opened.st_nlink == 1 else { throw RecordingPendingStoreError.unsafeSession }
        let data = try readAll(from: existing)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingSessionMetadata.self, from: data)
        try metadata.validateForPersistence()
        return (metadata, observed)
    }

    private func metadataTargetMatches(_ expected: stat?, named name: String, in directory: Int32) -> Bool {
        var current = stat()
        if let expected {
            return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0
                && (current.st_mode & S_IFMT) == S_IFREG
                && current.st_nlink == 1
                && sameEntry(expected, current)
        }
        return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
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

    private func readAll(from descriptor: Int32) throws -> Data {
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 16_384)
        while true { let count = Darwin.read(descriptor, &bytes, bytes.count); if count < 0 { throw RecordingPendingStoreError.unsafeSession }; if count == 0 { return data }; guard data.count + Int(count) <= 262_144 else { throw RecordingPendingStoreError.unsafeSession }; data.append(bytes, count: Int(count)) }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset); guard count > 0 else { throw RecordingPendingStoreError.unsafeSession }; offset += Int(count) }
        }
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
