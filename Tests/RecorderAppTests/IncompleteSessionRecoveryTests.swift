@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import RecorderApp

final class IncompleteSessionRecoveryTests: XCTestCase {
    func testPromotesValidBackupAndWritesRecoveryMetadata() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "meeting-interrupted")
        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        try writeValidM4A(to: backup)

        IncompleteSessionRecovery().recover(in: root)

        let final = folder.appendingPathComponent("recording.m4a")
        XCTAssertTrue(RecordingSessionStore.isRegularFile(final))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(RecordingSessionMetadataStore.load(in: folder).recoveryState, .recoveredAfterInterruption)
    }

    func testInvalidBackupAndPartialAreRetained() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "meeting-interrupted")
        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        let partial = folder.appendingPathComponent("recording.partial.mp4")
        try Data([1, 2, 3]).write(to: backup)
        try Data([4, 5, 6]).write(to: partial)

        IncompleteSessionRecovery().recover(in: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.m4a").path))
    }

    func testExistingFinalWinsWithoutChangingBackupOrMetadata() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "meeting-interrupted")
        let final = folder.appendingPathComponent("recording.m4a")
        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        let original = Data([9, 8, 7])
        try original.write(to: final)
        try writeValidM4A(to: backup)
        try RecordingSessionMetadataStore.save(.init(recoveryState: .none), in: folder)

        IncompleteSessionRecovery().recover(in: root)

        XCTAssertEqual(try Data(contentsOf: final), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(RecordingSessionMetadataStore.load(in: folder).recoveryState, .none)
    }

    func testEveryExistingManualFinalWinsWithoutChangingBackupOrMetadata() throws {
        let root = try makeRoot()
        let extensions = ManualTranscriptionImporter.supportedExtensions.sorted()
        for (index, fileExtension) in extensions.enumerated() {
            let folder = try makeFolder(in: root, name: "manual-final-\(fileExtension)")
            let final = folder.appendingPathComponent("recording.\(fileExtension)")
            let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
            let original = Data([7, 8, UInt8(index)])
            try original.write(to: final)
            try writeValidM4A(to: backup)

            IncompleteSessionRecovery().recover(in: root)

            XCTAssertEqual(try Data(contentsOf: final), original, fileExtension)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), fileExtension)
            XCTAssertEqual(RecordingSessionMetadataStore.load(in: folder).recoveryState, .none, fileExtension)
        }
    }

    func testNoReplacePromotionPreservesFinalCreatedAfterValidation() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "meeting-race")
        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        let final = folder.appendingPathComponent("recording.m4a")
        let racedFinal = Data([6, 5, 4])
        try writeValidM4A(to: backup)

        let recovery = IncompleteSessionRecovery(beforeNoReplaceRename: { _, destination in
            try racedFinal.write(to: destination)
        })
        recovery.recover(in: root)

        XCTAssertEqual(try Data(contentsOf: final), racedFinal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(RecordingSessionMetadataStore.load(in: folder).recoveryState, .none)
    }

    func testNoReplacePromotionRejectsSymlinkDestinationWithoutFollowingIt() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "meeting-symlink")
        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        let target = folder.appendingPathComponent("target.m4a")
        let final = folder.appendingPathComponent("recording.m4a")
        let targetContents = Data([1, 3, 5])
        try writeValidM4A(to: backup)
        try targetContents.write(to: target)
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: target)

        IncompleteSessionRecovery().recover(in: root)

        XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: final.path).hasSuffix("target.m4a"))
        XCTAssertEqual(try Data(contentsOf: target), targetContents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(RecordingSessionMetadataStore.load(in: folder).recoveryState, .none)
    }

    func testNoReplacePromotionRejectsDirectoryDestination() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "meeting-directory")
        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        let final = folder.appendingPathComponent("recording.m4a")
        try writeValidM4A(to: backup)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)

        IncompleteSessionRecovery().recover(in: root)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(RecordingSessionMetadataStore.load(in: folder).recoveryState, .none)
    }

    func testMetadataFailureKeepsPromotedFinalAndSecondLaunchIsIdempotent() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "meeting-interrupted")
        let backup = folder.appendingPathComponent("recording.audio-backup.m4a")
        try writeValidM4A(to: backup)
        let recovery = IncompleteSessionRecovery(metadataSaver: { _, _ in throw TestError.metadata })

        recovery.recover(in: root)
        let final = folder.appendingPathComponent("recording.m4a")
        let firstContents = try Data(contentsOf: final)
        recovery.recover(in: root)

        XCTAssertEqual(try Data(contentsOf: final), firstContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testOnlySupportedSessionFoldersAreScanned() throws {
        let root = try makeRoot()
        let folder = try makeFolder(in: root, name: "other-interrupted")
        try writeValidM4A(to: folder.appendingPathComponent("recording.audio-backup.m4a"))

        IncompleteSessionRecovery().recover(in: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.audio-backup.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.m4a").path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeFolder(in root: URL, name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeValidM4A(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        try file.write(from: buffer)
    }

    private enum TestError: Error { case metadata }
}
