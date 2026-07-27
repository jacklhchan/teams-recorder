import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelScreenCaptureTests: XCTestCase {
    func testPreflightQueriesSelectedOutputFolderBeforeStarting() async throws {
        let provider = StorageCapacityTestProvider(results: [.success(6 * gibibyte)])
        let fixture = makeFixture(provider: provider)
        let selectedFolder = temporaryFolder().appendingPathComponent("External", isDirectory: true)
        fixture.model.setOutputFolder(selectedFolder)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertEqual(provider.queriedURLs, [selectedFolder])
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testPreflightBelowOneGiBStartsAudioButDisablesScreenCapture() async throws {
        let provider = StorageCapacityTestProvider(results: [.success(512 * mebibyte)])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertFalse(fixture.model.isScreenCaptureAllowedByStorage)
        XCTAssertEqual(
            fixture.model.screenCaptureStorageRestrictionReason,
            "Screen capture disabled: less than 1 GB available. Audio recording can continue."
        )
        XCTAssertEqual(fixture.engine.meetingScreenCaptureState, .off)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testPreflightBelowAudioSafetyThresholdRefusesNewRecording() async throws {
        let provider = StorageCapacityTestProvider(results: [.success((256 * mebibyte) - 1)])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil {
            fixture.model.statusMessage == "Recording cannot start: less than 256 MB available."
        }

        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.startCount, 0)
        XCTAssertEqual(
            fixture.model.statusMessage,
            "Recording cannot start: less than 256 MB available."
        )
    }

    func testTestRecordingAlsoPreflightsAndRefusesBelowAudioSafetyThreshold() async throws {
        let provider = StorageCapacityTestProvider(results: [.success((256 * mebibyte) - 1)])
        let fixture = makeFixture(provider: provider)

        fixture.model.runTestRecording()
        await waitUntil {
            fixture.model.statusMessage == "Recording cannot start: less than 256 MB available."
        }

        XCTAssertFalse(fixture.model.isRunningTestRecording)
        XCTAssertEqual(fixture.source.startCount, 0)
    }

    func testProviderErrorWarnsButAllowsRecording() async throws {
        let provider = StorageCapacityTestProvider(results: [.failure(StorageTestError.unavailable)])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertTrue(fixture.model.isScreenCaptureAllowedByStorage)
        XCTAssertEqual(
            fixture.model.storageWarningMessage,
            "Storage check unavailable: unavailable. Recording can continue."
        )

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testRuntimeAudioOnlyDisablesScreenButKeepsAudioRecording() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .success(512 * mebibyte)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await waitUntil { !fixture.model.isScreenCaptureAllowedByStorage }

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.engine.meetingScreenCaptureState, .off)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testRuntimeBelowAudioSafetyThresholdUsesNormalStopLifecycle() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .success((256 * mebibyte) - 1)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await waitUntil { !fixture.engine.isRecording }

        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertTrue(fixture.model.statusMessage.hasPrefix("Recording saved:"))
    }

    func testRuntimeProviderErrorWarnsAndKeepsRecording() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .failure(StorageTestError.unavailable)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await waitUntil {
            fixture.model.storageWarningMessage == "Storage check unavailable: unavailable. Recording can continue."
        }

        XCTAssertTrue(fixture.engine.isRecording)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testChangingOutputFolderDuringPreflightCannotStartOnUncheckedVolume() async throws {
        let provider = StorageCapacityTestProvider(results: [
            .blocked(.success(6 * gibibyte))
        ])
        let fixture = makeFixture(provider: provider)
        let originalFolder = temporaryFolder().appendingPathComponent("Original", isDirectory: true)
        let replacementFolder = temporaryFolder().appendingPathComponent("Replacement", isDirectory: true)
        fixture.model.setOutputFolder(originalFolder)

        fixture.model.startOrStop()
        await provider.waitForBlockedRequest()
        fixture.model.setOutputFolder(replacementFolder)
        provider.resumeBlockedRequest()
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }

        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertEqual(fixture.source.startCount, 0)
        XCTAssertEqual(provider.queriedURLs, [originalFolder])
        XCTAssertEqual(
            fixture.model.statusMessage,
            "Output folder changed. Start recording again."
        )
    }

    func testLateOldStorageResultCannotStopNewRecordingOrReplaceItsStatus() async throws {
        let ticker = StorageTestTicker()
        let provider = StorageCapacityTestProvider(results: [
            .success(6 * gibibyte),
            .blocked(.success((256 * mebibyte) - 1)),
            .success(6 * gibibyte)
        ])
        let fixture = makeFixture(provider: provider, ticker: ticker)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await ticker.fire()
        await provider.waitForBlockedRequest()

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
        await waitUntil { !fixture.model.isCaptureLifecycleWorking }
        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        await waitUntil { fixture.model.statusMessage == "Recording" }
        XCTAssertEqual(fixture.model.statusMessage, "Recording")

        provider.resumeBlockedRequest()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(fixture.engine.isRecording)
        XCTAssertEqual(fixture.model.statusMessage, "Recording")

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    func testNewRecordingResetsStorageScreenAllowanceAfterPriorAudioOnlyRecording() async throws {
        let provider = StorageCapacityTestProvider(results: [
            .success(512 * mebibyte),
            .success(6 * gibibyte)
        ])
        let fixture = makeFixture(provider: provider)

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }
        XCTAssertFalse(fixture.model.isScreenCaptureAllowedByStorage)
        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }

        fixture.model.startOrStop()
        await waitUntil { fixture.engine.isRecording }

        XCTAssertTrue(fixture.model.isScreenCaptureAllowedByStorage)
        XCTAssertNil(fixture.model.screenCaptureStorageRestrictionReason)

        fixture.model.startOrStop()
        await waitUntil { !fixture.engine.isRecording }
    }

    private func makeFixture(
        provider: StorageCapacityTestProvider,
        ticker: StorageTestTicker = StorageTestTicker()
    ) -> StorageFixture {
        let source = StorageTestCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in StorageTestWriter() },
            mixerBlockFrames: 4
        )
        let defaults = UserDefaults(suiteName: "AppModelScreenCaptureTests.\(UUID().uuidString)")!
        let microphone = AudioDevice(
            id: 1,
            uid: "test-microphone",
            name: "Test Microphone",
            manufacturer: "Tests",
            channelCount: 1
        )
        let model = AppModel(
            defaults: defaults,
            recorder: engine,
            inputDevices: { [microphone] },
            defaultInputDeviceID: { microphone.id },
            performStartupWork: false,
            permissionRequestHandler: { _, _ in },
            volumeCapacityProvider: provider,
            storagePolicy: RecordingStoragePolicy(),
            storageMonitorTick: { await ticker.waitForTick() }
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        return StorageFixture(model: model, engine: engine, source: source, defaults: defaults)
    }

    private func temporaryFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    private let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    private let mebibyte: Int64 = 1_024 * 1_024
}

