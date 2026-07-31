import CryptoKit
import Foundation
import XCTest
@testable import RecorderApp

final class SecureTranscriptDocumentReaderTests: XCTestCase {
    func testReadsExactCanonicalFileAndProducesStableSHA256() throws {
        let fixture = try TranscriptReaderFixture()
        defer { fixture.remove() }
        let bytes = Data("會議內容".utf8)
        try bytes.write(to: fixture.transcriptURL)

        let snapshot = try SecureTranscriptDocumentReader().readCanonical(
            in: fixture.folder,
            allowLegacy: false
        )
        let expectedDigest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(snapshot.data, bytes)
        XCTAssertEqual(snapshot.revision.byteCount, bytes.count)
        XCTAssertEqual(snapshot.revision.sha256, "sha256:\(expectedDigest)")
    }

    func testRejectsCanonicalSymlinkWithoutReadingOutsideBytes() throws {
        let fixture = try TranscriptReaderFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.transcriptURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try SecureTranscriptDocumentReader().readCanonical(
                in: fixture.folder,
                allowLegacy: false
            )
        ) { XCTAssertEqual($0 as? SecureTranscriptReadError, .unsafeFile) }
    }

    func testRejectsDirectoryAndAdditionalHardLink() throws {
        let fixture = try TranscriptReaderFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.transcriptURL,
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(
            try SecureTranscriptDocumentReader().readCanonical(
                in: fixture.folder, allowLegacy: false
            )
        ) { XCTAssertEqual($0 as? SecureTranscriptReadError, .unsafeFile) }
        try FileManager.default.removeItem(at: fixture.transcriptURL)
        try Data("content".utf8).write(to: fixture.transcriptURL)
        try FileManager.default.linkItem(
            at: fixture.transcriptURL,
            to: fixture.folder.appendingPathComponent("second-link.txt")
        )
        XCTAssertThrowsError(
            try SecureTranscriptDocumentReader().readCanonical(
                in: fixture.folder, allowLegacy: false
            )
        ) { XCTAssertEqual($0 as? SecureTranscriptReadError, .unsafeFile) }
    }

    func testRejectsOversizedAndInvalidUTF8CanonicalFiles() throws {
        let fixture = try TranscriptReaderFixture()
        defer { fixture.remove() }
        try Data(repeating: 65, count: 4 * 1_024 * 1_024 + 1)
            .write(to: fixture.transcriptURL)
        XCTAssertThrowsError(
            try SecureTranscriptDocumentReader().readCanonical(
                in: fixture.folder, allowLegacy: false
            )
        ) { XCTAssertEqual($0 as? SecureTranscriptReadError, .tooLarge) }
        try Data([0xff]).write(to: fixture.transcriptURL)
        XCTAssertThrowsError(
            try SecureTranscriptDocumentReader().readCanonical(
                in: fixture.folder, allowLegacy: false
            )
        ) { XCTAssertEqual($0 as? SecureTranscriptReadError, .invalidUTF8) }
    }
}

private struct TranscriptReaderFixture {
    let root: URL
    let folder: URL
    let transcriptURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "secure-transcript-reader-\(UUID().uuidString)", isDirectory: true
        )
        folder = root.appendingPathComponent("meeting-test", isDirectory: true)
        transcriptURL = folder.appendingPathComponent("transcript.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
