@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import XCTest
@testable import RecorderApp

final class TranscriptionAudioPreparerTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
        folders = []
        super.tearDown()
    }

    func testM4AAndManualAudioPassThroughWithoutCleanup() async throws {
        let m4a = try makeAudioFile(named: "recording.m4a")
        let wav = try makeAudioFile(named: "recording.wav")
        let preparer = TranscriptionAudioPreparer()

        let m4aPrepared = try await preparer.prepare(for: try makeSession(recordingURL: m4a))
        let wavPrepared = try await preparer.prepare(for: try makeSession(recordingURL: wav))

        XCTAssertEqual(m4aPrepared.audioURL, m4a)
        XCTAssertNil(m4aPrepared.cleanupURL)
        XCTAssertEqual(wavPrepared.audioURL, wav)
        XCTAssertNil(wavPrepared.cleanupURL)
    }

    func testMP4ExtractsReopenableAACToUniqueTemporaryM4AWithoutChangingSessionFolder() async throws {
        let mp4 = try makeMP4WithAudio(named: "recording.mp4")
        let session = try makeSession(recordingURL: mp4)
        let before = try directoryContents(of: session.folderURL)
        let preparer = TranscriptionAudioPreparer()

        let first = try await preparer.prepare(for: session)
        let second = try await preparer.prepare(for: session)
        defer {
            preparer.cleanup(first)
            preparer.cleanup(second)
        }

        XCTAssertEqual(first.audioURL.pathExtension.lowercased(), "m4a")
        XCTAssertNotEqual(first.audioURL, second.audioURL)
        XCTAssertEqual(first.cleanupURL, first.audioURL)
        XCTAssertEqual(second.cleanupURL, second.audioURL)
        let reopened = try AVAudioFile(forReading: first.audioURL)
        XCTAssertGreaterThan(reopened.length, 0)
        XCTAssertEqual(try directoryContents(of: session.folderURL), before)
    }

    func testCleanupIsIdempotentAndNeverDeletesOriginalSessionRecording() async throws {
        let mp4 = try makeMP4WithAudio(named: "recording.mp4")
        let session = try makeSession(recordingURL: mp4)
        let preparer = TranscriptionAudioPreparer()
        let prepared = try await preparer.prepare(for: session)

        preparer.cleanup(prepared)
        preparer.cleanup(prepared)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))
    }

    func testExportFailureCleansTemporaryOutput() async throws {
        let mp4 = try makeMP4WithAudio(named: "recording.mp4")
        let session = try makeSession(recordingURL: mp4)
        let factory = ControlledExporterFactory(mode: .failed(error: TestError.failed))
        let preparer = TranscriptionAudioPreparer(exporterFactory: factory.make)

        await XCTAssertThrowsErrorAsync(try await preparer.prepare(for: session))

        XCTAssertEqual(factory.createdURLs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(factory.createdURLs.first).path))
    }

    func testCancellationCleansTemporaryOutputAndResumesOnlyOnceWhenCompletionRaces() async throws {
        let mp4 = try makeMP4WithAudio(named: "recording.mp4")
        let session = try makeSession(recordingURL: mp4)
        let factory = ControlledExporterFactory(mode: .manual)
        let preparer = TranscriptionAudioPreparer(exporterFactory: factory.make)

        let task = Task.detached { try await preparer.prepare(for: session) }
        let exporter = await factory.waitForExporter()
        await exporter.waitForExportStart()
        task.cancel()
        await exporter.waitForCancellation()
        exporter.finish(status: .completed)

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(exporter.cancelCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exporter.outputURL.path))
    }

    func testCancellationAfterContinuationInstallationNeverStartsExporterOrLeavesTemporaryOutput() async throws {
        let mp4 = try makeMP4WithAudio(named: "recording.mp4")
        let session = try makeSession(recordingURL: mp4)
        let barrier = PreStartBarrier()
        let factory = ControlledExporterFactory(mode: .manual)
        let preparer = TranscriptionAudioPreparer(
            exporterFactory: factory.make,
            beforeExportStart: { barrier.waitForRelease() },
            cancellationRequested: { barrier.markCancellationRequested() }
        )

        let task = Task.detached { try await preparer.prepare(for: session) }
        let exporter = await factory.waitForExporter()
        await barrier.waitUntilEntered()
        task.cancel()
        await barrier.waitUntilCancellationRequested()
        barrier.release()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(exporter.exportStartCount, 0)
        XCTAssertEqual(exporter.cancelCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exporter.outputURL.path))
    }

    func testMissingOutputAfterCompletedExportIsRejectedAndCleaned() async throws {
        let mp4 = try makeMP4WithAudio(named: "recording.mp4")
        let session = try makeSession(recordingURL: mp4)
        let factory = ControlledExporterFactory(mode: .completedWithoutOutput)
        let preparer = TranscriptionAudioPreparer(exporterFactory: factory.make)

        await XCTAssertThrowsErrorAsync(try await preparer.prepare(for: session))

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(factory.createdURLs.first).path))
    }

    func testUnreadableOutputAfterCompletedExportIsRejectedAndCleaned() async throws {
        let mp4 = try makeMP4WithAudio(named: "recording.mp4")
        let session = try makeSession(recordingURL: mp4)
        let factory = ControlledExporterFactory(mode: .completedWithUnreadableOutput)
        let preparer = TranscriptionAudioPreparer(exporterFactory: factory.make)

        await XCTAssertThrowsErrorAsync(try await preparer.prepare(for: session))

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(factory.createdURLs.first).path))
    }

    private func makeSession(recordingURL: URL) throws -> RecordingSession {
        RecordingSessionStore.session(for: recordingURL.deletingLastPathComponent(), recordingURL: recordingURL)
    }

    private func makeAudioFile(named name: String) throws -> URL {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
        buffer.frameLength = 1_024
        try file.write(from: buffer)
        return url
    }

    private func makeMP4WithAudio(named name: String) throws -> URL {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        XCTAssertTrue(input.append(try makeAudioSample(frames: 4_800)))
        input.markAsFinished()
        let finished = expectation(description: "finish mp4")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func makeAudioSample(frames: Int) throws -> CMSampleBuffer {
        let samples = Array(repeating: Float(0.1), count: frames)
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            throw TestError.failed
        }
        let replaceStatus = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaceStatus == noErr else { throw TestError.failed }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            throw TestError.failed
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            throw TestError.failed
        }
        return sampleBuffer
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcription-preparer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func directoryContents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private enum TestError: Error {
    case failed
}

