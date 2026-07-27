@preconcurrency import AVFoundation
import Foundation

struct PreparedTranscriptionAudio: Equatable {
    let audioURL: URL
    let cleanupURL: URL?
}

protocol TranscriptionAudioPreparing {
    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio
    func cleanup(_ prepared: PreparedTranscriptionAudio)
}

protocol TranscriptionAudioExporting: AnyObject {
    var status: AVAssetExportSession.Status { get }
    var error: Error? { get }

    func exportAsynchronously(_ completionHandler: @escaping () -> Void)
    func cancelExport()
}

enum TranscriptionAudioPreparationError: LocalizedError {
    case unsupportedInput
    case missingAudioTrack
    case cannotCreateExporter
    case exportFailed(Error?)
    case outputUnreadable

    var errorDescription: String? {
        switch self {
        case .unsupportedInput:
            return "The recording is not a supported audio file."
        case .missingAudioTrack:
            return "The MP4 recording has no audio track."
        case .cannotCreateExporter:
            return "Unable to create an audio exporter for this recording."
        case .exportFailed(let error):
            return error?.localizedDescription ?? "Audio extraction failed."
        case .outputUnreadable:
            return "The extracted audio file could not be read."
        }
    }
}

struct TranscriptionAudioPreparer: TranscriptionAudioPreparing {
    typealias ExporterFactory = (URL, URL) throws -> any TranscriptionAudioExporting

    private let fileManager: FileManager
    private let exporterFactory: ExporterFactory
    private let beforeExportStart: @Sendable () -> Void
    private let cancellationRequested: @Sendable () -> Void

    init(
        fileManager: FileManager = .default,
        exporterFactory: @escaping ExporterFactory = TranscriptionAudioPreparer.makeExporter,
        beforeExportStart: @escaping @Sendable () -> Void = {},
        cancellationRequested: @escaping @Sendable () -> Void = {}
    ) {
        self.fileManager = fileManager
        self.exporterFactory = exporterFactory
        self.beforeExportStart = beforeExportStart
        self.cancellationRequested = cancellationRequested
    }

    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        let sourceURL = session.recordingURL
        let fileExtension = sourceURL.pathExtension.lowercased()
        if fileExtension == "m4a" || ManualTranscriptionImporter.supportedExtensions.contains(fileExtension) {
            return .init(audioURL: sourceURL, cleanupURL: nil)
        }
        guard fileExtension == "mp4" else {
            throw TranscriptionAudioPreparationError.unsupportedInput
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw TranscriptionAudioPreparationError.missingAudioTrack
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("local-meeting-recorder-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        do {
            let exporter = try exporterFactory(sourceURL, outputURL)
            try await export(exporter, outputURL: outputURL)
            try validateOutput(at: outputURL)
            return .init(audioURL: outputURL, cleanupURL: outputURL)
        } catch {
            removeIfPresent(outputURL)
            throw error
        }
    }

    func cleanup(_ prepared: PreparedTranscriptionAudio) {
        guard let cleanupURL = prepared.cleanupURL else { return }
        removeIfPresent(cleanupURL)
    }

    private func export(_ exporter: any TranscriptionAudioExporting, outputURL: URL) async throws {
        let owner = ExportOperationOwner(exporter: exporter, outputURL: outputURL)
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                owner.install(continuation)
                beforeExportStart()
                owner.start()
            }
        }, onCancel: {
            cancellationRequested()
            owner.cancel()
        })
    }

    private func validateOutput(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw TranscriptionAudioPreparationError.outputUnreadable
        }
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0, audioFile.processingFormat.sampleRate > 0 else {
            throw TranscriptionAudioPreparationError.outputUnreadable
        }
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func makeExporter(
        sourceURL: URL,
        outputURL: URL
    ) throws -> any TranscriptionAudioExporting {
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionAudioPreparationError.cannotCreateExporter
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        return AVFoundationTranscriptionExporter(exporter)
    }
}

private final class AVFoundationTranscriptionExporter: TranscriptionAudioExporting {
    private let exporter: AVAssetExportSession

    init(_ exporter: AVAssetExportSession) {
        self.exporter = exporter
    }

    var status: AVAssetExportSession.Status { exporter.status }
    var error: Error? { exporter.error }

    func exportAsynchronously(_ completionHandler: @escaping () -> Void) {
        exporter.exportAsynchronously(completionHandler: completionHandler)
    }

    func cancelExport() {
        exporter.cancelExport()
    }
}

/// AVAssetExportSession itself is only touched while `lock` is held.
private final class ExportOperationOwner: @unchecked Sendable {
    private enum Lifecycle: Equatable {
        case waitingToStart
        case running
        case finished
    }

    private let lock = NSLock()
    private let exporter: any TranscriptionAudioExporting
    private let outputURL: URL
    private var lifecycle: Lifecycle = .waitingToStart
    private var cancellationRequested = false
    private var cancellationIssued = false
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(exporter: any TranscriptionAudioExporting, outputURL: URL) {
        self.exporter = exporter
        self.outputURL = outputURL
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        guard !cancellationRequested else {
            completeLocked(.failure(CancellationError()))
            lock.unlock()
            return
        }

        // Keep the lock through the start call: a concurrent cancellation can
        // only observe this operation after AVFoundation has actually started.
        lifecycle = .running
        exporter.exportAsynchronously { [weak self] in
            DispatchQueue.global().async {
                self?.finishFromExporter()
            }
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        guard result == nil else {
            lock.unlock()
            return
        }

        guard lifecycle == .running else {
            completeLocked(.failure(CancellationError()))
            lock.unlock()
            return
        }

        guard !cancellationIssued else {
            lock.unlock()
            return
        }
        cancellationIssued = true
        exporter.cancelExport()
        lock.unlock()
    }

    private func finishFromExporter() {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        let result: Result<Void, Error>
        if cancellationRequested || exporter.status == .cancelled {
            result = .failure(CancellationError())
        } else if exporter.status == .completed {
            result = .success(())
        } else {
            result = .failure(TranscriptionAudioPreparationError.exportFailed(exporter.error))
        }
        completeLocked(result)
        lock.unlock()
    }

    private func completeLocked(_ result: Result<Void, Error>) {
        self.result = result
        lifecycle = .finished
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
