@preconcurrency import AVFoundation
import XCTest
@testable import RecorderApp

final class MixedAudioWriterTests: XCTestCase {
    func testDefaultBitrateUses192KbpsSettings() throws {
        let settings = try AACMixedAudioWriter.outputSettings()

        XCTAssertEqual(settings.bitRate, 192_000)
        XCTAssertEqual(settings.sampleRate, 48_000)
        XCTAssertEqual(settings.channelCount, 2)
    }

    func testExplicit128KbpsBitrateIsReflectedInSettings() throws {
        let settings = try AACMixedAudioWriter.outputSettings(bitRate: 128_000)

        XCTAssertEqual(settings.bitRate, 128_000)
        XCTAssertEqual(settings.sampleRate, 48_000)
        XCTAssertEqual(settings.channelCount, 2)
    }

    func testExplicit128KbpsBitrateIsPassedToAVAudioFileSettings() throws {
        let settings = try AACMixedAudioWriter.outputSettings(bitRate: 128_000)
        let avSettings = settings.avFoundationSettings

        XCTAssertEqual(avSettings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(avSettings[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(avSettings[AVNumberOfChannelsKey] as? AVAudioChannelCount, 2)
        XCTAssertEqual(avSettings[AVEncoderBitRateKey] as? Int, 128_000)
    }

    func testNonPositiveBitrateReturnsTypedError() {
        XCTAssertThrowsError(try AACMixedAudioWriter.outputSettings(bitRate: 0)) {
            XCTAssertEqual($0 as? AACMixedAudioWriterError, .invalidBitRate(0))
        }
        XCTAssertThrowsError(try AACMixedAudioWriter.outputSettings(bitRate: -1)) {
            XCTAssertEqual($0 as? AACMixedAudioWriterError, .invalidBitRate(-1))
        }
    }

    func testClosedWriterRejectsAdditionalBlocks() throws {
        let fixture = try makeWriter()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        try fixture.writer.close()

        XCTAssertThrowsError(try fixture.writer.write(block(frameCount: 4))) {
            XCTAssertEqual($0 as? AACMixedAudioWriterError, .closed)
        }
    }

    func testMalformedBlocksReturnTypedErrors() throws {
        let fixture = try makeWriter()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        XCTAssertThrowsError(try fixture.writer.write(
            MixedAudioBlock(startFrame: 0, left: [], right: [])
        )) {
            XCTAssertEqual($0 as? AACMixedAudioWriterError, .emptyBlock)
        }
        XCTAssertThrowsError(try fixture.writer.write(
            MixedAudioBlock(startFrame: 0, left: [0.25, 0.25], right: [0.25])
        )) {
            XCTAssertEqual(
                $0 as? AACMixedAudioWriterError,
                .mismatchedChannelFrameCounts(left: 2, right: 1)
            )
        }
    }

    func testAACWriterProducesReopenableBoundedStereoContainer() throws {
        let fixture = try makeWriter()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let framesPerBlock = 2_400

        try fixture.writer.write(block(frameCount: framesPerBlock, value: 0.2))
        try fixture.writer.write(block(
            startFrame: Int64(framesPerBlock),
            frameCount: framesPerBlock,
            value: -0.2
        ))
        try fixture.writer.close()

        let file = try AVAudioFile(forReading: fixture.url)
        let formatID = file.fileFormat.streamDescription.pointee.mFormatID
        let duration = Double(file.length) / file.fileFormat.sampleRate

        XCTAssertEqual(formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000, accuracy: 0.01)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertLessThanOrEqual(file.length, AVAudioFramePosition(framesPerBlock * 2 + 2_048))
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThan(duration, 0.2)
    }

    func test128KbpsAACWriterProducesReopenableStereoContainer() throws {
        let fixture = try makeWriter(bitRate: 128_000)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        try fixture.writer.write(block(frameCount: 4_800, value: 0.2))
        try fixture.writer.close()

        let file = try AVAudioFile(forReading: fixture.url)

        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000, accuracy: 0.01)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertGreaterThan(file.length, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(
            byteCount,
            0
        )
    }

    private func makeWriter(bitRate: Int? = nil) throws -> (
        writer: AACMixedAudioWriter,
        url: URL,
        folder: URL
    ) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let url = folder.appendingPathComponent("recording.m4a")
        let writer: AACMixedAudioWriter
        if let bitRate {
            writer = try AACMixedAudioWriter(url: url, bitRate: bitRate)
        } else {
            writer = try AACMixedAudioWriter(url: url)
        }
        return (writer, url, folder)
    }

    private func block(
        startFrame: Int64 = 0,
        frameCount: Int,
        value: Float = 0.25
    ) -> MixedAudioBlock {
        MixedAudioBlock(
            startFrame: startFrame,
            left: Array(repeating: value, count: frameCount),
            right: Array(repeating: value, count: frameCount)
        )
    }

}
