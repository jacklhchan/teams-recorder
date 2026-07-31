import Darwin
import Foundation

enum MeetingIntelligenceStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformed
    case tooLarge
    case unsafeFile
    case identityChanged
    case missing
}

struct MeetingIntelligenceArtifactStore: MeetingIntelligenceArtifactStoring, Sendable {
    static let fileName = "meeting-intelligence.json"
    static let maximumBytes = 256 * 1_024
    private let mutationGate: RecordingSessionMutationGate
    private let fileAccess: any MeetingIntelligenceStoreFileAccess

    init(
        mutationGate: RecordingSessionMutationGate,
        fileAccess: any MeetingIntelligenceStoreFileAccess = DarwinMeetingIntelligenceStoreFileAccess()
    ) {
        self.mutationGate = mutationGate
        self.fileAccess = fileAccess
    }

    func load(in folder: URL) throws -> MeetingIntelligenceArtifact? {
        guard let data = try MeetingIntelligenceStoreFileIO.read(
            named: Self.fileName,
            in: folder,
            maximumBytes: Self.maximumBytes
        ) else {
            return nil
        }
        let version = try schemaVersion(in: data)
        guard version == MeetingIntelligenceArtifact.currentSchemaVersion else {
            throw MeetingIntelligenceStoreError.unsupportedSchemaVersion(version)
        }
        do {
            let artifact = try JSONDecoder.meetingIntelligence.decode(
                MeetingIntelligenceArtifact.self,
                from: data
            )
            guard MeetingIntelligenceArtifactValidator.isValid(artifact) else {
                throw MeetingIntelligenceStoreError.malformed
            }
            return artifact
        } catch let error as MeetingIntelligenceStoreError {
            throw error
        } catch {
            throw MeetingIntelligenceStoreError.malformed
        }
    }

    func stage(_ artifact: MeetingIntelligenceArtifact, in folder: URL) throws -> URL {
        guard artifact.schemaVersion == MeetingIntelligenceArtifact.currentSchemaVersion else {
            throw MeetingIntelligenceStoreError.unsupportedSchemaVersion(artifact.schemaVersion)
        }
        guard MeetingIntelligenceArtifactValidator.isValid(artifact) else {
            throw MeetingIntelligenceStoreError.malformed
        }
        let data = try JSONEncoder.meetingIntelligence.encode(artifact)
        guard data.count <= Self.maximumBytes else {
            throw MeetingIntelligenceStoreError.tooLarge
        }
        let folderIdentity = try MeetingIntelligenceStoreFileIO.folderIdentity(in: folder)
        let name = ".meeting-intelligence-stage-\(folderIdentity.device)-\(folderIdentity.inode)-\(UUID().uuidString)"
        _ = try fileAccess.create(
            named: name,
            data: data,
            in: folder
        )
        return folder.standardizedFileURL.appendingPathComponent(name)
    }

    func promoteStaged(_ stagedURL: URL, in folder: URL) throws {
        try mutationGate.withMutation(for: folder) {
            let normalizedFolder = try MeetingIntelligenceStoreFileIO.normalizedFolder(folder)
            let staged = stagedURL.standardizedFileURL
            guard staged.deletingLastPathComponent() == normalizedFolder,
                  staged.lastPathComponent.hasPrefix(".meeting-intelligence-stage-") else {
                throw MeetingIntelligenceStoreError.unsafeFile
            }
            if let expectedFolder = MeetingIntelligenceStoreFileIO.folderIdentity(
                encodedInStageName: staged.lastPathComponent
            ) {
                try MeetingIntelligenceStoreFileIO.verifyFolder(normalizedFolder, matches: expectedFolder)
            }
            guard let stagedSnapshot = try fileAccess.snapshot(
                named: staged.lastPathComponent, in: normalizedFolder, maximumBytes: Self.maximumBytes
            ) else { throw MeetingIntelligenceStoreError.missing }
            try validateArtifactData(stagedSnapshot.data)
            let destination = try fileAccess.snapshot(
                named: Self.fileName, in: normalizedFolder, maximumBytes: Self.maximumBytes
            )
            if let destination {
                try validateArtifactData(destination.data)
            }
            try fileAccess.promote(stagedSnapshot, to: Self.fileName, over: destination, in: normalizedFolder)
        }
    }