private struct StorageFixture {
    let model: AppModel
    let engine: RecordingEngine
    let source: StorageTestCaptureSource
    let defaults: UserDefaults
}

private enum StorageTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "unavailable" }
}

private final class StorageCapacityTestProvider: VolumeCapacityProviding, @unchecked Sendable {
    enum Result {
        case success(Int64)
        case failure(Error)
        case blocked(Swift.Result<Int64, Error>)
    }

    private let lock = NSLock()
    private var results: [Result]
    private var blockedSemaphore: DispatchSemaphore?
    private let blockedRequestSemaphore = DispatchSemaphore(value: 0)
    private(set) var queriedURLs: [URL] = []

    init(results: [Result]) {
        self.results = results
    }

    func availableBytes(onVolumeContaining url: URL) throws -> Int64 {
        lock.lock()
        queriedURLs.append(url)
        let result = results.removeFirst()
        if case .blocked = result {
            let semaphore = DispatchSemaphore(value: 0)
            blockedSemaphore = semaphore
            lock.unlock()
            blockedRequestSemaphore.signal()
            semaphore.wait()
        } else {
            lock.unlock()
        }

        switch result {
        case .success(let bytes): return bytes
        case .failure(let error): throw error
        case .blocked(let result): return try result.get()
        }
    }

    func waitForBlockedRequest() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.blockedRequestSemaphore.wait()
                continuation.resume()
            }
        }
    }

    func resumeBlockedRequest() {
        lock.lock()
        let semaphore = blockedSemaphore
        blockedSemaphore = nil
        lock.unlock()
        semaphore?.signal()
    }
}

private actor StorageTestTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
            return
        }
        await withCheckedContinuation { continuations.append($0) }
    }

    func fire() {
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }
    }
}

private final class StorageTestCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: 0)
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func refreshContent() async throws -> [CaptureApplication] { [] }
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}
    func updateVideoTarget(_: TeamsWindowIdentity?) async throws -> CaptureFilterRevision {
        .init(sessionGeneration: 0, revision: 0)
    }
    func start(
        selection _: ResolvedCaptureSelection,
        microphoneUID _: String?,
        onAudio _: @escaping (AudioFrameBlock) -> Void,
        onVideo _: @escaping (ScreenVideoFrame) -> Void,
        onEvent _: @escaping (CaptureEvent) -> Void
    ) async throws {
        startCount += 1
    }
    func stop() async { stopCount += 1 }
}

private final class StorageTestWriter: MixedAudioWriting {
    func write(_: MixedAudioBlock) throws {}
    func close() throws {}
}
