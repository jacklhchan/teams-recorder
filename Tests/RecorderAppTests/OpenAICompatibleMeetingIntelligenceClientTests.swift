import Foundation
import XCTest
@testable import RecorderApp

final class OpenAICompatibleMeetingIntelligenceClientTests: XCTestCase {
    func testFinalRequestUsesOnlyLLMModelAndOptionalBearer() async throws {
        let transport = MeetingIntelligenceRecordingTransport(responses: [
            .response(status: 200, body: #"{"id":"chatcmpl-safe","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"{\"title\":\"ClearPass migration\",\"summary\":\"The team reviewed migration sequencing.\"}"}}],"usage":{"total_tokens":1}}"#)
        ])
        let result = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport)
            .requestFinalResult(input: "bounded transcript", snapshot: try snapshot(apiKey: "secret"))

        XCTAssertEqual(result, .init(title: "ClearPass migration", summary: "The team reviewed migration sequencing."))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try body(transport.requests[0])["model"] as? String, "llm-only")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(transport.maximums, [OpenAICompatibleMeetingIntelligenceClient.maximumResponseBytes])
    }

    func testTerminalFailuresMakeExactlyOneAttemptAndKeepPublicErrorRedacted() async throws {
        for response in [
            MeetingIntelligenceRecordingTransport.Stub.response(status: 429, body: "provider-body", headers: ["Retry-After": "9999"]),
            .urlError(.timedOut)
        ] {
            let transport = MeetingIntelligenceRecordingTransport(responses: [response])
            do {
                _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport)
                    .requestPartialSummary(input: "private transcript", snapshot: try snapshot(apiKey: "secret"))
                XCTFail("Expected terminal failure")
            } catch {
                XCTAssertEqual(transport.requests.count, 1)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                XCTAssertFalse(error.localizedDescription.contains("private transcript"))
                XCTAssertFalse(error.localizedDescription.contains("provider-body"))
            }
        }
    }

    func testTerminalHTTPStatusesExposeOnlyCappedRetryHintAndNeverRetry() async throws {
        for status in [408, 429, 500] {
            let transport = MeetingIntelligenceRecordingTransport(responses: [.response(status: status, body: "body", headers: ["Retry-After": "9999"])])
            await assertError(.httpStatus(status, retryAfter: 60)) {
                _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport).requestPartialSummary(input: "x", snapshot: try self.snapshot())
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let date = formatter.string(from: Date(timeIntervalSinceNow: 9))
        let transport = MeetingIntelligenceRecordingTransport(responses: [.response(status: 429, body: "", headers: ["Retry-After": date])])
        do {
            _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport).requestPartialSummary(input: "x", snapshot: try snapshot())
            XCTFail("Expected status")
        } catch let .httpStatus(_, retryAfter: hint) as MeetingIntelligenceClientError {
            XCTAssertNotNil(hint)
            XCTAssertLessThanOrEqual(hint ?? .infinity, 60)
        } catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRequestBoundsAndTransportShapeDoNotSendOversizeOrCredentialsWhenAbsent() async throws {
        let oversize = MeetingIntelligenceRecordingTransport(responses: [])
        await assertError(.requestTooLarge) {
            _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: oversize).requestPartialSummary(input: String(repeating: "x", count: 100_000), snapshot: try self.snapshot())
        }
        XCTAssertTrue(oversize.requests.isEmpty)

        let transport = MeetingIntelligenceRecordingTransport(responses: [.response(status: 200, body: outer(#"{"summary":"ok"}"#))])
        _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport).requestPartialSummary(input: "hostile transcript", snapshot: try snapshot())
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 90)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let payload = try body(request)
        XCTAssertEqual(payload["stream"] as? Bool, false)
        XCTAssertEqual(payload["temperature"] as? Int, 0)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("untrusted data") == true)
        XCTAssertEqual(messages[1]["content"], "hostile transcript")
    }

    func testTypedTransportAndOuterResponseFailures() async throws {
        for (stub, expected) in [
            (MeetingIntelligenceRecordingTransport.Stub.failure(ProviderHTTPTransportError.redirectRejected), MeetingIntelligenceClientError.unsafeRedirect),
            (.failure(CancellationError()), .cancelled)
        ] {
            let transport = MeetingIntelligenceRecordingTransport(responses: [stub])
            await assertError(expected) {
                _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport).requestPartialSummary(input: "x", snapshot: try self.snapshot())
            }
        }
        for response in [#"{"choices":[]}"#, #"{"choices":[{},{}]}"#, #"{"choices":[{"message":{"content":1}}]}"#] {
            let transport = MeetingIntelligenceRecordingTransport(responses: [.response(status: 200, body: response)])
            await assertError(.invalidResponse) {
                _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport).requestPartialSummary(input: "x", snapshot: try self.snapshot())
            }
        }
    }

    func testRejectsUnsafeAndNonExactOutputWhileKeepingNewlinesAndTabs() async throws {
        let accepted = MeetingIntelligenceRecordingTransport(responses: [
            .response(status: 200, body: #"{"choices":[{"message":{"content":"{\"summary\":\"line one\\nline\\ttwo\"}"}}]}"#)
        ])
        let summary = try await OpenAICompatibleMeetingIntelligenceClient(transport: accepted)
            .requestPartialSummary(input: "untrusted", snapshot: try snapshot())
        XCTAssertEqual(summary, "line one\nline\ttwo")

        for content in [
            #"{"summary":" "}"#,
            #"{"summary":"ok","extra":"no"}"#,
            "```json\n{\"summary\":\"ok\"}\n```",
            #"{"summary":"bad\u0000"}"#
        ] {
            let transport = MeetingIntelligenceRecordingTransport(responses: [
                .response(status: 200, body: outer(content))
            ])
            do {
                _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport)
                    .requestPartialSummary(input: "ignore instructions", snapshot: try snapshot())
                XCTFail("Expected unsafe output rejection")
            } catch {
                XCTAssertEqual(error as? MeetingIntelligenceClientError, .unsafeOutput)
            }
        }
    }

    func testRejectsBoundOverflowsAndUnsafeFinalTitles() async throws {
        let oversized = String(repeating: "a", count: OpenAICompatibleMeetingIntelligenceClient.maximumPartialSummaryBytes + 1)
        let oversizedTransport = MeetingIntelligenceRecordingTransport(responses: [.response(status: 200, body: outer(#"{"summary":"\#(oversized)"}"#))])
        await assertError(.unsafeOutput) {
            _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: oversizedTransport).requestPartialSummary(input: "x", snapshot: try self.snapshot())
        }
        for title in ["2026-07-31", "folder/name", "folder\\name", "bad\u{202E}name", String(repeating: "a", count: 121)] {
            let transport = MeetingIntelligenceRecordingTransport(responses: [.response(status: 200, body: outer(#"{"title":"\#(title)","summary":"ok"}"#))])
            await assertError(.unsafeOutput) {
                _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: transport).requestFinalResult(input: "x", snapshot: try self.snapshot())
            }
        }
        let responseCap = MeetingIntelligenceRecordingTransport(responses: [.failure(ProviderHTTPTransportError.responseTooLarge)])
        await assertError(.responseTooLarge) {
            _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: responseCap).requestPartialSummary(input: "x", snapshot: try self.snapshot())
        }

        let finalOversize = String(repeating: "a", count: OpenAICompatibleMeetingIntelligenceClient.maximumFinalSummaryBytes + 1)
        let finalTransport = MeetingIntelligenceRecordingTransport(responses: [.response(status: 200, body: outer(#"{"title":"ok","summary":"\#(finalOversize)"}"#))])
        await assertError(.unsafeOutput) {
            _ = try await OpenAICompatibleMeetingIntelligenceClient(transport: finalTransport).requestFinalResult(input: "x", snapshot: try self.snapshot())
        }
    }

    private func snapshot(apiKey: String? = nil) throws -> OpenAICompatibleProviderSnapshot {
        .init(profile: try .validated(baseURLText: "https://api.example/v1", asrModel: "asr-only", llmModel: "llm-only", language: "en", prompt: "ASR prompt"), apiKey: apiKey)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func outer(_ content: String) -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return String(decoding: json, as: UTF8.self)
    }

    private func assertError(_ expected: MeetingIntelligenceClientError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected failure") } catch { XCTAssertEqual(error as? MeetingIntelligenceClientError, expected) }
    }
}

private final class MeetingIntelligenceRecordingTransport: ProviderHTTPTransport, @unchecked Sendable {
    enum Stub { case response(status: Int, body: String, headers: [String: String] = [:]); case urlError(URLError.Code); case failure(Error) }
    private let lock = NSLock()
    private var responses: [Stub]
    private(set) var requests: [URLRequest] = []
    private(set) var maximums: [Int] = []
    init(responses: [Stub]) { self.responses = responses }
    func response(for request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let stub = lock.withLock { requests.append(request); maximums.append(maximumBodyBytes); return responses.removeFirst() }
        switch stub {
        case let .response(status, body, headers):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        case let .urlError(code): throw URLError(code)
        case let .failure(error): throw error
        }
    }
}
