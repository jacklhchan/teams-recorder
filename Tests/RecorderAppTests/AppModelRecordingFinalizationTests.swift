import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class AppModelRecordingFinalizationTests: XCTestCase {
    func testFinishRecordingPublishesOneFinalizationOnlyAfterSourceMetadataAttempt() async throws {
        let ordering = FinalizationOrder()
        let fixture = try makeFixture { _, _, _ in
            ordering.append("metadata")
        }
        await primeLibrary(fixture)
        fixture.library.onSessionsLoaded = { _ in ordering.append("refresh") }

        try await start(fixture)
        await fixture.model.finishRecording(playAfterStop: false)
        await waitUntil { ordering.values.contains("refresh") }

        XCTAssertEqual(ordering.values, ["metadata", "refresh"])
    }

    func testFinishRecordingMetadataWarningStillPublishesOneFinalizationAndRefresh() async throws {
        let updates = FinalizationCounter()
        let refreshes = FinalizationCounter()
        let fixture = try makeFixture { _, _, _ in
            updates.increment()
            throw FinalizationTestError.metadataWriteFailed
        }
        await primeLibrary(fixture)
        fixture.library.onSessionsLoaded = { _ in refreshes.increment() }

        try await start(fixture)
        await fixture.model.finishRecording(playAfterStop: false)
        await waitUntil { refreshes.value == 1 }

        XCTAssertEqual(updates.value, 1)
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(
            fixture.model.statusMessage,
            "Recording saved, but source metadata could not be written: metadata write failed"
        )
    }

    func testFinishRecordingWithNoActiveResultPublishesNoFinalizationAndDoesNotRefreshLibrary() async throws {
        let updates = FinalizationCounter()
        let refreshes = FinalizationCounter()
        let fixture = try makeFixture { _, _, _ in updates.increment() }
        await primeLibrary(fixture)
        fixture.library.onSessionsLoaded = { _ in refreshes.increment() }

        await fixture.model.finishRecording(playAfterStop: false)

        XCTAssertEqual(updates.value, 0)
        XCTAssertEqual(refreshes.value, 0)
        XCTAssertEqual(fixture.model.statusMessage, "No active recording.")
    }

    func testFinishRecordingUsesFenceCapturedAtStopStartWhenWorkspaceChangesDuringStop() async throws {
        let fixture = try makeFixture()
        let replacement = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: replacement) }
        let refreshes = FinalizationRefreshRecorder()
        await primeLibrary(fixture)
        fixture.library.onSessionsLoaded = { snapshot in
            refreshes.append(snapshot.sessions.map(\.folderURL))
        }

        try await start(fixture)
        fixture.source.pauseStop = true
        let stop = Task { @MainActor in
            await fixture.model.finishRecording(playAfterStop: false)
        }
        await fixture.source.waitForPausedStop()
        fixture.model.setOutputFolder(replacement)
        await waitUntil { refreshes.count == 1 }
        fixture.source.resumeStop()
        await stop.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(refreshes.count, 1)
        XCTAssertFalse(
            refreshes.allFolders.contains { $0.deletingLastPathComponent() == fixture.workspace },
            "The old workspace finalization must be obsolete after its stop-start fence changes."
        )
    }

    func testFinalizationFromWorkspaceSymlinkPublishesOnePhysicalCanonicalSession() async throws {
        let fixture = try makeFixture(initialOutputFolder: { physicalWorkspace in
            let alias = physicalWorkspace.deletingLastPathComponent()
                .appendingPathComponent("workspace-alias-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: alias,
                withDestinationURL: physicalWorkspace
            )
            return alias
        })
        let refreshes = FinalizationRefreshRecorder()
        await primeLibrary(fixture)
        fixture.library.onSessionsLoaded = { snapshot in
            refreshes.append(snapshot.sessions.map(\.folderURL))
        }

        try await start(fixture)
        await fixture.model.finishRecording(playAfterStop: false)
        await waitUntil { refreshes.count == 1 }

        XCTAssertEqual(refreshes.count, 1)
        let session = try XCTUnwrap(fixture.library.sessions.first)
        let physicalFolder = RecordingLibraryURLIdentity.normalized(
            session.folderURL
        )
        let physicalRecording = RecordingLibraryURLIdentity.normalized(
            session.recordingURL
        )
        XCTAssertEqual(session.folderURL, physicalFolder)
        XCTAssertEqual(session.recordingURL, physicalRecording)
        XCTAssertEqual(physicalFolder.deletingLastPathComponent(), fixture.workspace)
        XCTAssertEqual(physicalRecording.deletingLastPathComponent(), physicalFolder)
        XCTAssertEqual(refreshes.allFolders, [physicalFolder])
    }

    private func makeFixture(
        updater: @escaping (RecordingSource, URL, RecordingSessionMutationGate) throws -> Void = {
            source, folder, gate in
            try gate.withMutation(for: folder) {
                var metadata = RecordingSessionMetadataStore.load(in: folder)
                metadata.source = source
                try RecordingSessionMetadataStore.save(metadata, in: folder)
            }
        },
        initialOutputFolder: (URL) throws -> URL = { $0 }
    ) throws -> FinalizationFixture {
        let workspace = try makeTemporaryFolder()
        let outputFolder = try initialOutputFolder(workspace)
        let source = FinalizationCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { FinalizationWriter(outputURL: $0) },
            mixerBlockFrames: 4
        )
        let library = LibraryFeatureModel(
            sessionLoader: { RecordingSessionStore.load(from: $0) },
            sessionReloader: { RecordingSessionStore.session(for: $0.folderURL, recordingURL: $0.recordingURL) },
            searchDocumentLoader: { session in
                RecordingLibrarySearchDocument.load(
                    folderURL: session.folderURL,
                    displayName: session.displayName,
                    createdAt: session.createdAt,
                    metadata: session.metadata
                )
            },
            recovery: { _ in },
            trashHandler: { _ in true }
        )
        let model = AppModel(
            recorder: engine,
            performStartupWork: false,
            initialOutputFolder: outputFolder,
            libraryFeature: library,
            recordingSourceMetadataUpdater: updater
        )
        addTeardownBlock {
            model.shutdown()
            if outputFolder != workspace {
                try? FileManager.default.removeItem(at: outputFolder)
            }
            try? FileManager.default.removeItem(at: workspace)
        }
        return .init(
            model: model,
            engine: engine,
            source: source,
            library: library,
            workspace: workspace,
            outputFolder: outputFolder
        )
    }

    private func start(_ fixture: FinalizationFixture) async throws {
        _ = try await fixture.engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: fixture.outputFolder
        )
    }

    private func primeLibrary(_ fixture: FinalizationFixture) async {
        let loaded = expectation(description: "initial library workspace load")
        fixture.library.onSessionsLoaded = { _ in loaded.fulfill() }
        fixture.model.refreshSessions()
        await fulfillment(of: [loaded], timeout: 1)
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        if !condition() { XCTFail("Condition was not reached", file: file, line: line) }
    }
}

