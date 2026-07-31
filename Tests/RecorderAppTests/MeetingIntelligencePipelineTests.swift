import Foundation
import XCTest
@testable import RecorderApp

final class MeetingIntelligencePipelineTests: XCTestCase {
    func testOneChunkSendsOneFinalRequestWithoutPartialRequests() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        let expected = MeetingIntelligenceGeneratedContent(
            title: "One chunk",
            summary: "The transcript fits in a single bounded request."
        )
        await client.setFinal(expected)

        let result = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: Data(repeating: 0x61, count: 64 * 1_024)),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        XCTAssertEqual(result, expected)
        let partialInputs = await client.partialInputs
        let finalInputs = await client.finalInputs
        XCTAssertEqual(partialInputs, [])
        XCTAssertEqual(finalInputs.count, 1)
    }

    func testMultiChunkPreservesEverySourceByteAndUsesOneFinalRequest() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { "partial:\($0.utf8.count)" }
        let expected = MeetingIntelligenceGeneratedContent(
            title: "Network migration review",
            summary: "All bounded partial summaries were combined."
        )
        await client.setFinal(expected)
        let source = Data(repeating: 0x61, count: 130 * 1_024)

        let result = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: source),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        XCTAssertEqual(result, expected)
        let partialInputs = await client.partialInputs
        let finalInputs = await client.finalInputs
        XCTAssertEqual(
            partialInputs.reduce(0) { $0 + $1.utf8.count },
            source.count
        )
        XCTAssertEqual(finalInputs.count, 1)
    }

    func testUTF8ScalarAtExactChunkBoundaryIsNotSplit() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in "partial" }
        let exact = String(repeating: "é", count: 32 * 1_024)
        let source = Data((exact + "\n" + exact).utf8)

        _ = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: source),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        let partials = await client.partialInputs
        XCTAssertEqual(partials.map(\.utf8.count), [64 * 1_024, 1, 64 * 1_024])
        XCTAssertEqual(Data(partials.joined().utf8), source)
    }

    func testSourceOverflowFailsBeforeAnyRequest() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await assertPipelineFails(.sourceTooLarge) {
            _ = try await MeetingIntelligencePipeline(client: client).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 4 * 1_024 * 1_024 + 1)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testOversizedPartialFailsWithoutFinalPublication() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in String(repeating: "x", count: 4 * 1_024 + 1) }

        await assertPipelineFails(.partialTooLarge) {
            _ = try await MeetingIntelligencePipeline(client: client).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 65 * 1_024)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }
        let finalInputs = await client.finalInputs
        XCTAssertEqual(finalInputs, [])
    }

    func testThirteenPartialsReduceInGroupsOfTwelveAndOne() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { input in
            input.utf8.count == 64 * 1_024 ? String(repeating: "p", count: 4 * 1_024) : "r"
        }
        let source = Data(repeating: 0x61, count: 13 * 64 * 1_024)

        _ = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: source),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        let partialInputs = await client.partialInputs
        let finalInputs = await client.finalInputs
        let finalInput = try XCTUnwrap(finalInputs.first)
        XCTAssertEqual(partialInputs.count, 15)
        XCTAssertEqual(finalInput, "r\nr")
    }

    func testDeadlineAtBoundaryFailsBeforeAnyRequest() async throws {
        let clock = DeadlinePipelineClock()
        let client = ScriptedMeetingIntelligenceClient()

        await assertPipelineFails(.deadlineExceeded) {
            _ = try await MeetingIntelligencePipeline(client: client, now: { clock.now() }).generate(
                transcript: self.transcript(bytes: Data("transcript".utf8)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testCancellationAtSecondChunkStopsBeforeLaterRequests() async throws {
        let client = BlockingMeetingIntelligenceClient(blockRequest: 2)
        let task = Task {
            try await MeetingIntelligencePipeline(client: client).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 130 * 1_024)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }

        await client.waitForBlockedRequest()
        task.cancel()
        await client.releaseBlockedRequest()
        await assertCancelled(task)
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testCancellationDuringReductionStopsBeforeFinalRequest() async throws {
        let client = BlockingMeetingIntelligenceClient(blockRequest: 14)
        let task = Task {
            try await MeetingIntelligencePipeline(client: client).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 13 * 64 * 1_024)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }

        await client.waitForBlockedRequest()
        task.cancel()
        await client.releaseBlockedRequest()
        await assertCancelled(task)
        let requestCount = await client.requestCount
        let finalRequestCount = await client.finalRequestCount
        XCTAssertEqual(requestCount, 14)
        XCTAssertEqual(finalRequestCount, 0)
    }

    func testCancellationBeforeFinalResultPreventsGeneratedContent() async throws {
        let client = BlockingMeetingIntelligenceClient(blockRequest: 3)
        let task = Task {
            try await MeetingIntelligencePipeline(client: client).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 65 * 1_024)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }

        await client.waitForBlockedRequest()
        task.cancel()
        await client.releaseBlockedRequest()
        await assertCancelled(task)
        let finalRequestCount = await client.finalRequestCount
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testEscapeHeavyInputIsShrunkByExactEncodedRequestSizerBeforeClientCall() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in "p" }
        let source = Data(String(repeating: "\\", count: 64 * 1_024 + 1).utf8)

        _ = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: source),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        let inputs = await client.partialInputs
        XCTAssertTrue(inputs.allSatisfy {
            MeetingIntelligenceRequestEncoder.body(
                input: $0,
                snapshot: try! self.providerSnapshot(),
                final: false
            ).count <= OpenAICompatibleMeetingIntelligenceClient.maximumRequestBytes
        })
        XCTAssertEqual(Data(inputs.prefix(2).joined().utf8), source)
    }

    func testEscapedMultibyteInputShrinksAtScalarBoundariesWithoutDataLoss() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in "p" }
        let source = Data(String(repeating: "\\é", count: 28 * 1_024).utf8)

        _ = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: source),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        let inputs = await client.partialInputs
        XCTAssertEqual(Data(inputs.prefix(2).joined().utf8), source)
        XCTAssertTrue(inputs.prefix(2).allSatisfy {
            $0.utf8.count <= OpenAICompatibleMeetingIntelligenceClient.maximumInputBytesBeforeEncoding &&
                MeetingIntelligenceRequestEncoder.body(
                    input: $0,
                    snapshot: try! self.providerSnapshot(),
                    final: false
                ).count <= OpenAICompatibleMeetingIntelligenceClient.maximumRequestBytes
        })
    }

    func testFourMiBWithEarlyNewlinesUsesExactlySixtyFourChunksAndSeventyOneRequests() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in "p" }
        let block = Data(("\n" + String(repeating: "a", count: 64 * 1_024 - 1)).utf8)
        var source = Data()
        for _ in 0 ..< 64 { source.append(block) }

        _ = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: source),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        let inputs = await client.partialInputs
        let total = await client.requestCount
        XCTAssertEqual(inputs.prefix(64).map(\.utf8.count), Array(repeating: 64 * 1_024, count: 64))
        XCTAssertEqual(Data(inputs.prefix(64).joined().utf8), source)
        XCTAssertEqual(total, 71)
    }

    func testSizingCanMakeMoreThanSixtyFourChunksFailBeforeAnyClientRequest() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        let source = Data(String(repeating: "\\", count: 4 * 1_024 * 1_024).utf8)

        await assertPipelineFails(.tooManyChunks) {
            _ = try await MeetingIntelligencePipeline(client: client).generate(
                transcript: self.transcript(bytes: source),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testDelimiterAfterNonzeroOffsetPreservesEveryByte() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in "p" }
        let source = Data((String(repeating: "a", count: 64 * 1_024) + "b\n\n" + String(repeating: "c", count: 64 * 1_024)).utf8)

        _ = try await MeetingIntelligencePipeline(client: client).generate(
            transcript: transcript(bytes: source),
            snapshot: try providerSnapshot(),
            onProgress: { _ in }
        )

        let partials = await client.partialInputs
        XCTAssertEqual(partials.prefix(2), [String(repeating: "a", count: 64 * 1_024), "b\n\n"])
        XCTAssertEqual(Data(partials.prefix(3).joined().utf8), source)
    }

    func testProgressCancellationPreventsRequestAndLaterProgress() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        let progress = ProgressCancellationRecorder()

        await assertPipelineFails(.cancelled) {
            _ = try await MeetingIntelligencePipeline(client: client).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 65 * 1_024)),
                snapshot: try self.providerSnapshot(),
                onProgress: { event in
                    progress.record(event)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(progress.events.count, 1)
    }

    func testNeverFinalSizerPermitsSeventyOneRequestsButRejectsTheSeventySecond() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in "p" }
        let sizer = NeverFinalRequestSizer()

        await assertPipelineFails(.tooManyRequests) {
            _ = try await MeetingIntelligencePipeline(client: client, sizer: sizer).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 4 * 1_024 * 1_024)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 71)
    }

    func testNeverFinalSizerReachesMaximumReductionDepthBeforePublication() async throws {
        let client = ScriptedMeetingIntelligenceClient()
        await client.setPartial { _ in "p" }

        await assertPipelineFails(.maximumDepthReached) {
            _ = try await MeetingIntelligencePipeline(
                client: client,
                sizer: NeverFinalRequestSizer()
            ).generate(
                transcript: self.transcript(bytes: Data(repeating: 0x61, count: 65 * 1_024)),
                snapshot: try self.providerSnapshot(),
                onProgress: { _ in }
            )
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 6)
    }

    private func transcript(bytes: Data) -> TranscriptDocumentSnapshot {
        .init(
            url: URL(fileURLWithPath: "/tmp/transcript.txt"),
            data: bytes,
            revision: .init(sha256: "test", byteCount: bytes.count)
        )
    }

    private func providerSnapshot() throws -> OpenAICompatibleProviderSnapshot {
        try .validated(
            profile: try .validated(
                baseURLText: "https://api.example",
                asrModel: "asr",
                llmModel: "llm",
                language: "English",
                prompt: ""
            ),
            apiKey: nil
        )
    }

    private func assertPipelineFails(
        _ expected: MeetingIntelligencePipelineError,
        _ body: @escaping () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected bounded pipeline failure")
        } catch let error as MeetingIntelligencePipelineError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected pipeline error: \(error)")
        }
    }

    private func assertCancelled(
        _ task: Task<MeetingIntelligenceGeneratedContent, Error>
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as MeetingIntelligencePipelineError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }
}

