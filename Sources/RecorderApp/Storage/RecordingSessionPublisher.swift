import AVFoundation
import CryptoKit
import Darwin
import Foundation

struct RecordingPublicationSuccess: Equatable, Sendable {
    let itemID: UUID
    let folderURL: URL
    let recordingURL: URL
}

enum RecordingPublicationError: Error, Equatable, Sendable {
    case invalidSource, unsafeEntry, invalidMedia, destinationUnavailable, verificationMismatch, destinationCollision
    case ioFailure(String)
}

protocol RecordingSessionPublishing: Sendable {
    func publish(item: RecordingPublicationItem, destination: RecordingDestinationAccess) async throws -> RecordingPublicationSuccess
}

struct RecordingSessionPublisher: RecordingSessionPublishing, @unchecked Sendable {
    typealias MediaValidator = (Int32, String) -> Bool
    typealias WriteOperation = (Int32, UnsafeRawPointer, Int) -> Int

    enum EntryContext: Equatable { case source, staging, published }

    struct Hooks {
        var afterEntryObservation: ((EntryContext, Int32, String) -> Void)?
        var beforeStagingVerification: ((Int32) -> Void)?
        var beforeStagingCleanup: ((Int32, String) -> Void)?
        var beforeFinalRename: ((Int32, String) -> Void)?
        var beforePublishedValidation: ((Int32, String) -> Void)?
    }

    private static let markerName = ".lmr-publication-v1.json"
    private static let maximumMarkerBytes: Int64 = 65_536
    private static let maximumDepth = 32
    private static let maximumEntries = 4_096

    private let pendingStore: RecordingPendingStore
    private let mediaValidator: MediaValidator
    private let hooks: Hooks
    private let writeOperation: WriteOperation

    init(
        pendingStore: RecordingPendingStore,
        mediaValidator: @escaping MediaValidator = Self.liveMediaValidator,
        hooks: Hooks = .init(),
        writeOperation: @escaping WriteOperation = { Darwin.write($0, $1, $2) }
    ) {
        self.pendingStore = pendingStore
        self.mediaValidator = mediaValidator
        self.hooks = hooks
        self.writeOperation = writeOperation
    }

