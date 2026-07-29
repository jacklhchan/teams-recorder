import Foundation
import XCTest
@testable import RecorderApp

final class TranscriptionProcessTests: XCTestCase {
    func testConfigurationArrivesOnlyThroughPrivateStdin() async throws {
        let fixture = try StdinFixture.make()
        defer { fixture.remove() }
        let secret = "private-api-key"
        let payload = Data(#"{"apiKey":"private-api-key","asrModel":"asr"}"#.utf8)
        let process = try FoundationTranscriptionProcessLauncher().makeProcess(
            request: .init(
                scriptURL: fixture.scriptURL,
                audioURL: fixture.audioURL,
                folderURL: fixture.root,
                configurationInput: payload
            ),
            onOutput: { _ in }
        )

        try process.run()
        let result = await process.waitForExit()

        XCTAssertEqual(try Data(contentsOf: fixture.stdinCaptureURL), payload)
        let metadata = try String(
            contentsOf: fixture.metadataCaptureURL,
            encoding: .utf8
        )
        XCTAssertFalse(metadata.contains(secret))
        XCTAssertFalse(result.output.contains(secret))
    }

    func testWaitForExitReturnsFullyDrainedOutputWithoutTrailingNewline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("emit-final-output.sh")
        let expectedOutput = """
        STATUS=Processing transcript
        TRANSCRIPT_PATH=/tmp/final-transcript.txt
        """
        let script = """
        #!/bin/bash
        printf 'STATUS=Processing transcript\\n'
        printf 'TRANSCRIPT_PATH=/tmp/final-transcript.txt'
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let liveOutput = LockedOutput()
        let process = try FoundationTranscriptionProcessLauncher().makeProcess(
            request: .init(
                scriptURL: scriptURL,
                audioURL: root.appendingPathComponent("recording.m4a"),
                folderURL: root,
                configurationInput: Data()
            ),
            onOutput: { liveOutput.append($0) }
        )

        try process.run()
        let result = await process.waitForExit()

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.output, expectedOutput)
        XCTAssertEqual(liveOutput.value, expectedOutput)
    }
}

private struct StdinFixture {
    let root: URL
    let scriptURL: URL
    let audioURL: URL
    let stdinCaptureURL: URL
    let metadataCaptureURL: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-stdin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("capture-stdin.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        OUTPUT_FOLDER="$2"
        /bin/cat > "${OUTPUT_FOLDER}/stdin-capture"
        /usr/bin/printf '%s\\n' "$@" > "${OUTPUT_FOLDER}/metadata-capture"
        /usr/bin/env >> "${OUTPUT_FOLDER}/metadata-capture"
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return .init(
            root: root,
            scriptURL: scriptURL,
            audioURL: root.appendingPathComponent("recording.m4a"),
            stdinCaptureURL: root.appendingPathComponent("stdin-capture"),
            metadataCaptureURL: root.appendingPathComponent("metadata-capture")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LockedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var value: String {
        lock.withLock { storage.joined(separator: "\n") }
    }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}
