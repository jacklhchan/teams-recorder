import XCTest
@testable import RecorderApp

@MainActor
final class RecordingEngineStateTests: XCTestCase {
    func testStartDoesNotRequireBlackHoleDevice() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)

        let folder = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: "BuiltInMicrophone",
            baseFolder: temporaryFolder()
        )

        XCTAssertEqual(source.startedSelection, .allSystemAudio)
        XCTAssertEqual(source.startedMicrophoneUID, "BuiltInMicrophone")
        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testSelectedAppDisconnectKeepsRecordingActive() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(event: .applicationDisconnected("Teams"))
        await settle()
        source.emit(try block(.microphone, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertTrue(engine.isRecording)
        XCTAssertFalse(engine.isSystemCaptureConnected)
        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertEqual(try XCTUnwrap(writer.blocks.first?.left.first), 0.48, accuracy: 0.001)
    }

    func testMicrophoneDisconnectKeepsSystemRecordingActive() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(event: .microphoneDisconnected)
        await settle()
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertTrue(engine.isRecording)
        XCTAssertFalse(engine.isMicrophoneCaptureConnected)
        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertEqual(try XCTUnwrap(writer.blocks.first?.left.first), 0.48, accuracy: 0.001)
    }

    func testStopFlushesMixerAndClosesWriterOnce() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [0.5, 0.5, 0.5, 0.5]))
        source.emit(try block(.microphone, frame: 0, samples: [0.5, 0.5, 0.5, 0.5]))

        let result = await engine.stop()
        let second = await engine.stop()

        XCTAssertNotNil(result)
        XCTAssertNil(second)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(writer.closeCount, 1)
        XCTAssertEqual(writer.blocks.count, 1)
    }

    func testCaptureFailureAppearsInHealthReport() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(event: .conversionFailed(.system))
        source.emit(event: .streamFailed)
        await settle()
        let result = await engine.stop()

        XCTAssertEqual(result?.health.conversionFailures, 1)
        XCTAssertEqual(result?.health.streamFailures, 1)
        XCTAssertTrue(result?.health.summary.contains("conversion failures") == true)
    }

    func testTimelineDiscontinuityIsReportedWithoutPaddingElapsedDuration() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        source.emit(try block(.system, frame: 48_000 * 3_600, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 48_000 * 3_600, samples: [0, 0, 0, 0]))
        await settle()
        let result = await engine.stop()

        XCTAssertEqual(writer.blocks.count, 2)
        XCTAssertEqual(writer.physicalFrameCount, 8)
        XCTAssertEqual(result?.health.timelineDiscontinuities, 1)
    }

    func testNoAudioStopDoesNotWritePhantomBlock() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        _ = await engine.stop()

        XCTAssertTrue(writer.blocks.isEmpty)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testConcurrentStopsCloseWriterOnlyOnce() async throws {
        let source = FakeCaptureSource()
        source.pauseStop = true
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        async let first = engine.stop()
        await Task.yield()
        async let second = engine.stop()
        await Task.yield()
        source.resumeStop()
        let results = await [first, second]

        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testCallbackBarrierFlushesAcceptedFrameAndDropsOldSession() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        let result = await engine.stop()
        source.emit(try block(.system, frame: 4, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertNotNil(result)
        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testOldSessionCallbackCannotWriteToNewSessionWriter() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        _ = await engine.stop()
        writer.resetBlocks()

        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emitFromSession(0, try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertTrue(writer.blocks.isEmpty)
        _ = await engine.stop()
    }

    private func temporaryFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeEngine(source: FakeCaptureSource, writer: FakeWriter) -> RecordingEngine {
        RecordingEngine(
            captureSource: source,
            writerFactory: { _ in writer },
            mixerBlockFrames: 4
        )
    }

    private func block(_ source: AudioSourceKind, frame: Int64, samples: [Float]) throws -> AudioFrameBlock {
        try AudioFrameBlock.stereo(source: source, startFrame: frame, left: samples, right: samples)
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }
}

private final class FakeCaptureSource: CaptureSourceProtocol {
    private var onAudio: ((AudioFrameBlock) -> Void)?
    private var onEvent: ((CaptureEvent) -> Void)?
    private var audioHandlers: [(AudioFrameBlock) -> Void] = []
    private(set) var startedSelection: ResolvedCaptureSelection?
    private(set) var startedMicrophoneUID: String?
    private(set) var stopCount = 0
    var pauseStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func refreshContent() async throws -> [CaptureApplication] { [] }

    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws {
        startedSelection = selection
        startedMicrophoneUID = microphoneUID
        self.onAudio = onAudio
        self.onEvent = onEvent
        audioHandlers.append(onAudio)
    }

    func stop() async {
        stopCount += 1
        guard pauseStop else { return }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func emit(_ block: AudioFrameBlock) {
        onAudio?(block)
    }

    func emit(event: CaptureEvent) {
        onEvent?(event)
    }

    func emitFromSession(_ index: Int, _ block: AudioFrameBlock) {
        audioHandlers[index](block)
    }

    func resumeStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
}

private final class FakeWriter: MixedAudioWriting {
    private(set) var blocks: [MixedAudioBlock] = []
    private(set) var closeCount = 0

    var physicalFrameCount: Int {
        blocks.reduce(0) { $0 + $1.left.count }
    }

    func write(_ block: MixedAudioBlock) throws {
        blocks.append(block)
    }

    func close() throws {
        closeCount += 1
    }

    func resetBlocks() {
        blocks.removeAll()
    }
}
