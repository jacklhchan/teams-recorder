import AVFoundation
import Darwin
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
    var mediaKind: RecordingMediaKind { metadata.mediaKind }
    var screenIntervals: [RecordedScreenInterval] { metadata.screenIntervals }
    var capturedTeamsWindow: RecordedTeamsWindowIdentity? { metadata.capturedTeamsWindow }
    var recoveryState: RecordingRecoveryState { metadata.recoveryState }

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
            guard isSupportedSessionFolder(folder) else {
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
        var metadata = RecordingSessionMetadataStore.load(in: folder)
        if recordingURL.lastPathComponent == "recording.mp4", !metadata.screenIntervals.isEmpty {
            metadata.mediaKind = .video
        } else {
            metadata.mediaKind = .audio
            metadata.screenIntervals = []
            metadata.capturedTeamsWindow = nil
        }

        return RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: recordingURL,
            createdAt: folderValues?.creationDate ?? Date.distantPast,
            duration: duration,
            fileSize: Int64(fileValues?.fileSize ?? 0),
            metadata: metadata
        )
    }

    @discardableResult
    static func moveToTrash(folder: URL) throws -> Bool {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &resultingURL)
        return resultingURL != nil
    }

    static func isSupportedSessionFolder(_ folder: URL) -> Bool {
        supportedFolderPrefixes.contains { folder.lastPathComponent.hasPrefix($0) }
            && isRegularFile(folder, directory: true)
    }

    static func recordingURL(in folder: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for fileName in ["recording.mp4", "recording.m4a"] {
            guard let candidate = contents.first(where: { $0.lastPathComponent == fileName }) else { continue }
            if isRegularFile(candidate) { return candidate }
        }
        for fileExtension in ManualTranscriptionImporter.supportedExtensions.sorted() where fileExtension != "m4a" {
            let fileName = "recording.\(fileExtension)"
            guard let candidate = contents.first(where: { $0.lastPathComponent == fileName }) else { continue }
            if isRegularFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func isRegularFile(_ url: URL, directory: Bool = false) -> Bool {
        var attributes = stat()
        guard url.path.withCString({ lstat($0, &attributes) }) == 0 else { return false }
        if directory { return (attributes.st_mode & S_IFMT) == S_IFDIR }
        return (attributes.st_mode & S_IFMT) == S_IFREG
    }

    private static func duration(for url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration).isFinite ? CMTimeGetSeconds(asset.duration) : 0
    }
}
