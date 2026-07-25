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
        XCTAssertEqual(writer.events, ["write", "close"])
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

    func testStopBoundsOneHourSparseSourceGap() async throws {
        let futureFrame: Int64 = 48_000 * 3_600
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
        source.emit(try block(
            .system,
            frame: futureFrame,
            samples: Array(repeating: 1, count: 8)
        ))

        let result = await engine.stop()

        XCTAssertEqual(writer.blocks.map(\.startFrame), [0, futureFrame, futureFrame + 4])
        XCTAssertEqual(writer.physicalFrameCount, 12)
        XCTAssertEqual(result?.health.timelineDiscontinuities, 1)
    }

    func testStopWritesExactPartialTail() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1]))

        _ = await engine.stop()

        XCTAssertEqual(writer.blocks.map(\.left.count), [3])
        XCTAssertEqual(writer.physicalFrameCount, 3)
    }

    func testWriterOpenFailureRollsBackSourceAndEmptyFolder() async throws {
        let source = FakeCaptureSource()
        let attemptedURL = URLBox()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { url in
                attemptedURL.value = url
                throw FakeFailure.writerOpen
            },
            mixerBlockFrames: 4
        )
        let baseFolder = temporaryFolder()
        try FileManager.default.createDirectory(
            at: baseFolder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: baseFolder) }

        do {
            _ = try await engine.start(
                selection: .allSystemAudio,
                microphoneUID: nil,
                baseFolder: baseFolder
            )
            XCTFail("Expected writer open failure")
        } catch {
            XCTAssertTrue(error is RecordingEngineError)
        }

        let attemptedFolder = try XCTUnwrap(attemptedURL.value?.deletingLastPathComponent())
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(engine.isMonitoring)
        XCTAssertFalse(engine.isRecording)
        let result = await engine.stop()
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attemptedFolder.path))
    }

    func testConcurrentSameMonitoringRequestCoalescesOneSourceStart() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        let engine = makeEngine(source: source, writer: FakeWriter())

        async let first: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await waitUntil { source.startCount == 1 }
        async let second: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await settle()
        source.resumeAllStarts()
        try await first
        try await second

        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.maximumConcurrentStarts, 1)
        XCTAssertTrue(engine.isMonitoring)
    }

    func testDifferentMonitoringRequestWaitsThenRestarts() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        let engine = makeEngine(source: source, writer: FakeWriter())
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )

        async let first: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await waitUntil { source.startCount == 1 }
        async let second: Void = engine.startMonitoring(
            selection: .application(teams),
            microphoneUID: "mic-b"
        )
        await settle()
        source.resumeNextStart()
        await waitUntil { source.startCount == 2 }
        source.resumeNextStart()
        try await first
        try await second

        XCTAssertEqual(source.startedSelections, [.allSystemAudio, .application(teams)])
        XCTAssertEqual(source.maximumConcurrentStarts, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertTrue(engine.isMonitoring)
    }

    func testFailedMonitoringRequestCannotPolluteNewSession() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        source.startErrors[1] = CaptureSourceError.streamFailure
        let engine = makeEngine(source: source, writer: FakeWriter())
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )

        async let first: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await waitUntil { source.startCount == 1 }
        async let second: Void = engine.startMonitoring(
            selection: .application(teams),
            microphoneUID: "mic-b"
        )
        source.resumeNextStart()
        await waitUntil { source.startCount == 2 }
        source.resumeNextStart()

        do {
            try await first
            XCTFail("Expected first monitoring request to fail")
        } catch {}
        try await second

        XCTAssertTrue(engine.isMonitoring)
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        XCTAssertNil(engine.captureStatus)
    }

    func testConcurrentRecordingStartsCreateOneWriter() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        let factory = FakeWriterFactory()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: factory.makeWriter,
            mixerBlockFrames: 4
        )
        let baseFolder = temporaryFolder()

        async let first = engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: baseFolder
        )
        await waitUntil { source.startCount == 1 }
        async let second = engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: baseFolder
        )
        await settle()
        source.resumeAllStarts()
        let folders = try await [first, second]

        XCTAssertEqual(factory.createCount, 1)
        XCTAssertEqual(Set(folders).count, 1)
        _ = await engine.stop()
    }

    func testTerminalEventDuringRecordingKeepsResultAvailableUntilStop() async throws {
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
        source.emit(event: .streamStoppedBySystem)
        await settle()

        XCTAssertFalse(engine.isMonitoring)
        XCTAssertFalse(engine.isSystemCaptureConnected)
        XCTAssertFalse(engine.isMicrophoneCaptureConnected)
        XCTAssertTrue(engine.isRecording)

        let result = await engine.stop()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.health.streamFailures, 1)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testMonitorOnlyTerminalEventAllowsSameSelectionRestart() async throws {
        let source = FakeCaptureSource()
        let engine = makeEngine(source: source, writer: FakeWriter())
        try await engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: nil
        )

        source.emit(event: .streamFailed)
        await settle()
        XCTAssertFalse(engine.isMonitoring)

        try await engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: nil
        )

        XCTAssertEqual(source.startCount, 2)
        XCTAssertTrue(engine.isMonitoring)
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

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}

private final class FakeCaptureSource: CaptureSourceProtocol {
    private var onAudio: ((AudioFrameBlock) -> Void)?
    private var onEvent: ((CaptureEvent) -> Void)?
    private var audioHandlers: [(AudioFrameBlock) -> Void] = []
    private(set) var startedSelection: ResolvedCaptureSelection?
    private(set) var startedMicrophoneUID: String?
    private(set) var stopCount = 0
    private(set) var startCount = 0
    private(set) var activeStarts = 0
    private(set) var maximumConcurrentStarts = 0
    private(set) var startedSelections: [ResolvedCaptureSelection] = []
    var pauseStarts = false
    var startErrors: [Int: Error] = [:]
    var pauseStop = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func refreshContent() async throws -> [CaptureApplication] { [] }

    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws {
        startCount += 1
        let thisStart = startCount
        activeStarts += 1
        maximumConcurrentStarts = max(maximumConcurrentStarts, activeStarts)
        startedSelections.append(selection)
        defer { activeStarts -= 1 }
        if pauseStarts {
            await withCheckedContinuation { continuation in
                startContinuations.append(continuation)
            }
        }
        if let error = startErrors[thisStart] {
            throw error
        }
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

    func resumeNextStart() {
        guard !startContinuations.isEmpty else { return }
        startContinuations.removeFirst().resume()
    }

    func resumeAllStarts() {
        pauseStarts = false
        let continuations = startContinuations
        startContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class FakeWriter: MixedAudioWriting {
    private(set) var blocks: [MixedAudioBlock] = []
    private(set) var closeCount = 0
    private(set) var events: [String] = []

    var physicalFrameCount: Int {
        blocks.reduce(0) { $0 + $1.left.count }
    }

    func write(_ block: MixedAudioBlock) throws {
        blocks.append(block)
        events.append("write")
    }

    func close() throws {
        closeCount += 1
        events.append("close")
    }

    func resetBlocks() {
        blocks.removeAll()
    }
}

private final class FakeWriterFactory {
    private(set) var createCount = 0
    private(set) var writers: [FakeWriter] = []

    func makeWriter(url: URL) throws -> MixedAudioWriting {
        createCount += 1
        let writer = FakeWriter()
        writers.append(writer)
        return writer
    }
}

private final class URLBox {
    var value: URL?
}

private enum FakeFailure: Error {
    case writerOpen
}
