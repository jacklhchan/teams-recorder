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

    func testReadsNoMoreThanSingleOverflowByteWhenFileGrowsAfterInitialStatus() throws {
        let fixture = try TranscriptReaderFixture()
        defer { fixture.remove() }
        let access = ControlledTranscriptFileAccess(
            statuses: [
                .regular(byteCount: Int64(SecureTranscriptDocumentReader.maximumBytes)),
                .regular(byteCount: Int64(SecureTranscriptDocumentReader.maximumBytes + 1))
            ],
            chunks: Array(
                repeating: Data(repeating: 65, count: 64 * 1_024),
                count: SecureTranscriptDocumentReader.maximumBytes / (64 * 1_024)
            ) + [Data([66])]
        )

        XCTAssertThrowsError(
            try SecureTranscriptDocumentReader(fileAccess: access).readCanonical(
                in: fixture.folder,
                allowLegacy: false
            )
        ) { XCTAssertEqual($0 as? SecureTranscriptReadError, .tooLarge) }
        XCTAssertEqual(
            access.readLimits.last,
            1
        )
        XCTAssertTrue(access.readLimits.allSatisfy { $0 <= 64 * 1_024 })
    }

    func testRejectsDeterministicIdentityChangeAfterRead() throws {
        let fixture = try TranscriptReaderFixture()
        defer { fixture.remove() }
        let bytes = Data("stable bytes".utf8)
        let access = ControlledTranscriptFileAccess(
            statuses: [
                .regular(inode: 101, byteCount: Int64(bytes.count)),
                .regular(inode: 202, byteCount: Int64(bytes.count))
            ],
            chunks: [bytes, Data()]
        )

        XCTAssertThrowsError(
            try SecureTranscriptDocumentReader(fileAccess: access).readCanonical(
                in: fixture.folder,
                allowLegacy: false
            )
        ) { XCTAssertEqual($0 as? SecureTranscriptReadError, .identityChanged) }
    }
}

private final class ControlledTranscriptFileAccess:
    TranscriptFileAccessing,
    @unchecked Sendable
{
    private var statuses: [TranscriptFileStatus]
    private var chunks: [Data]
    private(set) var readLimits: [Int] = []

    init(statuses: [TranscriptFileStatus], chunks: [Data]) {
        self.statuses = statuses
        self.chunks = chunks
    }

    func openFolder(at path: String) -> Int32 { 10 }

    func openFile(named name: String, in folderDescriptor: Int32) -> Int32 {
        11
    }

    func status(of descriptor: Int32) -> TranscriptFileStatus? {
        guard !statuses.isEmpty else { return nil }
        return statuses.removeFirst()
    }

    func read(from descriptor: Int32, maximumByteCount: Int) -> Data {
        readLimits.append(maximumByteCount)
        return chunks.removeFirst()
    }

    func close(_ descriptor: Int32) {}
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