    func publish(item: RecordingPublicationItem, destination: RecordingDestinationAccess) async throws -> RecordingPublicationSuccess {
        let source = try pendingStore.openSession(for: item.sessionDirectoryName)
        IncompleteSessionRecovery().recover(in: source)
        let sourceInventory = try inventory(directory: source.fileDescriptor, context: .source)
        let recordingName = try finalizedRecording(in: sourceInventory)
        guard validateMedia(named: recordingName, in: source.fileDescriptor, context: .source) else {
            throw RecordingPublicationError.invalidMedia
        }
        let sourceDigest = aggregateDigest(sourceInventory)

        let destinationFD = try openDestination(destination.url)
        defer { Darwin.close(destinationFD) }
        if let existing = try publishedMatch(
            in: destinationFD,
            destinationURL: destination.url,
            itemID: item.id,
            digest: sourceDigest,
            recordingName: recordingName
        ) {
            return existing
        }

        let stagingName = ".\(item.id.uuidString).lmr-publishing"
        guard mkdirat(destinationFD, stagingName, 0o700) == 0 else {
            throw RecordingPublicationError.destinationCollision
        }
        var stagingObservation = stat()
        guard fstatat(destinationFD, stagingName, &stagingObservation, AT_SYMLINK_NOFOLLOW) == 0,
              (stagingObservation.st_mode & S_IFMT) == S_IFDIR else {
            throw RecordingPublicationError.unsafeEntry
        }
        let stagingFD = openat(destinationFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { throw RecordingPublicationError.unsafeEntry }
        var stagingOpened = stat()
        guard fstat(stagingFD, &stagingOpened) == 0, sameIdentity(stagingObservation, stagingOpened) else {
            Darwin.close(stagingFD)
            throw RecordingPublicationError.unsafeEntry
        }
        var staged = true
        defer {
            if staged {
                hooks.beforeStagingCleanup?(destinationFD, stagingName)
                removeOwnedTree(
                    named: stagingName,
                    from: destinationFD,
                    retainedDescriptor: stagingFD,
                    identity: stagingOpened
                )
            }
            Darwin.close(stagingFD)
        }

        try copyTree(from: source.fileDescriptor, to: stagingFD)
        hooks.beforeStagingVerification?(stagingFD)
        let copied = try inventory(directory: stagingFD, context: .staging)
        guard copied == sourceInventory else { throw RecordingPublicationError.verificationMismatch }
        try writeMarker(itemID: item.id, digest: sourceDigest, in: stagingFD)

        let finalName = try destinationName(preferred: item.sessionDirectoryName, itemID: item.id, in: destinationFD)
        hooks.beforeFinalRename?(destinationFD, finalName)
        guard renameatx_np(destinationFD, stagingName, destinationFD, finalName, UInt32(RENAME_EXCL)) == 0 else {
            throw RecordingPublicationError.destinationCollision
        }
        staged = false

        var publishedObservation = stat()
        var publishedOpened = stat()
        guard fstatat(destinationFD, finalName, &publishedObservation, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(stagingFD, &publishedOpened) == 0,
              sameIdentity(publishedObservation, publishedOpened),
              (publishedOpened.st_mode & S_IFMT) == S_IFDIR else {
            throw RecordingPublicationError.verificationMismatch
        }
        hooks.beforePublishedValidation?(stagingFD, recordingName)
        guard validateMedia(named: recordingName, in: stagingFD, context: .published) else {
            throw RecordingPublicationError.invalidMedia
        }

        let folderURL = destination.url.appendingPathComponent(finalName, isDirectory: true).standardizedFileURL
        return .init(
            itemID: item.id,
            folderURL: folderURL,
            recordingURL: folderURL.appendingPathComponent(recordingName).standardizedFileURL
        )
    }

    private static func liveMediaValidator(_ descriptor: Int32, _ recordingName: String) -> Bool {
        var template = Array((NSTemporaryDirectory() + "lmr-media-XXXXXX").utf8CString)
        guard let directoryPath = mkdtemp(&template) else { return false }
        let directoryURL = URL(fileURLWithPath: String(cString: directoryPath), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        _ = chmod(directoryPath, 0o700)

        let directoryFD = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { Darwin.close(directoryFD) }
        let safeName = "recording." + URL(fileURLWithPath: recordingName).pathExtension
        let copyFD = openat(directoryFD, safeName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard copyFD >= 0 else { return false }
        let copied = copyDescriptorBytes(from: descriptor, to: copyFD)
        Darwin.close(copyFD)
        guard copied else { return false }

        let asset = AVURLAsset(url: directoryURL.appendingPathComponent(safeName))
        let duration = CMTimeGetSeconds(asset.duration)
        return duration.isFinite && duration > 0
    }

    private static func copyDescriptorBytes(from source: Int32, to destination: Int32) -> Bool {
        guard lseek(source, 0, SEEK_SET) >= 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count < 0 { return false }
            if count == 0 { return fsync(destination) == 0 }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(destination, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                guard written > 0 else { return false }
                offset += written
            }
        }
    }

    private func openDestination(_ url: URL) throws -> Int32 {
        let path = url.path
        guard path.hasPrefix("/") else { throw RecordingPublicationError.destinationUnavailable }
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        guard rawComponents.first?.isEmpty == true, rawComponents.count > 1 else {
            throw RecordingPublicationError.destinationUnavailable
        }
        let components = rawComponents.dropFirst()
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RecordingPublicationError.destinationUnavailable
        }

        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw RecordingPublicationError.destinationUnavailable }
        for component in components {
            var observation = stat()
            guard fstatat(current, String(component), &observation, AT_SYMLINK_NOFOLLOW) == 0,
                  (observation.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(current)
                throw RecordingPublicationError.destinationUnavailable
            }
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                Darwin.close(current)
                throw RecordingPublicationError.destinationUnavailable
            }
            var opened = stat()
            guard fstat(next, &opened) == 0, sameIdentity(observation, opened) else {
                Darwin.close(next)
                Darwin.close(current)
                throw RecordingPublicationError.destinationUnavailable
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    private func finalizedRecording(in inventory: [InventoryEntry]) throws -> String {
        let names = ["recording.mp4", "recording.m4a"]
            + ManualTranscriptionImporter.supportedExtensions.sorted().filter { $0 != "m4a" }.map { "recording.\($0)" }
        let found = inventory.filter { names.contains($0.path) }
        guard found.count == 1, found[0].bytes > 0 else { throw RecordingPublicationError.invalidMedia }
        return found[0].path
    }

    private func validateMedia(named name: String, in directory: Int32, context: EntryContext) -> Bool {
        var observation = stat()
        guard fstatat(directory, name, &observation, AT_SYMLINK_NOFOLLOW) == 0,
              (observation.st_mode & S_IFMT) == S_IFREG,
              let opened = try? openObserved(
                directory: directory,
                name: name,
                observation: observation,
                context: context
              ) else { return false }
        defer { Darwin.close(opened.descriptor) }
        guard opened.attributes.st_size > 0, mediaValidator(opened.descriptor, name) else { return false }
        var current = stat()
        return fstat(opened.descriptor, &current) == 0 && sameIdentity(opened.attributes, current)
    }

    private struct InventoryEntry: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    private struct Marker: Codable {
        let version: Int
        let itemID: UUID
        let inventoryDigest: String
    }

    private func inventory(directory: Int32, context: EntryContext, excludingMarker: Bool = false) throws -> [InventoryEntry] {
        var count = 0
        return try inventory(
            directory: directory,
            prefix: "",
            depth: 0,
            entryCount: &count,
            context: context,
            excludingMarker: excludingMarker
        )
    }

    private func inventory(
        directory: Int32,
        prefix: String,
        depth: Int,
        entryCount: inout Int,
        context: EntryContext,
        excludingMarker: Bool
    ) throws -> [InventoryEntry] {
        guard depth <= Self.maximumDepth else { throw RecordingPublicationError.unsafeEntry }
        var entries: [InventoryEntry] = []
        let names = try entryNames(in: directory)
        for name in names {
            if excludingMarker, prefix.isEmpty, name == Self.markerName { continue }
            entryCount += 1
            guard entryCount <= Self.maximumEntries else { throw RecordingPublicationError.unsafeEntry }
            var observation = stat()
            guard fstatat(directory, name, &observation, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw RecordingPublicationError.unsafeEntry
            }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            switch observation.st_mode & S_IFMT {
            case S_IFREG:
                do {
                    let opened = try openObserved(directory: directory, name: name, observation: observation, context: context)
                    defer { Darwin.close(opened.descriptor) }
                    let fileDigest = try digest(opened.descriptor)
                    var current = stat()
                    guard fstat(opened.descriptor, &current) == 0, sameIdentity(opened.attributes, current) else {
                        throw RecordingPublicationError.unsafeEntry
                    }
                    entries.append(.init(path: path, bytes: Int64(opened.attributes.st_size), sha256: fileDigest))
                }
            case S_IFDIR:
                do {
                    let opened = try openObserved(directory: directory, name: name, observation: observation, context: context)
                    defer { Darwin.close(opened.descriptor) }
                    entries += try inventory(
                        directory: opened.descriptor,
                        prefix: path,
                        depth: depth + 1,
                        entryCount: &entryCount,
                        context: context,
                        excludingMarker: excludingMarker
                    )
                }
            default:
                throw RecordingPublicationError.unsafeEntry
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func entryNames(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw RecordingPublicationError.ioFailure("enumerate") }
        _ = lseek(duplicate, 0, SEEK_SET)
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw RecordingPublicationError.ioFailure("enumerate")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    private func openObserved(
        directory: Int32,
        name: String,
        observation: stat,
        context: EntryContext
    ) throws -> (descriptor: Int32, attributes: stat) {
        hooks.afterEntryObservation?(context, directory, name)
        let type = observation.st_mode & S_IFMT
        let flags: Int32
        if type == S_IFREG {
            flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        } else if type == S_IFDIR {
            flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        } else {
            throw RecordingPublicationError.unsafeEntry
        }
        let descriptor = openat(directory, name, flags)
        guard descriptor >= 0 else { throw RecordingPublicationError.unsafeEntry }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, sameIdentity(observation, opened) else {
            Darwin.close(descriptor)
            throw RecordingPublicationError.unsafeEntry
        }
        return (descriptor, opened)
    }

    private func digest(_ descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw RecordingPublicationError.ioFailure("seek") }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { throw RecordingPublicationError.ioFailure("read") }
            if count == 0 { break }
            hash.update(data: Data(buffer[0..<count]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func aggregateDigest(_ inventory: [InventoryEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(inventory)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func copyTree(from source: Int32, to destination: Int32, depth: Int = 0, entryCount: inout Int) throws {
        guard depth <= Self.maximumDepth else { throw RecordingPublicationError.unsafeEntry }
        for name in try entryNames(in: source) {
            entryCount += 1
            guard entryCount <= Self.maximumEntries else { throw RecordingPublicationError.unsafeEntry }
            var observation = stat()
            guard fstatat(source, name, &observation, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw RecordingPublicationError.unsafeEntry
            }
            switch observation.st_mode & S_IFMT {
            case S_IFDIR:
                do {
                    let from = try openObserved(directory: source, name: name, observation: observation, context: .source)
                    defer { Darwin.close(from.descriptor) }
                    guard mkdirat(destination, name, 0o700) == 0 else { throw RecordingPublicationError.ioFailure("mkdir") }
                    var created = stat()
                    guard fstatat(destination, name, &created, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw RecordingPublicationError.unsafeEntry
                    }
                    let to = try openObserved(directory: destination, name: name, observation: created, context: .staging)
                    defer { Darwin.close(to.descriptor) }
                    try copyTree(from: from.descriptor, to: to.descriptor, depth: depth + 1, entryCount: &entryCount)
                }
            case S_IFREG:
                do {
                    let from = try openObserved(directory: source, name: name, observation: observation, context: .source)
                    defer { Darwin.close(from.descriptor) }
                    let toFD = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard toFD >= 0 else { throw RecordingPublicationError.unsafeEntry }
                    defer { Darwin.close(toFD) }
                    var destinationObservation = stat()
                    guard fstatat(destination, name, &destinationObservation, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw RecordingPublicationError.unsafeEntry
                    }
                    var destinationOpened = stat()
                    guard fstat(toFD, &destinationOpened) == 0, sameIdentity(destinationObservation, destinationOpened) else {
                        throw RecordingPublicationError.unsafeEntry
                    }
                    try copyBytes(from: from.descriptor, to: toFD)
                    var sourceCurrent = stat()
                    guard fstat(from.descriptor, &sourceCurrent) == 0, sameIdentity(from.attributes, sourceCurrent) else {
                        throw RecordingPublicationError.unsafeEntry
                    }
                }
            default:
                throw RecordingPublicationError.unsafeEntry
            }
        }
    }

    private func copyTree(from source: Int32, to destination: Int32) throws {
        var count = 0
        try copyTree(from: source, to: destination, entryCount: &count)
    }

    private func copyBytes(from source: Int32, to destination: Int32) throws {
        guard lseek(source, 0, SEEK_SET) >= 0 else { throw RecordingPublicationError.ioFailure("seek") }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count < 0 { throw RecordingPublicationError.ioFailure("read") }
            if count == 0 { return }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(destination, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                guard written > 0 else { throw RecordingPublicationError.ioFailure("write") }
                offset += written
            }
        }
    }

    private func writeMarker(itemID: UUID, digest: String, in directory: Int32) throws {
        let data = try JSONEncoder().encode(Marker(version: 1, itemID: itemID, inventoryDigest: digest))
        let descriptor = openat(
            directory,
            Self.markerName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw RecordingPublicationError.ioFailure("marker") }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = writeOperation(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0, written <= bytes.count - offset else {
                    throw RecordingPublicationError.ioFailure("marker")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw RecordingPublicationError.ioFailure("marker") }
    }

    private func destinationName(preferred: String, itemID: UUID, in directory: Int32) throws -> String {
        var attributes = stat()
        if fstatat(directory, preferred, &attributes, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return preferred }
        let candidate = "\(preferred)-\(itemID.uuidString)"
        if fstatat(directory, candidate, &attributes, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return candidate }
        throw RecordingPublicationError.destinationCollision
    }

    private func publishedMatch(
        in directory: Int32,
        destinationURL: URL,
        itemID: UUID,
        digest: String,
        recordingName: String
    ) throws -> RecordingPublicationSuccess? {
        for name in try entryNames(in: directory) where !name.hasPrefix(".") {
            var observation = stat()
            guard fstatat(directory, name, &observation, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard (observation.st_mode & S_IFMT) == S_IFDIR else { continue }
            if let match = try withOpenedDirectory(
                parent: directory,
                name: name,
                observation: observation,
                context: .published,
                body: { folder -> RecordingPublicationSuccess? in
                    guard let marker = readMarker(in: folder),
                          marker.version == 1,
                          marker.itemID == itemID,
                          marker.inventoryDigest == digest else { return nil }
                    let actualInventory = try inventory(directory: folder, context: .published, excludingMarker: true)
                    guard aggregateDigest(actualInventory) == digest else { return nil }
                    guard validateMedia(named: recordingName, in: folder, context: .published) else {
                        throw RecordingPublicationError.invalidMedia
                    }
                    let folderURL = destinationURL.appendingPathComponent(name, isDirectory: true).standardizedFileURL
                    return .init(
                        itemID: itemID,
                        folderURL: folderURL,
                        recordingURL: folderURL.appendingPathComponent(recordingName).standardizedFileURL
                    )
                }
            ) {
                return match
            }
        }
        return nil
    }

    private func withOpenedDirectory<T>(
        parent: Int32,
        name: String,
        observation: stat,
        context: EntryContext,
        body: (Int32) throws -> T
    ) throws -> T {
        let opened = try openObserved(
            directory: parent,
            name: name,
            observation: observation,
            context: context
        )
        defer { Darwin.close(opened.descriptor) }
        return try body(opened.descriptor)
    }

    private func readMarker(in directory: Int32) -> Marker? {
        var observation = stat()
        guard fstatat(directory, Self.markerName, &observation, AT_SYMLINK_NOFOLLOW) == 0,
              (observation.st_mode & S_IFMT) == S_IFREG,
              observation.st_size <= Self.maximumMarkerBytes,
              let opened = try? openObserved(
                directory: directory,
                name: Self.markerName,
                observation: observation,
                context: .published
              ) else { return nil }
        defer { Darwin.close(opened.descriptor) }
        guard let data = readBounded(opened.descriptor, maximumBytes: Int(Self.maximumMarkerBytes)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private func readBounded(_ descriptor: Int32, maximumBytes: Int) -> Data? {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            let requested = min(buffer.count, maximumBytes + 1 - data.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
        return nil
    }

    private func removeOwnedTree(named name: String, from parent: Int32, retainedDescriptor: Int32, identity: stat) {
        var named = stat()
        var retained = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(retainedDescriptor, &retained) == 0,
              sameObject(named, identity),
              sameObject(retained, identity) else { return }
        removeTree(retainedDescriptor)
        var final = stat()
        guard fstatat(parent, name, &final, AT_SYMLINK_NOFOLLOW) == 0,
              sameObject(final, identity) else { return }
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    private func removeTree(_ directory: Int32) {
        guard let names = try? entryNames(in: directory) else { return }
        for name in names {
            var observation = stat()
            guard fstatat(directory, name, &observation, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (observation.st_mode & S_IFMT) == S_IFDIR,
               let child = try? openObserved(directory: directory, name: name, observation: observation, context: .staging) {
                removeTree(child.descriptor)
                Darwin.close(child.descriptor)
                var current = stat()
                if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, sameIdentity(current, observation) {
                    _ = unlinkat(directory, name, AT_REMOVEDIR)
                }
            } else if (observation.st_mode & S_IFMT) == S_IFREG {
                let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if descriptor >= 0 {
                    var opened = stat()
                    if fstat(descriptor, &opened) == 0, sameIdentity(observation, opened) {
                        var current = stat()
                        if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, sameIdentity(current, opened) {
                            _ = unlinkat(directory, name, 0)
                        }
                    }
                    Darwin.close(descriptor)
                }
            }
        }
    }
}

private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
        && lhs.st_dev == rhs.st_dev
        && lhs.st_ino == rhs.st_ino
        && lhs.st_size == rhs.st_size
}

private func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
    (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
        && lhs.st_dev == rhs.st_dev
        && lhs.st_ino == rhs.st_ino
}