    func removeStaged(_ stagedURL: URL, in folder: URL) throws {
        try mutationGate.withMutation(for: folder) {
            let normalizedFolder = try MeetingIntelligenceStoreFileIO.normalizedFolder(folder)
            let staged = stagedURL.standardizedFileURL
            guard staged.deletingLastPathComponent() == normalizedFolder,
                  staged.lastPathComponent.hasPrefix(".meeting-intelligence-stage-") else {
                throw MeetingIntelligenceStoreError.unsafeFile
            }
            guard let snapshot = try fileAccess.snapshot(
                named: staged.lastPathComponent,
                in: normalizedFolder,
                maximumBytes: Self.maximumBytes
            ) else {
                return
            }
            try fileAccess.remove(snapshot, in: normalizedFolder)
        }
    }
}

struct MeetingIntelligenceStateStore: MeetingIntelligenceStateStoring, Sendable {
    static let fileName = "meeting-intelligence-state.json"
    static let maximumBytes = 32 * 1_024
    private let mutationGate: RecordingSessionMutationGate
    private let fileAccess: any MeetingIntelligenceStoreFileAccess

    init(
        mutationGate: RecordingSessionMutationGate,
        fileAccess: any MeetingIntelligenceStoreFileAccess = DarwinMeetingIntelligenceStoreFileAccess()
    ) {
        self.mutationGate = mutationGate
        self.fileAccess = fileAccess
    }

    func load(in folder: URL) throws -> MeetingIntelligenceState? {
        try mutationGate.withMutation(for: folder) {
            let normalizedFolder = try MeetingIntelligenceStoreFileIO.normalizedFolder(folder)
            guard let snapshot = try fileAccess.snapshot(
                named: Self.fileName, in: normalizedFolder, maximumBytes: Self.maximumBytes
            ) else { return nil }
            let version = try schemaVersion(in: snapshot.data)
            guard version == MeetingIntelligenceState.currentSchemaVersion else {
                throw MeetingIntelligenceStoreError.unsupportedSchemaVersion(version)
            }
            let state: MeetingIntelligenceState
            do {
                state = try JSONDecoder.meetingIntelligence.decode(
                    MeetingIntelligenceState.self, from: snapshot.data
                )
            } catch {
                throw MeetingIntelligenceStoreError.malformed
            }
            guard [.checkingAvailability, .generating].contains(state.phase) else {
                return state
            }
            let interrupted = MeetingIntelligenceState(
                schemaVersion: state.schemaVersion,
                phase: .interrupted,
                message: "Meeting intelligence interrupted. You can generate again.",
                sourceTranscriptSHA256: state.sourceTranscriptSHA256,
                startedAt: state.startedAt,
                finishedAt: Date()
            )
            try saveEncoded(interrupted, in: normalizedFolder)
            return interrupted
        }
    }

    func save(_ state: MeetingIntelligenceState, in folder: URL) throws {
        guard state.schemaVersion == MeetingIntelligenceState.currentSchemaVersion else {
            throw MeetingIntelligenceStoreError.unsupportedSchemaVersion(state.schemaVersion)
        }
        let sanitized = MeetingIntelligenceState(
            schemaVersion: state.schemaVersion,
            phase: state.phase,
            message: sanitize(state.message),
            sourceTranscriptSHA256: state.sourceTranscriptSHA256,
            startedAt: state.startedAt,
            finishedAt: state.finishedAt
        )
        try mutationGate.withMutation(for: folder) {
            try saveEncoded(sanitized, in: MeetingIntelligenceStoreFileIO.normalizedFolder(folder))
        }
    }

