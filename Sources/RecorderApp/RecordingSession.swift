import AVFoundation
import Foundation

struct RecordingSession: Identifiable, Hashable {
    let id: URL
    let folderURL: URL
    let recordingURL: URL
    let createdAt: Date
    let duration: TimeInterval
    let fileSize: Int64
    let metadata: RecordingSessionMetadata

    var displayName: String {
        metadata.title ?? folderURL.lastPathComponent
    }

    var tags: [String] { metadata.tags }
    var isFavorite: Bool { metadata.isFavorite }

    var durationText: String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

enum ManualTranscriptionImportError: LocalizedError {
    case missingSourceFile
    case unsupportedAudioFile

    var errorDescription: String? {
        switch self {
        case .missingSourceFile:
            return "Selected audio file was not found."
        case .unsupportedAudioFile:
            return "Selected file does not have a supported audio extension."
        }
    }
}

enum ManualTranscriptionImporter {
    static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "flac", "aac", "aiff", "aif", "caf"]

    static func importAudioFile(_ sourceURL: URL, into baseFolder: URL, now: Date = Date()) throws -> RecordingSession {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ManualTranscriptionImportError.missingSourceFile
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw ManualTranscriptionImportError.unsupportedAudioFile
        }

        let folder = baseFolder
            .appendingPathComponent("manual-\(folderStamp.string(from: now))", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let recordingURL = folder.appendingPathComponent("recording.\(fileExtension)")
        if fileManager.fileExists(atPath: recordingURL.path) {
            try fileManager.removeItem(at: recordingURL)
        }
        try fileManager.copyItem(at: sourceURL, to: recordingURL)

        return RecordingSessionStore.session(for: folder, recordingURL: recordingURL)
    }

    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

enum RecordingSessionStore {
    private static let supportedFolderPrefixes = ["meeting-", "test-", "manual-"]

    static func load(from baseFolder: URL) -> [RecordingSession] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: baseFolder,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return folders.compactMap { folder in
            guard supportedFolderPrefixes.contains(where: { folder.lastPathComponent.hasPrefix($0) }) else {
                return nil
            }
            guard let recordingURL = Self.recordingURL(in: folder) else { return nil }
            return Self.session(for: folder, recordingURL: recordingURL)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func session(for folder: URL, recordingURL: URL) -> RecordingSession {
        let folderValues = try? folder.resourceValues(forKeys: [.creationDateKey])
        let fileValues = try? recordingURL.resourceValues(forKeys: [.fileSizeKey])
        let duration = Self.duration(for: recordingURL)

        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: recordingURL,
            createdAt: folderValues?.creationDate ?? Date.distantPast,
            duration: duration,
            fileSize: Int64(fileValues?.fileSize ?? 0),
            metadata: RecordingSessionMetadataStore.load(in: folder)
        )
    }

    @discardableResult
    static func moveToTrash(folder: URL) throws -> Bool {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &resultingURL)
        return resultingURL != nil
    }

    private static func recordingURL(in folder: URL) -> URL? {
        let fileManager = FileManager.default
        for fileExtension in ManualTranscriptionImporter.supportedExtensions.sorted() {
            let candidate = folder.appendingPathComponent("recording.\(fileExtension)")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func duration(for url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration).isFinite ? CMTimeGetSeconds(asset.duration) : 0
    }
}
