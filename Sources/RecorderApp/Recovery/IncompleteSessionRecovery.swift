import AVFoundation
import Darwin
import Foundation

struct IncompleteSessionRecovery {
    typealias MetadataSaver = (RecordingSessionMetadata, URL) throws -> Void
    typealias BeforeNoReplaceRename = (URL, URL) throws -> Void
    typealias DescriptorBackupValidator = (Int32) -> Bool

    private let fileManager: FileManager
    private let metadataSaver: MetadataSaver
    private let beforeNoReplaceRename: BeforeNoReplaceRename?
    private let descriptorBackupValidator: DescriptorBackupValidator

    init(
        fileManager: FileManager = .default,
        metadataSaver: @escaping MetadataSaver = RecordingSessionMetadataStore.save,
        beforeNoReplaceRename: BeforeNoReplaceRename? = nil,
        descriptorBackupValidator: @escaping DescriptorBackupValidator = Self.liveDescriptorBackupValidator
    ) {
        self.fileManager = fileManager
        self.metadataSaver = metadataSaver
        self.beforeNoReplaceRename = beforeNoReplaceRename
        self.descriptorBackupValidator = descriptorBackupValidator
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

    /// Pending-session recovery deliberately operates on the retained descriptor.
    /// It does not use `displayURL`, which may have been replaced after admission.
    func recover(in session: RecordingPendingSession) {
        let finalName = "recording.m4a"
        let backupName = "recording.audio-backup.m4a"
        guard regularFile(named: backupName, in: session.fileDescriptor),
              !hasAnyFinal(in: session.fileDescriptor),
              validBackup(named: backupName, in: session.fileDescriptor) else { return }
        _ = renameatx_np(session.fileDescriptor, backupName, session.fileDescriptor, finalName, UInt32(RENAME_EXCL))
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

    private func regularFile(named name: String, in directory: Int32) -> Bool {
        var attributes = stat()
        return fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 && (attributes.st_mode & S_IFMT) == S_IFREG
    }

    private func hasAnyFinal(in directory: Int32) -> Bool {
        (["recording.mp4", "recording.m4a"] + ManualTranscriptionImporter.supportedExtensions.sorted().filter { $0 != "m4a" }.map { "recording.\($0)" })
            .contains { regularFile(named: $0, in: directory) }
    }

    private func validBackup(named name: String, in directory: Int32) -> Bool {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return descriptorBackupValidator(descriptor)
    }

    private static func liveDescriptorBackupValidator(_ descriptor: Int32) -> Bool {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: "/dev/fd/\(descriptor)")),
              file.length > 0,
              file.processingFormat.sampleRate.isFinite,
              file.processingFormat.sampleRate > 0,
              file.processingFormat.channelCount >= 1 else { return false }
        return true
    }
}