    func remove(in folder: URL) throws {
        try mutationGate.withMutation(for: folder) {
            let normalizedFolder = try MeetingIntelligenceStoreFileIO.normalizedFolder(folder)
            guard let destination = try fileAccess.snapshot(
                named: Self.fileName, in: normalizedFolder, maximumBytes: Self.maximumBytes
            ) else { return }
            try validateCurrentSchema(destination.data, expected: MeetingIntelligenceState.currentSchemaVersion)
            try fileAccess.remove(destination, in: normalizedFolder)
        }
    }

    private func sanitize(_ message: String) -> String {
        let filtered = message.unicodeScalars.filter {
            $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t"
        }
        return String(String.UnicodeScalarView(filtered)).prefix(1_024).description
    }

    private func saveEncoded(_ state: MeetingIntelligenceState, in folder: URL) throws {
        let data = try JSONEncoder.meetingIntelligence.encode(state)
        guard data.count <= Self.maximumBytes else {
            throw MeetingIntelligenceStoreError.tooLarge
        }
        let destination = try fileAccess.snapshot(named: Self.fileName, in: folder, maximumBytes: Self.maximumBytes)
        if let destination {
            try validateCurrentSchema(destination.data, expected: MeetingIntelligenceState.currentSchemaVersion)
        }
        let stage = try fileAccess.create(
            named: ".meeting-intelligence-state-stage-\(UUID().uuidString)", data: data, in: folder
        )
        do {
            try fileAccess.promote(stage, to: Self.fileName, over: destination, in: folder)
        } catch {
            try? fileAccess.remove(stage, in: folder)
            throw error
        }
    }
}

private func schemaVersion(in data: Data) throws -> Int {
    struct Header: Decodable { let schemaVersion: Int }
    do {
        return try JSONDecoder().decode(Header.self, from: data).schemaVersion
    } catch {
        throw MeetingIntelligenceStoreError.malformed
    }
}

private func validateCurrentSchema(_ data: Data, expected: Int) throws {
    let version = try schemaVersion(in: data)
    guard version == expected else {
        throw MeetingIntelligenceStoreError.unsupportedSchemaVersion(version)
    }
}

private func validateArtifactData(_ data: Data) throws {
    try validateCurrentSchema(data, expected: MeetingIntelligenceArtifact.currentSchemaVersion)
    do {
        let artifact = try JSONDecoder.meetingIntelligence.decode(MeetingIntelligenceArtifact.self, from: data)
        guard MeetingIntelligenceArtifactValidator.isValid(artifact) else {
            throw MeetingIntelligenceStoreError.malformed
        }
    } catch let error as MeetingIntelligenceStoreError {
        throw error
    } catch {
        throw MeetingIntelligenceStoreError.malformed
    }
}

struct MeetingIntelligenceStoreFileIdentity: Equatable, Sendable {
    let device: Int64
    let inode: Int64
    let byteCount: Int64
}

struct MeetingIntelligenceStoreDirectoryIdentity: Equatable, Sendable {
    let device: Int64
    let inode: Int64
}

struct MeetingIntelligenceStoreFileSnapshot: Equatable, Sendable {
    let name: String
    let data: Data
    let identity: MeetingIntelligenceStoreFileIdentity
    /// The directory identity observed when this file was opened. A staged
    /// candidate must never be promoted through a replacement folder path.
    let directoryIdentity: MeetingIntelligenceStoreDirectoryIdentity?

    init(
        name: String,
        data: Data,
        identity: MeetingIntelligenceStoreFileIdentity,
        directoryIdentity: MeetingIntelligenceStoreDirectoryIdentity? = nil
    ) {
        self.name = name
        self.data = data
        self.identity = identity
        self.directoryIdentity = directoryIdentity
    }
}

