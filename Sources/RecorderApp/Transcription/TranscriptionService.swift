import Foundation

struct TranscriptionServiceRequest: Sendable {
    let audioURL: URL
    let sessionFolder: URL
    let snapshot: OpenAICompatibleProviderSnapshot
}

enum TranscriptionServiceProgress: Equatable, Sendable {
    case preparingChunks
    case uploading(chunk: Int, total: Int)
    case publishing
    case status(
        message: String,
        phase: TranscriptionState.Phase
    )

    var message: String {
        switch self {
        case .preparingChunks:
            "Preparing native audio chunks"
        case .uploading(let chunk, let total):
            "Uploading chunk \(chunk) of \(total)"
        case .publishing:
            "Publishing transcript"
        case .status(let message, _):
            message
        }
    }

    var phase: TranscriptionState.Phase {
        switch self {
        case .preparingChunks:
            .queued
        case .uploading:
            .uploading
        case .publishing:
            .transcribing
        case .status(_, let phase):
            phase
        }
    }
}

struct TranscriptionServiceResult: Equatable, Sendable {
    let transcriptURL: URL
    let rawTranscriptURL: URL?
    let manifestURL: URL?
    let logURL: URL?
    let committedTranscriptRevision: TranscriptDocumentRevision
}

protocol TranscriptionServicing: Sendable {
    func transcribe(
        _ request: TranscriptionServiceRequest,
        onProgress: @escaping @Sendable (
            TranscriptionServiceProgress
        ) -> Void
    ) async throws -> TranscriptionServiceResult
}

protocol ProviderTranscriptionRequesting: Sendable {
    func transcribe(
        audioData: Data,
        fileName: String,
        snapshot: OpenAICompatibleProviderSnapshot,
        prompt: String
    ) async throws -> ProviderTranscriptionResult
}

extension OpenAICompatibleTranscriptionClient:
    ProviderTranscriptionRequesting {}

struct FoundationTraditionalChineseConverter: Sendable {
    func convert(_ text: String) -> String {
        text.applyingTransform(
            StringTransform("Hans-Hant"),
            reverse: false
        ) ?? text
    }
}

enum TranscriptMerger {
    static func merge(
        _ transcripts: [String],
        minimumOverlap: Int = 4
    ) -> String {
        var merged = ""
        for raw in transcripts {
            let text = raw.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { continue }
            guard !merged.isEmpty else {
                merged = text
                continue
            }
            let maximum = min(merged.count, text.count)
            var overlap = 0
            if maximum >= minimumOverlap {
                for length in stride(
                    from: maximum,
                    through: minimumOverlap,
                    by: -1
                ) {
                    if merged.suffix(length) == text.prefix(length) {
                        overlap = length
                        break
                    }
                }
            }
            let remainder = text.dropFirst(overlap)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                merged += "\n" + remainder
            }
        }
        return merged
    }
}

struct NativeOpenAICompatibleTranscriptionService:
    TranscriptionServicing,
    @unchecked Sendable
{
    typealias WorkspaceURL = @Sendable () -> URL

    private let chunker: any TranscriptionChunking
    private let client: any ProviderTranscriptionRequesting
    private let publisher: TranscriptionArtifactPublisher
    private let converter: FoundationTraditionalChineseConverter
    private let fileManager: FileManager
    private let maximumChunkBytes: Int
    private let workspaceURL: WorkspaceURL

    init(
        chunker: any TranscriptionChunking =
            AVFoundationTranscriptionChunker(),
        client: any ProviderTranscriptionRequesting =
            OpenAICompatibleTranscriptionClient(),
        publisher: TranscriptionArtifactPublisher = .init(),
        converter: FoundationTraditionalChineseConverter = .init(),
        fileManager: FileManager = .default,
        maximumChunkBytes: Int =
            OpenAICompatibleTranscriptionClient.maximumAudioBytes,
        workspaceURL: @escaping WorkspaceURL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "local-meeting-recorder-transcription-"
                        + UUID().uuidString,
                    isDirectory: true
                )
        }
    ) {
        self.chunker = chunker
        self.client = client
        self.publisher = publisher
        self.converter = converter
        self.fileManager = fileManager
        self.maximumChunkBytes = max(0, maximumChunkBytes)
        self.workspaceURL = workspaceURL
    }

    func transcribe(
        _ request: TranscriptionServiceRequest,
        onProgress: @escaping @Sendable (
            TranscriptionServiceProgress
        ) -> Void
    ) async throws -> TranscriptionServiceResult {
        let workspace = workspaceURL()
        defer { try? fileManager.removeItem(at: workspace) }
        onProgress(.preparingChunks)
        let chunks = try await chunker.chunks(
            for: request.audioURL,
            workspaceURL: workspace
        )
        var texts: [String] = []
        var responseFormats: [String] = []
        var logLines = [
            "Native transcription started",
            "Prepared \(chunks.count) audio chunks"
        ]
        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onProgress(
                .uploading(
                    chunk: offset + 1,
                    total: chunks.count
                )
            )
            let chunkSize = try chunk.url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
            guard let chunkSize,
                  chunkSize <= maximumChunkBytes else {
                throw OpenAICompatibleTranscriptionError
                    .audioChunkTooLarge
            }
            let data = try Data(
                contentsOf: chunk.url,
                options: .mappedIfSafe
            )
            let result = try await client.transcribe(
                audioData: data,
                fileName: chunk.url.lastPathComponent,
                snapshot: request.snapshot,
                prompt: prompt(
                    global: request.snapshot.profile.prompt,
                    previousText: texts.last
                )
            )
            texts.append(result.text)
            responseFormats.append(result.responseFormat.rawValue)
            logLines.append(
                "Completed chunk \(offset + 1) of \(chunks.count)"
            )
        }
        try Task.checkCancellation()
        onProgress(.publishing)
        let raw = TranscriptMerger.merge(texts)
        let final = converter.convert(raw)
        logLines.append("Native transcription completed")
        let artifacts = try publisher.publish(
            rawText: raw,
            finalText: final,
            manifest: .init(
                model: request.snapshot.profile.asrModel,
                language: request.snapshot.profile.language,
                chunkCount: chunks.count,
                responseFormats: responseFormats
            ),
            logLines: logLines,
            sessionFolder: request.sessionFolder
        )
        return .init(
            transcriptURL: artifacts.transcriptURL,
            rawTranscriptURL: artifacts.rawTranscriptURL,
            manifestURL: artifacts.manifestURL,
            logURL: artifacts.logURL,
            committedTranscriptRevision: artifacts.committedTranscriptRevision
        )
    }

    private func prompt(
        global: String,
        previousText: String?
    ) -> String {
        guard let previous = previousText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !previous.isEmpty else {
            return global
        }
        let rolling = String(previous.suffix(240))
        let continuation =
            "上一段錄音的轉錄結尾，只用作延續語境及專有名詞參考，"
            + "不要在本段重複輸出：\n\(rolling)"
        return global.isEmpty
            ? continuation
            : global + "\n\n" + continuation
    }
}
