import CryptoKit
import Darwin
import Foundation

struct TranscriptDocumentRevision: Equatable, Sendable { let sha256: String; let byteCount: Int }
struct TranscriptDocumentSnapshot: Equatable, Sendable { let url: URL; let data: Data; let revision: TranscriptDocumentRevision }
struct TranscriptPublicationIdentity: Equatable, Sendable { let coordinatorInstanceID: UUID; let generation: UInt64; let attemptID: UUID }
struct TranscriptPublished: Sendable { let session: RecordingSession; let canonicalURL: URL; let revision: TranscriptDocumentRevision; let normalizedSessionFolder: URL; let identity: TranscriptPublicationIdentity }
protocol TranscriptDocumentReading: Sendable { func readCanonical(in sessionFolder: URL, allowLegacy: Bool) throws -> TranscriptDocumentSnapshot }
enum SecureTranscriptReadError: LocalizedError, Equatable, Sendable { case missing, empty, tooLarge, invalidUTF8, unsafeFile, identityChanged }

struct SecureTranscriptDocumentReader: TranscriptDocumentReading {
    static let maximumBytes = 4 * 1_024 * 1_024
    func readCanonical(in sessionFolder: URL, allowLegacy: Bool) throws -> TranscriptDocumentSnapshot {
        let folder = sessionFolder.standardizedFileURL
        guard folder == sessionFolder.resolvingSymlinksInPath().standardizedFileURL else { throw SecureTranscriptReadError.unsafeFile }
        let folderFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folderFD >= 0 else { throw SecureTranscriptReadError.missing }
        defer { close(folderFD) }
        let names = [TranscriptDocumentStore.editableFileName]
            + (allowLegacy ? TranscriptDocumentStore.legacyTranscriptFileNames : [])
        var selectedName: String?
        var fd: Int32 = -1
        for name in names {
            let candidate = openat(folderFD, name, O_RDONLY | O_NOFOLLOW)
            if candidate >= 0 {
                selectedName = name
                fd = candidate
                break
            }
            if errno != ENOENT { throw SecureTranscriptReadError.unsafeFile }
        }
        guard let selectedName, fd >= 0 else { throw SecureTranscriptReadError.missing }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1 else { throw SecureTranscriptReadError.unsafeFile }
        guard before.st_size > 0 else { throw SecureTranscriptReadError.empty }
        guard before.st_size <= off_t(Self.maximumBytes) else { throw SecureTranscriptReadError.tooLarge }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= Self.maximumBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw SecureTranscriptReadError.unsafeFile }
            if count == 0 { break }; data.append(buffer, count: count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_nlink == after.st_nlink else { throw SecureTranscriptReadError.identityChanged }
        guard data.count <= Self.maximumBytes else { throw SecureTranscriptReadError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw SecureTranscriptReadError.invalidUTF8 }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(url: folder.appendingPathComponent(selectedName), data: data, revision: .init(sha256: "sha256:\(hash)", byteCount: data.count))
    }
}
