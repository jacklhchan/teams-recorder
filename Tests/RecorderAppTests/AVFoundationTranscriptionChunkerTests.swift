import AVFoundation
import XCTest
@testable import RecorderApp

final class AVFoundationTranscriptionChunkerTests: XCTestCase {
    func testPlannerSplitsTwoHundredFortyOneSecondsIntoBoundedRanges() {
        let ranges = TranscriptionChunkPlanner.plan(
            duration: 241,
            maximumDuration: 120
        )

        XCTAssertEqual(
            ranges,
            [
                .init(start: 0, duration: 120),
                .init(start: 120, duration: 120),
                .init(start: 240, duration: 1)
            ]
        )
    }

    func testShortAudioPassesThroughWithoutWorkspaceArtifact() async throws {
        let fixture = try makeFixture(duration: 0.2)
        defer { fixture.remove() }
        let chunker = AVFoundationTranscriptionChunker(
            maximumDuration: 1
        )

        let chunks = try await chunker.chunks(
            for: fixture.audioURL,
            workspaceURL: fixture.workspaceURL
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.url, fixture.audioURL)
        XCTAssertFalse(chunks.first?.requiresCleanup ?? true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspaceURL.path
            )
        )
    }

    func testLongAudioExportsReopenableBoundedM4AChunks() async throws {
        let fixture = try makeFixture(duration: 0.32)
        defer { fixture.remove() }
        let chunker = AVFoundationTranscriptionChunker(
            maximumDuration: 0.15
        )

        let chunks = try await chunker.chunks(
            for: fixture.audioURL,
            workspaceURL: fixture.workspaceURL
        )

        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy(\.requiresCleanup))
        for chunk in chunks {
            let file = try AVAudioFile(forReading: chunk.url)
            XCTAssertGreaterThan(file.length, 0)
            XCTAssertLessThanOrEqual(chunk.duration, 0.15)
        }
    }

    func testShortOversizedInputIsCompressedInsteadOfPassedThrough() async throws {
        let fixture = try makeFixture(duration: 0.2)
        defer { fixture.remove() }
        let chunker = AVFoundationTranscriptionChunker(
            maximumDuration: 1,
            maximumPassthroughBytes: 1
        )

        let chunks = try await chunker.chunks(
            for: fixture.audioURL,
            workspaceURL: fixture.workspaceURL
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertNotEqual(chunks.first?.url, fixture.audioURL)
        XCTAssertTrue(chunks.first?.requiresCleanup == true)
        XCTAssertGreaterThan(
            try XCTUnwrap(
                chunks.first?.url.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize
            ),
            0
        )
    }

    private func makeFixture(
        duration: TimeInterval
    ) throws -> ChunkerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "transcription-chunker-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let audioURL = root.appendingPathComponent("source.m4a")
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1
            )
        )
        let file = try AVAudioFile(
            forWriting: audioURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
        )
        let frameCount = AVAudioFrameCount(duration * 48_000)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        )
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                channel[frame] = sin(Float(frame) * 0.01) * 0.1
            }
        }
        try file.write(from: buffer)
        return .init(
            root: root,
            audioURL: audioURL,
            workspaceURL: root.appendingPathComponent(
                "workspace",
                isDirectory: true
            )
        )
    }
}

private struct ChunkerFixture {
    let root: URL
    let audioURL: URL
    let workspaceURL: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
