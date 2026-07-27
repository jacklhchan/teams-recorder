import AVFoundation
import Darwin
import Foundation

struct IncompleteSessionRecovery {
    typealias MetadataSaver = (RecordingSessionMetadata, URL) throws -> Void
    typealias BeforeNoReplaceRename = (URL, URL) throws -> Void

    private let fileManager: FileManager
    private let metadataSaver: MetadataSaver
    private let beforeNoReplaceRename: BeforeNoReplaceRename?

    init(
        fileManager: FileManager = .default,
        metadataSaver: @escaping MetadataSaver = RecordingSessionMetadataStore.save,
        beforeNoReplaceRename: BeforeNoReplaceRename? = nil
    ) {
        self.fileManager = fileManager
        self.metadataSaver = metadataSaver
        self.beforeNoReplaceRename = beforeNoReplaceRename
    }

    func recover(in baseFolder: URL) {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: baseFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for folder in folders where RecordingSessionStore.isSupportedSessionFolder(folder) {
            recoverSession(in: folder)
        }
    }

    private func recoverSession(in folder: URL) {
        let finalM4A = folder.appendingPathComponent("recording.m4a")
        guard RecordingSessionStore.recordingURL(in: folder) == nil else { return }

        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        guard isValidBackup(backup) else { return }
        guard promoteNoReplace(backup, to: finalM4A) else { return }

        var metadata = RecordingSessionMetadataStore.load(in: folder)
        metadata.recoveryState = .recoveredAfterInterruption
        try? metadataSaver(metadata, folder)
    }

    private func isValidBackup(_ url: URL) -> Bool {
        guard RecordingSessionStore.isRegularFile(url),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              file.processingFormat.sampleRate.isFinite,
              file.processingFormat.sampleRate > 0,
              file.processingFormat.channelCount >= 1 else {
            return false
        }
        return true
    }

    private func promoteNoReplace(_ source: URL, to destination: URL) -> Bool {
        guard RecordingSessionStore.isRegularFile(source),
              source.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            return false
        }
        var destinationAttributes = stat()
        if destination.path.withCString({ lstat($0, &destinationAttributes) }) == 0 {
            return false
        }
        guard errno == ENOENT else { return false }

        do {
            try beforeNoReplaceRename?(source, destination)
        } catch {
            return false
        }

        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        return result == 0
    }
}
