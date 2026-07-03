import AVFoundation
import Foundation

struct RecordingSession: Identifiable, Hashable {
    let id: URL
    let folderURL: URL
    let recordingURL: URL
    let createdAt: Date
    let duration: TimeInterval
    let fileSize: Int64

    var displayName: String {
        folderURL.lastPathComponent
    }

    var durationText: String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

enum RecordingSessionStore {
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
            guard folder.lastPathComponent.hasPrefix("meeting-") || folder.lastPathComponent.hasPrefix("test-") else {
                return nil
            }
            let recordingURL = folder.appendingPathComponent("recording.m4a")
            guard fileManager.fileExists(atPath: recordingURL.path) else { return nil }

            let folderValues = try? folder.resourceValues(forKeys: [.creationDateKey])
            let fileValues = try? recordingURL.resourceValues(forKeys: [.fileSizeKey])
            let duration = Self.duration(for: recordingURL)

            return RecordingSession(
                id: folder,
                folderURL: folder,
                recordingURL: recordingURL,
                createdAt: folderValues?.creationDate ?? Date.distantPast,
                duration: duration,
                fileSize: Int64(fileValues?.fileSize ?? 0)
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private static func duration(for url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration).isFinite ? CMTimeGetSeconds(asset.duration) : 0
    }
}