private final class ControlledExporterFactory: @unchecked Sendable {
    enum Mode {
        case failed(error: Error)
        case completedWithoutOutput
        case completedWithUnreadableOutput
        case manual
    }

    private let lock = NSLock()
    private let mode: Mode
    private var exporter: ControlledTranscriptionExporter?
    private var continuation: CheckedContinuation<ControlledTranscriptionExporter, Never>?
    private(set) var createdURLs: [URL] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func make(_ sourceURL: URL, _ outputURL: URL) throws -> any TranscriptionAudioExporting {
        let exporter = ControlledTranscriptionExporter(outputURL: outputURL, mode: mode)
        lock.lock()
        createdURLs.append(outputURL)
        self.exporter = exporter
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: exporter)
        return exporter
    }

    func waitForExporter() async -> ControlledTranscriptionExporter {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exporter {
                lock.unlock()
                continuation.resume(returning: exporter)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private final class ControlledTranscriptionExporter: TranscriptionAudioExporting, @unchecked Sendable {
    private let lock = NSLock()
    let outputURL: URL
    private let mode: ControlledExporterFactory.Mode
    private var completion: (() -> Void)?
    private var exportStartContinuation: CheckedContinuation<Void, Never>?
    private var didStartExport = false
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private(set) var status: AVAssetExportSession.Status = .unknown
    private(set) var error: Error?
    private(set) var cancelCount = 0
    private(set) var exportStartCount = 0

    init(outputURL: URL, mode: ControlledExporterFactory.Mode) {
        self.outputURL = outputURL
        self.mode = mode
    }

    func exportAsynchronously(_ completionHandler: @escaping () -> Void) {
        lock.lock()
        completion = completionHandler
        didStartExport = true
        exportStartCount += 1
        let exportStartContinuation = self.exportStartContinuation
        self.exportStartContinuation = nil
        let mode = self.mode
        lock.unlock()
        exportStartContinuation?.resume()
        switch mode {
        case let .failed(error):
            try? Data("not audio".utf8).write(to: outputURL)
            finish(status: .failed, error: error)
        case .completedWithoutOutput:
            finish(status: .completed)
        case .completedWithUnreadableOutput:
            try? Data("not audio".utf8).write(to: outputURL)
            finish(status: .completed)
        case .manual:
            break
        }
    }

    func cancelExport() {
        lock.lock()
        cancelCount += 1
        let cancellationContinuation = self.cancellationContinuation
        self.cancellationContinuation = nil
        lock.unlock()
        cancellationContinuation?.resume()
        finish(status: .cancelled)
    }

    func waitForCancellation() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancelCount > 0 {
                lock.unlock()
                continuation.resume()
                return
            }
            cancellationContinuation = continuation
            lock.unlock()
        }
    }

    func waitForExportStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didStartExport {
                lock.unlock()
                continuation.resume()
                return
            }
            exportStartContinuation = continuation
            lock.unlock()
        }
    }

    func finish(status: AVAssetExportSession.Status, error: Error? = nil) {
        lock.lock()
        self.status = status
        self.error = error
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
}

private final class PreStartBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var isReleased = false
    private var cancellationRequested = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() {
        condition.lock()
        didEnter = true
        let continuation = enteredContinuation
        enteredContinuation = nil
        condition.unlock()
        continuation?.resume()

        condition.lock()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func markCancellationRequested() {
        condition.lock()
        cancellationRequested = true
        let continuation = cancellationContinuation
        cancellationContinuation = nil
        condition.unlock()
        continuation?.resume()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if didEnter {
                condition.unlock()
                continuation.resume()
                return
            }
            enteredContinuation = continuation
            condition.unlock()
        }
    }

    func waitUntilCancellationRequested() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if cancellationRequested {
                condition.unlock()
                continuation.resume()
                return
            }
            cancellationContinuation = continuation
            condition.unlock()
        }
    }
}