private actor ScriptedMeetingIntelligenceClient: MeetingIntelligenceRequesting {
    private var partial: @Sendable (String) -> String = { _ in "partial" }
    private var final = MeetingIntelligenceGeneratedContent(title: "Final", summary: "Summary")
    private(set) var partialInputs: [String] = []
    private(set) var finalInputs: [String] = []

    var requestCount: Int { partialInputs.count + finalInputs.count }

    func setPartial(_ value: @escaping @Sendable (String) -> String) {
        partial = value
    }

    func setFinal(_ value: MeetingIntelligenceGeneratedContent) {
        final = value
    }

    func requestPartialSummary(input: String, snapshot _: OpenAICompatibleProviderSnapshot) async throws -> String {
        partialInputs.append(input)
        return partial(input)
    }

    func requestFinalResult(input: String, snapshot _: OpenAICompatibleProviderSnapshot) async throws -> MeetingIntelligenceGeneratedContent {
        finalInputs.append(input)
        return final
    }
}

private final class DeadlinePipelineClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock().now
    private var reads = 0

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            reads += 1
            return reads <= 2 ? start : start.advanced(by: .seconds(1_800))
        }
    }
}

private final class ProgressCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingIntelligenceProgress] = []

    var events: [MeetingIntelligenceProgress] { lock.withLock { values } }

    func record(_ event: MeetingIntelligenceProgress) {
        lock.withLock { values.append(event) }
    }
}