protocol MeetingIntelligenceStoreFileAccess: Sendable {
    func snapshot(named name: String, in folder: URL, maximumBytes: Int) throws -> MeetingIntelligenceStoreFileSnapshot?
    func create(named name: String, data: Data, in folder: URL) throws -> MeetingIntelligenceStoreFileSnapshot
    func promote(_ staged: MeetingIntelligenceStoreFileSnapshot, to destinationName: String, over destination: MeetingIntelligenceStoreFileSnapshot?, in folder: URL) throws
    func remove(_ destination: MeetingIntelligenceStoreFileSnapshot, in folder: URL) throws
}

struct DarwinMeetingIntelligenceStoreFileAccess: MeetingIntelligenceStoreFileAccess, Sendable {
    private let beforeRename: (@Sendable () -> Void)?

    init(beforeRename: (@Sendable () -> Void)? = nil) {
        self.beforeRename = beforeRename
    }
    func snapshot(named name: String, in folder: URL, maximumBytes: Int) throws -> MeetingIntelligenceStoreFileSnapshot? {
        try MeetingIntelligenceStoreFileIO.snapshot(named: name, in: folder, maximumBytes: maximumBytes)
    }

    func create(named name: String, data: Data, in folder: URL) throws -> MeetingIntelligenceStoreFileSnapshot {
        try MeetingIntelligenceStoreFileIO.createSnapshot(named: name, data: data, in: folder)
    }

    func promote(_ staged: MeetingIntelligenceStoreFileSnapshot, to destinationName: String, over destination: MeetingIntelligenceStoreFileSnapshot?, in folder: URL) throws {
        try MeetingIntelligenceStoreFileIO.promote(
            staged,
            to: destinationName,
            over: destination,
            in: folder,
            beforeRename: beforeRename
        )
    }

    func remove(_ destination: MeetingIntelligenceStoreFileSnapshot, in folder: URL) throws {
        try MeetingIntelligenceStoreFileIO.remove(destination, in: folder)
    }
}

enum MeetingIntelligenceStoreFileIO {
    static func folderIdentity(in folder: URL) throws -> MeetingIntelligenceStoreDirectoryIdentity {
        let directory = try openFolder(try normalizedFolder(folder))
        defer { Darwin.close(directory) }
        return try identity(ofDirectory: directory)
    }

    static func folderIdentity(encodedInStageName name: String) -> MeetingIntelligenceStoreDirectoryIdentity? {
        let prefix = ".meeting-intelligence-stage-"
        guard name.hasPrefix(prefix) else { return nil }
        let parts = name.dropFirst(prefix.count).split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              let device = Int64(parts[0]), let inode = Int64(parts[1]) else {
            return nil
        }
        return .init(device: device, inode: inode)
    }
    static func normalizedFolder(_ folder: URL) throws -> URL {
        let normalized = folder.standardizedFileURL
        guard normalized == folder.resolvingSymlinksInPath().standardizedFileURL else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        return normalized
    }

    static func read(named name: String, in folder: URL, maximumBytes: Int, expectedDirectory: MeetingIntelligenceStoreDirectoryIdentity? = nil) throws -> Data? {
        try snapshot(named: name, in: folder, maximumBytes: maximumBytes, expectedDirectory: expectedDirectory)?.data
    }

