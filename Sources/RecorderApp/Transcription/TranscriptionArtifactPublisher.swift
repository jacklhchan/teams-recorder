import Darwin
import Foundation

struct TranscriptionPublicationManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let model: String
    let language: String
    let chunkCount: Int
    let responseFormats: [String]

    init(
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        model: String,
        language: String,
        chunkCount: Int,
        responseFormats: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.model = model
        self.language = language
        self.chunkCount = chunkCount
        self.responseFormats = responseFormats
    }
}

struct PublishedTranscriptionArtifacts: Equatable, Sendable {
    let transcriptURL: URL
    let rawTranscriptURL: URL
    let manifestURL: URL
    let logURL: URL
    let committedTranscriptRevision: TranscriptDocumentRevision
}

enum TranscriptionArtifactPublicationError:
    LocalizedError,
    Equatable
{
    case unsafeExistingArtifact(String)

    var errorDescription: String? {
        switch self {
        case .unsafeExistingArtifact(let name):
            "Refusing to replace unsafe transcription artifact \(name)."
        }
    }
}

struct TranscriptionArtifactPublisher: @unchecked Sendable {
    static let canonicalNames = [
        "transcript.raw.txt",
        "transcript.txt",
        "transcription.json",
        "transcription.log"
    ]

    let maximumBackupsPerArtifact: Int
    private let fileManager: FileManager
    private let mutationGate: RecordingSessionMutationGate

    init(
        maximumBackupsPerArtifact: Int = 3,
        fileManager: FileManager = .default,
        mutationGate: RecordingSessionMutationGate = .init()
    ) {
        self.maximumBackupsPerArtifact = max(
            0,
            maximumBackupsPerArtifact
        )
        self.fileManager = fileManager
        self.mutationGate = mutationGate
    }

    func publish(
        rawText: String,
        finalText: String,
        manifest: TranscriptionPublicationManifest,
        logLines: [String],
        sessionFolder: URL,
        now: Date = Date()
    ) throws -> PublishedTranscriptionArtifacts {
        try mutationGate.withMutation(for: sessionFolder) {
        let staging = sessionFolder.appendingPathComponent(
            ".transcription-publish-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let contents: [(String, Data)] = [
            ("transcript.raw.txt", Data(rawText.utf8)),
            ("transcript.txt", Data(finalText.utf8)),
            ("transcription.json", try encoder.encode(manifest)),
            (
                "transcription.log",
                Data(
                    sanitizedLog(logLines)
                        .joined(separator: "\n")
                        .appending("\n")
                        .utf8
                )
            )
        ]
        for (name, data) in contents {
            try data.write(
                to: staging.appendingPathComponent(name),
                options: .atomic
            )
        }

        for (name, _) in contents {
            let destination = sessionFolder.appendingPathComponent(name)
            try validateExistingArtifact(destination)
            if fileManager.fileExists(atPath: destination.path) {
                let backup = sessionFolder.appendingPathComponent(
                    "\(name).previous-\(backupStamp(now))-\(UUID().uuidString)"
                )
                try fileManager.copyItem(
                    at: destination,
                    to: backup
                )
            }
        }
        for (name, _) in contents {
            let staged = staging.appendingPathComponent(name)
            let destination = sessionFolder.appendingPathComponent(name)
            let data = try Data(contentsOf: staged)
            try data.write(to: destination, options: .atomic)
            try pruneBackups(for: name, in: sessionFolder)
        }
        try expireLegacyRuns(
            in: sessionFolder,
            olderThan: 7 * 86_400,
            now: now
        )

        let revision = try SecureTranscriptDocumentReader().readCanonical(
            in: sessionFolder,
            allowLegacy: false
        ).revision
        return .init(
            transcriptURL: sessionFolder.appendingPathComponent(
                "transcript.txt"
            ),
            rawTranscriptURL: sessionFolder.appendingPathComponent(
                "transcript.raw.txt"
            ),
            manifestURL: sessionFolder.appendingPathComponent(
                "transcription.json"
            ),
            logURL: sessionFolder.appendingPathComponent(
                "transcription.log"
            ),
            committedTranscriptRevision: revision
        )
        }
    }

    func expireLegacyRuns(
        in sessionFolder: URL,
        olderThan age: TimeInterval,
        now: Date = Date()
    ) throws {
        let runs = sessionFolder.appendingPathComponent(
            ".transcription-runs",
            isDirectory: true
        )
        var attributes = stat()
        guard runs.path.withCString({
            lstat($0, &attributes)
        }) == 0, (attributes.st_mode & S_IFMT) == S_IFDIR else {
            return
        }
        let children = try fileManager.contentsOfDirectory(
            at: runs,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > age else {
                continue
            }
            try fileManager.removeItem(at: child)
        }
    }

    private func validateExistingArtifact(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard RecordingSessionStore.isRegularFile(url) else {
            throw TranscriptionArtifactPublicationError
                .unsafeExistingArtifact(url.lastPathComponent)
        }
    }

    private func pruneBackups(
        for canonicalName: String,
        in sessionFolder: URL
    ) throws {
        let prefix = "\(canonicalName).previous-"
        let backups = try fileManager.contentsOfDirectory(
            at: sessionFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix(prefix)
                && RecordingSessionStore.isRegularFile($0)
        }
        .sorted {
            $0.lastPathComponent > $1.lastPathComponent
        }
        for backup in backups.dropFirst(maximumBackupsPerArtifact) {
            try fileManager.removeItem(at: backup)
        }
    }

    private func sanitizedLog(_ lines: [String]) -> [String] {
        var retainedBytes = 0
        var result: [String] = []
        for line in lines {
            let sanitized = String(
                line
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(1_000)
            )
            let bytes = sanitized.utf8.count + 1
            guard retainedBytes + bytes <= 64 * 1_024 else { break }
            retainedBytes += bytes
            result.append(sanitized)
        }
        return result
    }

    private func backupStamp(_ date: Date) -> String {
        Self.backupFormatter.string(from: date)
    }

    private static let backupFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return formatter
    }()
}