private struct NeverFinalRequestSizer: MeetingIntelligenceRequestSizing {
    func fits(input _: String, snapshot _: OpenAICompatibleProviderSnapshot, final: Bool) -> Bool {
        !final
    }
}

private actor BlockingMeetingIntelligenceClient: MeetingIntelligenceRequesting {
    private let blockRequest: Int
    private var requestNumber = 0
    private var finalRequests = 0
    private var didStartBlockedRequest = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(blockRequest: Int) {
        self.blockRequest = blockRequest
    }

    var requestCount: Int { requestNumber }
    var finalRequestCount: Int { finalRequests }

    func waitForBlockedRequest() async {
        if didStartBlockedRequest { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func releaseBlockedRequest() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func requestPartialSummary(input _: String, snapshot _: OpenAICompatibleProviderSnapshot) async throws -> String {
        try await recordAndWaitIfNeeded()
        return String(repeating: "p", count: 4 * 1_024)
    }

    func requestFinalResult(input _: String, snapshot _: OpenAICompatibleProviderSnapshot) async throws -> MeetingIntelligenceGeneratedContent {
        finalRequests += 1
        try await recordAndWaitIfNeeded()
        return .init(title: "Final", summary: "Summary")
    }

    private func recordAndWaitIfNeeded() async throws {
        requestNumber += 1
        guard requestNumber == blockRequest else { return }
        didStartBlockedRequest = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}
