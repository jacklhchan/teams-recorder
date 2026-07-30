@preconcurrency import AVFoundation
import Foundation

struct TranscriptionChunkRange: Equatable, Sendable {
    let start: TimeInterval
    let duration: TimeInterval
}

enum TranscriptionChunkPlanner {
    static func plan(
        duration: TimeInterval,
        maximumDuration: TimeInterval
    ) -> [TranscriptionChunkRange] {
        guard duration > 0, maximumDuration > 0 else { return [] }
        var ranges: [TranscriptionChunkRange] = []
        var start: TimeInterval = 0
        while start < duration {
            let chunkDuration = min(maximumDuration, duration - start)
            ranges.append(
                .init(start: start, duration: chunkDuration)
            )
            start += chunkDuration
        }
        return ranges
    }
}

struct PreparedTranscriptionChunk: Equatable, Sendable {
    let index: Int
    let url: URL
    let start: TimeInterval
    let duration: TimeInterval
    let requiresCleanup: Bool
}

protocol TranscriptionChunking: Sendable {
    func chunks(
        for audioURL: URL,
        workspaceURL: URL
    ) async throws -> [PreparedTranscriptionChunk]
}

enum TranscriptionChunkingError: LocalizedError, Equatable {
    case missingAudioTrack
    case invalidDuration
    case cannotCreateExporter
    case exportedChunkUnreadable

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack:
            "The prepared recording has no audio track."
        case .invalidDuration:
            "The prepared recording has an invalid duration."
        case .cannotCreateExporter:
            "Unable to create a native audio chunk exporter."
        case .exportedChunkUnreadable:
            "A native audio chunk could not be reopened."
        }
    }
}

struct AVFoundationTranscriptionChunker:
    TranscriptionChunking,
    @unchecked Sendable
{
    typealias Export = @Sendable (
        URL,
        URL,
        CMTimeRange
    ) async throws -> Void

    let maximumDuration: TimeInterval
    let maximumPassthroughBytes: Int
    private let fileManager: FileManager
    private let export: Export

    init(
        maximumDuration: TimeInterval = 120,
        maximumPassthroughBytes: Int =
            OpenAICompatibleTranscriptionClient.maximumAudioBytes,
        fileManager: FileManager = .default,
        export: @escaping Export = { source, output, range in
            try await AVFoundationTranscriptionChunker.exportChunk(
                sourceURL: source,
                outputURL: output,
                timeRange: range
            )
        }
    ) {
        self.maximumDuration = maximumDuration
        self.maximumPassthroughBytes = max(
            0,
            maximumPassthroughBytes
        )
        self.fileManager = fileManager
        self.export = export
    }

    func chunks(
        for audioURL: URL,
        workspaceURL: URL
    ) async throws -> [PreparedTranscriptionChunk] {
        let asset = AVURLAsset(url: audioURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw TranscriptionChunkingError.missingAudioTrack
        }
        let loadedDuration = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(loadedDuration)
        guard duration.isFinite, duration > 0 else {
            throw TranscriptionChunkingError.invalidDuration
        }
        let ranges = TranscriptionChunkPlanner.plan(
            duration: duration,
            maximumDuration: maximumDuration
        )
        guard !ranges.isEmpty else {
            throw TranscriptionChunkingError.invalidDuration
        }
        let inputSize = try? audioURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize
        if ranges.count == 1,
           let inputSize,
           inputSize <= maximumPassthroughBytes {
            return [
                .init(
                    index: 0,
                    url: audioURL,
                    start: 0,
                    duration: duration,
                    requiresCleanup: false
                )
            ]
        }

        try fileManager.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        do {
            var chunks: [PreparedTranscriptionChunk] = []
            for (index, range) in ranges.enumerated() {
                try Task.checkCancellation()
                let outputURL = workspaceURL.appendingPathComponent(
                    String(format: "chunk-%04d.m4a", index + 1)
                )
                let timeRange = CMTimeRange(
                    start: CMTime(
                        seconds: range.start,
                        preferredTimescale: 48_000
                    ),
                    duration: CMTime(
                        seconds: range.duration,
                        preferredTimescale: 48_000
                    )
                )
                try await export(audioURL, outputURL, timeRange)
                try validateChunk(at: outputURL)
                chunks.append(
                    .init(
                        index: index,
                        url: outputURL,
                        start: range.start,
                        duration: range.duration,
                        requiresCleanup: true
                    )
                )
            }
            return chunks
        } catch {
            try? fileManager.removeItem(at: workspaceURL)
            throw error
        }
    }

    private func validateChunk(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0 else {
            throw TranscriptionChunkingError.exportedChunkUnreadable
        }
    }

    private static func exportChunk(
        sourceURL: URL,
        outputURL: URL,
        timeRange: CMTimeRange
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TranscriptionChunkingError.cannotCreateExporter
        }
        exporter.timeRange = timeRange
        try await exporter.export(to: outputURL, as: .m4a)
    }
}
