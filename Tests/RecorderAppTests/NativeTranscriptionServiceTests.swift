import Foundation
import XCTest
@testable import RecorderApp

final class NativeTranscriptionServiceTests: XCTestCase {
    func testNativeServiceChunksUploadsMergesConvertsAndPublishes() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = folder.appendingPathComponent(
            "native-workspace",
            isDirectory: true
        )
        let chunker = StubTranscriptionChunker(texts: ["one", "two"])
        let client = StubProviderTranscriptionClient(
            results: [
                .success(
                    .init(
                        text: "客户讨论共同內容",
                        responseFormat: .verboseJSON
                    )
                ),
                .success(
                    .init(
                        text: "共同內容第二段",
                        responseFormat: .json
                    )
                )
            ]
        )
        let progress = NativeLockedValues<TranscriptionServiceProgress>()
        let service = NativeOpenAICompatibleTranscriptionService(
            chunker: chunker,
            client: client,
            workspaceURL: { workspace }
        )

        let result = try await service.transcribe(
            .init(
                audioURL: folder.appendingPathComponent("recording.m4a"),
                sessionFolder: folder,
                snapshot: try makeSnapshot()
            ),
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(
            try String(
                contentsOf: XCTUnwrap(result.rawTranscriptURL),
                encoding: .utf8
            ),
            "客户讨论共同內容\n第二段"
        )
        XCTAssertEqual(
            try String(
                contentsOf: result.transcriptURL,
                encoding: .utf8
            ),
            "客戶討論共同內容\n第二段"
        )
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(
            client.requests[1].prompt.contains("客户讨论共同內容")
        )
        XCTAssertEqual(
            progress.values,
            [
                .preparingChunks,
                .uploading(chunk: 1, total: 2),
                .uploading(chunk: 2, total: 2),
                .publishing
            ]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.path)
        )
    }

    func testFailureRemovesWorkspaceAndDoesNotPublishCandidate() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = folder.appendingPathComponent(
            "failed-workspace",
            isDirectory: true
        )
        let service = NativeOpenAICompatibleTranscriptionService(
            chunker: StubTranscriptionChunker(texts: ["one"]),
            client: StubProviderTranscriptionClient(
                results: [
                    .failure(
                        OpenAICompatibleTranscriptionError.httpStatus(500)
                    )
                ]
            ),
            workspaceURL: { workspace }
        )

        do {
            _ = try await service.transcribe(
                .init(
                    audioURL: folder.appendingPathComponent(
                        "recording.m4a"
                    ),
                    sessionFolder: folder,
                    snapshot: try makeSnapshot()
                ),
                onProgress: { _ in }
            )
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleTranscriptionError,
                .httpStatus(500)
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(
                    "transcript.txt"
                ).path
            )
        )
    }

    func testOversizedChunkIsRejectedBeforeProviderRequest() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = StubProviderTranscriptionClient(
            results: [
                .success(
                    .init(text: "unused", responseFormat: .json)
                )
            ]
        )
        let service = NativeOpenAICompatibleTranscriptionService(
            chunker: StubTranscriptionChunker(texts: ["too large"]),
            client: client,
            maximumChunkBytes: 1,
            workspaceURL: {
                folder.appendingPathComponent(
                    "bounded-workspace",
                    isDirectory: true
                )
            }
        )

        do {
            _ = try await service.transcribe(
                .init(
                    audioURL: folder.appendingPathComponent(
                        "recording.m4a"
                    ),
                    sessionFolder: folder,
                    snapshot: try makeSnapshot()
                ),
                onProgress: { _ in }
            )
            XCTFail("Expected byte cap failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleTranscriptionError,
                .audioChunkTooLarge
            )
        }

        XCTAssertTrue(client.requests.isEmpty)
    }

    func testTranscriptMergerRemovesNormalizedOverlap() {
        XCTAssertEqual(
            TranscriptMerger.merge(
                [
                    "第一段共同重複內容文字。",
                    "共同重複內容文字。第二段。"
                ]
            ),
            "第一段共同重複內容文字。\n第二段。"
        )
    }

    func testFoundationChineseConverterUsesTraditionalCharacters() {
        XCTAssertEqual(
            FoundationTraditionalChineseConverter().convert("客户软件"),
            "客戶軟件"
        )
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "native-transcription-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder
    }

    private func makeSnapshot() throws
        -> OpenAICompatibleProviderSnapshot
    {
        .init(
            profile: try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example/v1",
                asrModel: "asr-model",
                llmModel: "llm-model",
                language: "yue",
                prompt: "global context"
            ),
            apiKey: nil
        )
    }
}

private final class StubTranscriptionChunker:
    TranscriptionChunking,
    @unchecked Sendable
{
    private let texts: [String]

    init(texts: [String]) {
        self.texts = texts
    }

    func chunks(
        for _: URL,
        workspaceURL: URL
    ) async throws -> [PreparedTranscriptionChunk] {
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        return try texts.enumerated().map { index, text in
            let url = workspaceURL.appendingPathComponent(
                "chunk-\(index).m4a"
            )
            try Data(text.utf8).write(to: url)
            return .init(
                index: index,
                url: url,
                start: Double(index),
                duration: 1,
                requiresCleanup: true
            )
        }
    }
}

private final class StubProviderTranscriptionClient:
    ProviderTranscriptionRequesting,
    @unchecked Sendable
{
    struct Request {
        let prompt: String
        let data: Data
    }

    private let lock = NSLock()
    private var results: [
        Result<ProviderTranscriptionResult, Error>
    ]
    private(set) var requests: [Request] = []

    init(results: [Result<ProviderTranscriptionResult, Error>]) {
        self.results = results
    }

    func transcribe(
        audioData: Data,
        fileName _: String,
        snapshot _: OpenAICompatibleProviderSnapshot,
        prompt: String
    ) async throws -> ProviderTranscriptionResult {
        try lock.withLock {
            requests.append(.init(prompt: prompt, data: audioData))
            return try results.removeFirst().get()
        }
    }
}

private final class NativeLockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}
