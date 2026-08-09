import CryptoKit
import Darwin
import Foundation

struct TranscriptDocumentRevision: Equatable, Hashable, Sendable {
    let sha256: String
    let byteCount: Int
}

struct TranscriptDocumentSnapshot: Equatable, Sendable {
    let url: URL
    let data: Data
    let revision: TranscriptDocumentRevision
}

struct WorkspacePublicationFence: Equatable, Hashable, Sendable {
    static let initial = WorkspacePublicationFence(revision: 0)

    let revision: UInt64

    func advanced() -> WorkspacePublicationFence {
        precondition(
            revision < UInt64.max,
            "Workspace publication revision exhausted."
        )
        return .init(revision: revision + 1)
    }
}

struct TranscriptPublicationIdentity: Equatable, Hashable, Sendable {
    let coordinatorInstanceID: UUID
    let generation: UInt64
    let attemptID: UUID
}

struct TranscriptPublished: Sendable {
    let session: RecordingSession
    let canonicalURL: URL
    let revision: TranscriptDocumentRevision
    let normalizedSessionFolder: URL
    let identity: TranscriptPublicationIdentity
    let workspaceFence: WorkspacePublicationFence

    init(
        session: RecordingSession,
        canonicalURL: URL,
        revision: TranscriptDocumentRevision,
        normalizedSessionFolder: URL,
        identity: TranscriptPublicationIdentity,
        workspaceFence: WorkspacePublicationFence = .initial
    ) {
        self.session = session
        self.canonicalURL = canonicalURL
        self.revision = revision
        self.normalizedSessionFolder = normalizedSessionFolder
        self.identity = identity
        self.workspaceFence = workspaceFence
    }
}

protocol TranscriptDocumentReading: Sendable {
    func readCanonical(
        in sessionFolder: URL,
        allowLegacy: Bool
    ) throws -> TranscriptDocumentSnapshot
}

enum SecureTranscriptReadError: LocalizedError, Equatable, Sendable {
    case missing
    case empty
    case tooLarge
    case invalidUTF8
    case unsafeFile
    case identityChanged
}

struct TranscriptFileStatus: Equatable, Sendable {
    let device: Int64
    let inode: Int64
    let byteCount: Int64
    let linkCount: Int64
    let isRegularFile: Bool

    static func regular(
        device: Int64 = 1,
        inode: Int64 = 1,
        byteCount: Int64,
        linkCount: Int64 = 1
    ) -> TranscriptFileStatus {
        .init(
            device: device,
            inode: inode,
            byteCount: byteCount,
            linkCount: linkCount,
            isRegularFile: true
        )
    }
}

protocol TranscriptFileAccessing: Sendable {
    func openFolder(at path: String) -> Int32
    func openFile(named name: String, in folderDescriptor: Int32) -> Int32
    func status(of descriptor: Int32) -> TranscriptFileStatus?
    func read(from descriptor: Int32, maximumByteCount: Int) throws -> Data
    func close(_ descriptor: Int32)
}

struct DarwinTranscriptFileAccess: TranscriptFileAccessing {
    func openFolder(at path: String) -> Int32 {
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    }

    func openFile(named name: String, in folderDescriptor: Int32) -> Int32 {
        openat(folderDescriptor, name, O_RDONLY | O_NOFOLLOW)
    }

    func status(of descriptor: Int32) -> TranscriptFileStatus? {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { return nil }
        return .init(
            device: Int64(value.st_dev),
            inode: Int64(value.st_ino),
            byteCount: Int64(value.st_size),
            linkCount: Int64(value.st_nlink),
            isRegularFile: (value.st_mode & S_IFMT) == S_IFREG
        )
    }

    func read(from descriptor: Int32, maximumByteCount: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumByteCount)
        let count = Darwin.read(descriptor, &buffer, maximumByteCount)
        guard count >= 0 else { throw SecureTranscriptReadError.unsafeFile }
        return Data(buffer.prefix(count))
    }

    func close(_ descriptor: Int32) {
        Darwin.close(descriptor)
    }
}

struct SecureTranscriptDocumentReader: TranscriptDocumentReading {
    static let maximumBytes = 4 * 1_024 * 1_024

    private let fileAccess: any TranscriptFileAccessing

    init(fileAccess: any TranscriptFileAccessing = DarwinTranscriptFileAccess()) {
        self.fileAccess = fileAccess
    }

    func readCanonical(
        in sessionFolder: URL,
        allowLegacy: Bool
    ) throws -> TranscriptDocumentSnapshot {
        let folder = sessionFolder.standardizedFileURL
        guard folder == sessionFolder.resolvingSymlinksInPath().standardizedFileURL else {
            throw SecureTranscriptReadError.unsafeFile
        }
        let folderDescriptor = fileAccess.openFolder(at: folder.path)
        guard folderDescriptor >= 0 else {
            throw SecureTranscriptReadError.missing
        }
        defer { fileAccess.close(folderDescriptor) }

        let names = [TranscriptDocumentStore.editableFileName]
            + (allowLegacy ? TranscriptDocumentStore.legacyTranscriptFileNames : [])
        let opened = try openWhitelistedFile(
            named: names,
            in: folderDescriptor
        )
        defer { fileAccess.close(opened.descriptor) }

        let before = try validatedStatus(of: opened.descriptor)
        guard before.byteCount > 0 else {
            throw SecureTranscriptReadError.empty
        }
        guard before.byteCount <= Int64(Self.maximumBytes) else {
            throw SecureTranscriptReadError.tooLarge
        }

        var data = Data()
        let maximumReadBytes = Self.maximumBytes + 1
        while data.count < maximumReadBytes {
            let remaining = maximumReadBytes - data.count
            let chunk = try fileAccess.read(
                from: opened.descriptor,
                maximumByteCount: min(64 * 1_024, remaining)
            )
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= Self.maximumBytes else {
                throw SecureTranscriptReadError.tooLarge
            }
        }

        let after = try validatedStatus(of: opened.descriptor)
        guard before == after else {
            throw SecureTranscriptReadError.identityChanged
        }
        guard !data.isEmpty else {
            throw SecureTranscriptReadError.empty
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SecureTranscriptReadError.invalidUTF8
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return .init(
            url: folder.appendingPathComponent(opened.name),
            data: data,
            revision: .init(
                sha256: "sha256:\(digest)",
                byteCount: data.count
            )
        )
    }

    private func openWhitelistedFile(
        named names: [String],
        in folderDescriptor: Int32
    ) throws -> (name: String, descriptor: Int32) {
        for name in names {
            let descriptor = fileAccess.openFile(
                named: name,
                in: folderDescriptor
            )
            if descriptor >= 0 { return (name, descriptor) }
            if errno != ENOENT { throw SecureTranscriptReadError.unsafeFile }
        }
        throw SecureTranscriptReadError.missing
    }

    private func validatedStatus(
        of descriptor: Int32
    ) throws -> TranscriptFileStatus {
        guard let status = fileAccess.status(of: descriptor),
              status.isRegularFile,
              status.linkCount == 1 else {
            throw SecureTranscriptReadError.unsafeFile
        }
        return status
    }
}