@MainActor
private struct FinalizationFixture {
    let model: AppModel
    let engine: RecordingEngine
    let source: FinalizationCaptureSource
    let library: LibraryFeatureModel
    let workspace: URL
    let outputFolder: URL
}

private enum FinalizationTestError: LocalizedError {
    case metadataWriteFailed
    var errorDescription: String? { "metadata write failed" }
}

private final class FinalizationCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: 0)
    var pauseStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func refreshContent() async throws -> [CaptureApplication] { [] }
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}
    func updateVideoTarget(_: TeamsWindowIdentity?) async throws -> CaptureFilterRevision { .init(sessionGeneration: 0, revision: 0) }
    func start(selection _: ResolvedCaptureSelection, microphoneUID _: String?, onAudio _: @escaping (AudioFrameBlock) -> Void, onVideo _: @escaping (ScreenVideoFrame) -> Void, onEvent _: @escaping (CaptureEvent) -> Void) async throws {}
    func stop() async {
        guard pauseStop else { return }
        stopWaiters.forEach { $0.resume() }
        stopWaiters.removeAll()
        await withCheckedContinuation { stopContinuation = $0 }
    }
    func waitForPausedStop() async {
        if stopContinuation != nil { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
    func resumeStop() { stopContinuation?.resume(); stopContinuation = nil; pauseStop = false }
}

private final class FinalizationWriter: MixedAudioWriting {
    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func write(_: MixedAudioBlock) throws {}
    func close() throws { try Data().write(to: outputURL) }
}

private final class FinalizationOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class FinalizationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class FinalizationRefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[URL]] = []
    func append(_ folders: [URL]) { lock.lock(); storage.append(folders); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var allFolders: [URL] { lock.lock(); defer { lock.unlock() }; return storage.flatMap { $0 } }
}