    static func snapshot(named name: String, in folder: URL, maximumBytes: Int, expectedDirectory: MeetingIntelligenceStoreDirectoryIdentity? = nil) throws -> MeetingIntelligenceStoreFileSnapshot? {
        let normalizedFolder = try normalizedFolder(folder)
        var pathEntry = stat()
        let entryURL = normalizedFolder.appendingPathComponent(name)
        if lstat(entryURL.path, &pathEntry) != 0 {
            if errno == ENOENT { return nil }
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        guard (pathEntry.st_mode & S_IFMT) == S_IFREG, pathEntry.st_nlink == 1 else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        let directory = try openFolder(normalizedFolder)
        defer { Darwin.close(directory) }
        let directoryIdentity = try identity(ofDirectory: directory)
        if let expectedDirectory, directoryIdentity != expectedDirectory {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        var entry = stat()
        if fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        guard (entry.st_mode & S_IFMT) == S_IFREG, entry.st_nlink == 1 else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        defer { Darwin.close(descriptor) }
        let (data, identity) = try readValidatedWithIdentity(descriptor, maximumBytes: maximumBytes)
        return .init(name: name, data: data, identity: identity, directoryIdentity: directoryIdentity)
    }

    static func createSnapshot(
        named name: String,
        data: Data,
        in folder: URL,
        expectedDirectory: MeetingIntelligenceStoreDirectoryIdentity? = nil
    ) throws -> MeetingIntelligenceStoreFileSnapshot {
        let directory = try openFolder(try normalizedFolder(folder))
        defer { Darwin.close(directory) }
        let directoryIdentity = try identity(ofDirectory: directory)
        if let expectedDirectory, directoryIdentity != expectedDirectory {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        let descriptor = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw MeetingIntelligenceStoreError.unsafeFile }
        defer { Darwin.close(descriptor) }
        try writeAll(data, to: descriptor)
        return .init(
            name: name,
            data: data,
            identity: try identity(of: descriptor),
            directoryIdentity: directoryIdentity
        )
    }

    static func revalidate(_ snapshot: MeetingIntelligenceStoreFileSnapshot, in folder: URL) throws {
        guard let current = try self.snapshot(named: snapshot.name, in: folder, maximumBytes: Int(snapshot.identity.byteCount)),
              current.identity == snapshot.identity else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
    }

    /// Opens the directory once and performs every promotion operation relative
    /// to that descriptor. A replacement path can neither redirect `renameat`
    /// nor pass the final path identity check.
    static func promote(
        _ staged: MeetingIntelligenceStoreFileSnapshot,
        to destinationName: String,
        over destination: MeetingIntelligenceStoreFileSnapshot?,
        in folder: URL,
        beforeRename: (@Sendable () -> Void)? = nil
    ) throws {
        guard destination?.directoryIdentity == nil ||
                destination?.directoryIdentity == staged.directoryIdentity else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        let normalizedFolder = try normalizedFolder(folder)
        let directory = try openFolder(normalizedFolder)
        defer { Darwin.close(directory) }
        let directoryIdentity = try identity(ofDirectory: directory)
        if let expected = staged.directoryIdentity, expected != directoryIdentity {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        try revalidate(staged, relativeTo: directory)
        if let destination {
            try revalidate(destination, relativeTo: directory)
        } else if try exists(named: destinationName, relativeTo: directory) {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        beforeRename?()
        guard try pathIdentity(of: normalizedFolder) == directoryIdentity else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        guard renameat(directory, staged.name, directory, destinationName) == 0 else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
    }

    static func exists(named name: String, in folder: URL) throws -> Bool {
        let directory = try openFolder(try normalizedFolder(folder))
        defer { Darwin.close(directory) }
        var attributes = stat()
        if fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw MeetingIntelligenceStoreError.unsafeFile
    }

    private static func exists(named name: String, relativeTo directory: Int32) throws -> Bool {
        var attributes = stat()
        if fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw MeetingIntelligenceStoreError.unsafeFile
    }

    static func rename(
        named source: String,
        to destination: String,
        in folder: URL,
        expectedDirectory: MeetingIntelligenceStoreDirectoryIdentity?
    ) throws {
        let directory = try openFolder(try normalizedFolder(folder))
        defer { Darwin.close(directory) }
        if let expectedDirectory, try identity(ofDirectory: directory) != expectedDirectory {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        guard renameat(directory, source, directory, destination) == 0 else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
    }

    static func remove(_ snapshot: MeetingIntelligenceStoreFileSnapshot, in folder: URL) throws {
        let directory = try openFolder(try normalizedFolder(folder))
        defer { Darwin.close(directory) }
        let descriptor = openat(directory, snapshot.name, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { throw MeetingIntelligenceStoreError.identityChanged }
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        defer { Darwin.close(descriptor) }
        guard try identity(of: descriptor) == snapshot.identity else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        guard unlinkat(directory, snapshot.name, 0) == 0 else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
    }

    private static func openFolder(_ folder: URL) throws -> Int32 {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MeetingIntelligenceStoreError.unsafeFile }
        return descriptor
    }

    private static func readValidatedWithIdentity(_ descriptor: Int32, maximumBytes: Int) throws -> (Data, MeetingIntelligenceStoreFileIdentity) {
        let before = try identity(of: descriptor)
        guard before.byteCount <= Int64(maximumBytes) else {
            throw MeetingIntelligenceStoreError.tooLarge
        }
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let size = min(64 * 1_024, remaining)
            var bytes = [UInt8](repeating: 0, count: size)
            let count = Darwin.read(descriptor, &bytes, size)
            guard count >= 0 else { throw MeetingIntelligenceStoreError.unsafeFile }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(Int(count)))
        }
        guard data.count <= maximumBytes else {
            throw MeetingIntelligenceStoreError.tooLarge
        }
        guard try identity(of: descriptor) == before else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
        return (data, before)
    }

    private static func identity(of descriptor: Int32) throws -> MeetingIntelligenceStoreFileIdentity {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_nlink == 1 else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        return MeetingIntelligenceStoreFileIdentity(
            device: Int64(attributes.st_dev),
            inode: Int64(attributes.st_ino),
            byteCount: Int64(attributes.st_size)
        )
    }

    static func verifyFolder(
        _ folder: URL,
        matches expected: MeetingIntelligenceStoreDirectoryIdentity
    ) throws {
        let directory = try openFolder(try normalizedFolder(folder))
        defer { Darwin.close(directory) }
        guard try identity(ofDirectory: directory) == expected else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
    }

    private static func identity(ofDirectory descriptor: Int32) throws -> MeetingIntelligenceStoreDirectoryIdentity {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFDIR else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        return .init(device: Int64(attributes.st_dev), inode: Int64(attributes.st_ino))
    }

    private static func pathIdentity(of folder: URL) throws -> MeetingIntelligenceStoreDirectoryIdentity {
        var attributes = stat()
        guard lstat(folder.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFDIR else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        return .init(device: Int64(attributes.st_dev), inode: Int64(attributes.st_ino))
    }

    private static func revalidate(
        _ snapshot: MeetingIntelligenceStoreFileSnapshot,
        relativeTo directory: Int32
    ) throws {
        try validateRegularEntry(named: snapshot.name, relativeTo: directory)
        let descriptor = openat(directory, snapshot.name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MeetingIntelligenceStoreError.identityChanged }
        defer { Darwin.close(descriptor) }
        guard try identity(of: descriptor) == snapshot.identity else {
            throw MeetingIntelligenceStoreError.identityChanged
        }
    }

    private static func validateRegularEntry(named name: String, relativeTo directory: Int32) throws {
        var attributes = stat()
        guard fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw MeetingIntelligenceStoreError.missing }
            throw MeetingIntelligenceStoreError.unsafeFile
        }
        guard (attributes.st_mode & S_IFMT) == S_IFREG, attributes.st_nlink == 1 else {
            throw MeetingIntelligenceStoreError.unsafeFile
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var address = buffer.baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                guard count > 0 else { throw MeetingIntelligenceStoreError.unsafeFile }
                remaining -= Int(count)
                address = address.advanced(by: Int(count))
            }
        }
    }
}

private extension JSONEncoder {
    static var meetingIntelligence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var meetingIntelligence: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
