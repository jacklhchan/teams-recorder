import Foundation
import XCTest
@testable import RecorderApp

final class TranscriptionProcessTests: XCTestCase {
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
                folderURL: root
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

private final class LockedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}
