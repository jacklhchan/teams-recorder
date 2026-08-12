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
    typealias MediaValidator = @Sendable (URL) -> Bool
    private let pendingStore: RecordingPendingStore
    private let mediaValidator: MediaValidator

    init(pendingStore: RecordingPendingStore, mediaValidator: @escaping MediaValidator = Self.liveMediaValidator) {
        self.pendingStore = pendingStore
        self.mediaValidator = mediaValidator
    }

    func publish(item: RecordingPublicationItem, destination: RecordingDestinationAccess) async throws -> RecordingPublicationSuccess {
        let source = try pendingStore.openSession(for: item.sessionDirectoryName)
        IncompleteSessionRecovery().recover(in: source)
        let sourceInventory = try inventory(directory: source.fileDescriptor)
        let recordingName = try finalizedRecording(in: source.fileDescriptor, inventory: sourceInventory)
        guard validateMedia(named: recordingName, in: source.fileDescriptor) else { throw RecordingPublicationError.invalidMedia }
        let sourceDigest = aggregateDigest(sourceInventory)

        let destinationFD = open(destination.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destinationFD >= 0 else { throw RecordingPublicationError.destinationUnavailable }
        defer { Darwin.close(destinationFD) }
        if let existing = try publishedMatch(in: destinationFD, destinationURL: destination.url, itemID: item.id, digest: sourceDigest, recordingName: recordingName) { return existing }

        let stagingName = ".\(item.id.uuidString).lmr-publishing"
        guard mkdirat(destinationFD, stagingName, 0o700) == 0 else { throw RecordingPublicationError.destinationCollision }
        var staged = true
        defer { if staged { removeOwnedTree(named: stagingName, from: destinationFD) } }
        let stagingFD = openat(destinationFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { throw RecordingPublicationError.ioFailure("open staging") }
        defer { Darwin.close(stagingFD) }
        try copyTree(from: source.fileDescriptor, to: stagingFD)
        let copied = try inventory(directory: stagingFD)
        guard copied == sourceInventory else { throw RecordingPublicationError.verificationMismatch }
        try writeMarker(itemID: item.id, digest: sourceDigest, in: stagingFD)
        let finalName = try destinationName(preferred: item.sessionDirectoryName, itemID: item.id, in: destinationFD)
        guard renameatx_np(destinationFD, stagingName, destinationFD, finalName, UInt32(RENAME_EXCL)) == 0 else { throw RecordingPublicationError.destinationCollision }
        staged = false
        let folderURL = destination.url.appendingPathComponent(finalName, isDirectory: true).standardizedFileURL
        let recordingURL = folderURL.appendingPathComponent(recordingName).standardizedFileURL
        guard mediaValidator(recordingURL) else { throw RecordingPublicationError.invalidMedia }
        return .init(itemID: item.id, folderURL: folderURL, recordingURL: recordingURL)
    }

    private static func liveMediaValidator(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        return duration.isFinite && duration > 0
    }

    private func finalizedRecording(in directory: Int32, inventory: [InventoryEntry]) throws -> String {
        let names = ["recording.mp4", "recording.m4a"] + ManualTranscriptionImporter.supportedExtensions.sorted().filter { $0 != "m4a" }.map { "recording.\($0)" }
        let found = inventory.filter { names.contains($0.path) }
        guard found.count == 1, found[0].bytes > 0 else { throw RecordingPublicationError.invalidMedia }
        return found[0].path
    }

    private func validateMedia(named name: String, in directory: Int32) -> Bool {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return mediaValidator(URL(fileURLWithPath: "/dev/fd/\(descriptor)"))
    }

    private struct InventoryEntry: Codable, Equatable, Sendable { let path: String; let bytes: Int64; let sha256: String }
    private struct Marker: Codable { let version: Int; let itemID: UUID; let inventoryDigest: String }

    private func inventory(directory: Int32, prefix: String = "") throws -> [InventoryEntry] {
        var entries: [InventoryEntry] = []
        let duplicate = dup(directory); guard duplicate >= 0 else { throw RecordingPublicationError.ioFailure("enumerate") }; _ = lseek(duplicate, 0, SEEK_SET); guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw RecordingPublicationError.ioFailure("enumerate") }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) } }
            guard name != ".", name != ".." else { continue }
            var attributes = stat()
            guard fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { throw RecordingPublicationError.ioFailure("stat") }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            switch attributes.st_mode & S_IFMT {
            case S_IFREG:
                let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw RecordingPublicationError.unsafeEntry }
                defer { Darwin.close(fd) }
                entries.append(.init(path: path, bytes: Int64(attributes.st_size), sha256: try digest(fd)))
            case S_IFDIR:
                let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw RecordingPublicationError.unsafeEntry }
                defer { Darwin.close(fd) }
                entries += try inventory(directory: fd, prefix: path)
            default: throw RecordingPublicationError.unsafeEntry
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func digest(_ descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw RecordingPublicationError.ioFailure("seek") }
        var hash = SHA256(); var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true { let count = Darwin.read(descriptor, &buffer, buffer.count); if count < 0 { throw RecordingPublicationError.ioFailure("read") }; if count == 0 { break }; hash.update(data: Data(buffer[0..<Int(count)])) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func aggregateDigest(_ inventory: [InventoryEntry]) -> String {
        let data = (try? JSONEncoder().encode(inventory)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func copyTree(from source: Int32, to destination: Int32) throws {
        let duplicate = dup(source); guard duplicate >= 0 else { throw RecordingPublicationError.ioFailure("enumerate") }; _ = lseek(duplicate, 0, SEEK_SET); guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw RecordingPublicationError.ioFailure("enumerate") }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) } }; guard name != ".", name != ".." else { continue }
            var attributes = stat(); guard fstatat(source, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { throw RecordingPublicationError.ioFailure("stat") }
            if (attributes.st_mode & S_IFMT) == S_IFDIR {
                guard mkdirat(destination, name, 0o700) == 0 else { throw RecordingPublicationError.ioFailure("mkdir") }
                let from = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), to = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard from >= 0, to >= 0 else { if from >= 0 { Darwin.close(from) }; if to >= 0 { Darwin.close(to) }; throw RecordingPublicationError.unsafeEntry }; defer { Darwin.close(from); Darwin.close(to) }; try copyTree(from: from, to: to)
            } else if (attributes.st_mode & S_IFMT) == S_IFREG {
                let from = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), to = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard from >= 0, to >= 0 else { if from >= 0 { Darwin.close(from) }; if to >= 0 { Darwin.close(to) }; throw RecordingPublicationError.unsafeEntry }; defer { Darwin.close(from); Darwin.close(to) }; try copyBytes(from: from, to: to)
            } else { throw RecordingPublicationError.unsafeEntry }
        }
    }

    private func copyBytes(from source: Int32, to destination: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true { let count = Darwin.read(source, &buffer, buffer.count); if count < 0 { throw RecordingPublicationError.ioFailure("read") }; if count == 0 { return }; var offset = 0; while offset < count { let wrote = Darwin.write(destination, buffer.withUnsafeBytes { $0.baseAddress!.advanced(by: offset) }, Int(count) - offset); if wrote <= 0 { throw RecordingPublicationError.ioFailure("write") }; offset += Int(wrote) } }
    }

    private func writeMarker(itemID: UUID, digest: String, in directory: Int32) throws {
        let data = try JSONEncoder().encode(Marker(version: 1, itemID: itemID, inventoryDigest: digest)); let fd = openat(directory, ".lmr-publication-v1.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard fd >= 0 else { throw RecordingPublicationError.ioFailure("marker") }; defer { Darwin.close(fd) }; try data.withUnsafeBytes { raw in guard Darwin.write(fd, raw.baseAddress!, raw.count) == raw.count else { throw RecordingPublicationError.ioFailure("marker") } }
    }

    private func destinationName(preferred: String, itemID: UUID, in directory: Int32) throws -> String {
        var attributes = stat(); if fstatat(directory, preferred, &attributes, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return preferred }
        let candidate = "\(preferred)-\(itemID.uuidString)"; if fstatat(directory, candidate, &attributes, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return candidate }; throw RecordingPublicationError.destinationCollision
    }

    private func publishedMatch(in directory: Int32, destinationURL: URL, itemID: UUID, digest: String, recordingName: String) throws -> RecordingPublicationSuccess? {
        let duplicate = dup(directory); guard duplicate >= 0 else { return nil }; _ = lseek(duplicate, 0, SEEK_SET); guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); return nil }; defer { closedir(stream) }
        while let entry = readdir(stream) { let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) } }; guard name != ".", name != "..", !name.hasPrefix(".") else { continue }; let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { continue }; defer { Darwin.close(fd) }; let markerFD = openat(fd, ".lmr-publication-v1.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard markerFD >= 0 else { continue }; let data = readAll(markerFD); Darwin.close(markerFD); guard let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.version == 1, marker.itemID == itemID, marker.inventoryDigest == digest else { continue }; let folder = destinationURL.appendingPathComponent(name, isDirectory: true).standardizedFileURL; let recording = folder.appendingPathComponent(recordingName).standardizedFileURL; guard mediaValidator(recording) else { throw RecordingPublicationError.invalidMedia }; return .init(itemID: itemID, folderURL: folder, recordingURL: recording) }
        return nil
    }

    private func readAll(_ fd: Int32) -> Data { var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384); while true { let count = Darwin.read(fd, &buffer, buffer.count); if count <= 0 { return data }; data.append(buffer, count: Int(count)) } }
    private func removeOwnedTree(named name: String, from directory: Int32) { let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { return }; removeTree(fd); Darwin.close(fd); _ = unlinkat(directory, name, AT_REMOVEDIR) }
    private func removeTree(_ directory: Int32) { let duplicate = dup(directory); guard duplicate >= 0 else { return }; _ = lseek(duplicate, 0, SEEK_SET); guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); return }; defer { closedir(stream) }; while let entry = readdir(stream) { let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) } }; guard name != ".", name != ".." else { continue }; var attributes = stat(); guard fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { continue }; if (attributes.st_mode & S_IFMT) == S_IFDIR { let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); if child >= 0 { removeTree(child); Darwin.close(child); _ = unlinkat(directory, name, AT_REMOVEDIR) } } else { _ = unlinkat(directory, name, 0) } } }
}
