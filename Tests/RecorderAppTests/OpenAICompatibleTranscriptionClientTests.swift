import Foundation
import XCTest
@testable import RecorderApp

final class OpenAICompatibleTranscriptionClientTests: XCTestCase {
    func testRetryPolicyRetriesOnlyTransientStatuses() {
        let policy = TranscriptionRetryPolicy()

        for status in [408, 429, 500, 503, 599] {
            XCTAssertTrue(policy.shouldRetry(statusCode: status))
        }
        for status in [400, 401, 403, 404, 422] {
            XCTAssertFalse(policy.shouldRetry(statusCode: status))
        }
    }

    func testRedirectPolicyRequiresSameOriginAndScheme() {
        let source = URL(
            string: "https://api.example/v1/audio/transcriptions"
        )!

        XCTAssertTrue(
            ProviderRedirectPolicy.allows(
                from: source,
                to: URL(
                    string: "https://api.example/v2/audio/transcriptions"
                )!
            )
        )
        XCTAssertFalse(
            ProviderRedirectPolicy.allows(
                from: source,
                to: URL(string: "https://evil.example/steal")!
            )
        )
        XCTAssertFalse(
            ProviderRedirectPolicy.allows(
                from: source,
                to: URL(
                    string: "http://api.example/v1/audio/transcriptions"
                )!
            )
        )
    }

    func testMultipartBuilderCapsAudioAndIncludesTypedFields() throws {
        let builder = TranscriptionMultipartBuilder(
            maximumAudioBytes: 3,
            boundary: "test-boundary"
        )

        XCTAssertThrowsError(
            try builder.makeBody(
                audioData: Data([0, 1, 2, 3]),
                fileName: "chunk.m4a",
                model: "asr-model",
                language: "yue",
                prompt: "meeting context",
                responseFormat: .json
            )
        ) {
            XCTAssertEqual(
                $0 as? OpenAICompatibleTranscriptionError,
                .audioChunkTooLarge
            )
        }

        let body = try builder.makeBody(
            audioData: Data([0, 1, 2]),
            fileName: "chunk.m4a",
            model: "asr-model",
            language: "yue",
            prompt: "meeting context",
            responseFormat: .verboseJSON
        )
        let text = String(decoding: body, as: UTF8.self)
        for expected in [
            #"name="file"; filename="chunk.m4a""#,
            #"name="model""#,
            "asr-model",
            #"name="language""#,
            "yue",
            #"name="prompt""#,
            "meeting context",
            #"name="response_format""#,
            "verbose_json"
        ] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected)")
        }
    }

    func testVerboseJSONRejectionNegotiatesJSONWithoutTransientRetry() async throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .http(status: 400, body: #"{"error":"unsupported"}"#),
                .http(status: 200, body: #"{"text":"done"}"#)
            ]
        )
        let sleeps = LockedValues<Double>()
        let client = makeClient(
            transport: transport,
            sleep: { sleeps.append($0) }
        )

        let result = try await client.transcribe(
            audioData: Data([1, 2, 3]),
            fileName: "chunk.m4a",
            snapshot: try makeSnapshot(),
            prompt: "context"
        )

        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(result.responseFormat, .json)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(
            transport.requests.map { requestFormat(in: $0) },
            [.verboseJSON, .json]
        )
        XCTAssertEqual(sleeps.values, [])
    }

    func testRetryAfterIsHonoredFor429ThenSucceeds() async throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .http(
                    status: 429,
                    body: "{}",
                    headers: ["Retry-After": "2"]
                ),
                .http(status: 200, body: #"{"text":"done"}"#)
            ]
        )
        let sleeps = LockedValues<Double>()
        let client = makeClient(
            transport: transport,
            sleep: { sleeps.append($0) }
        )

        let result = try await client.transcribe(
            audioData: Data([1]),
            fileName: "chunk.m4a",
            snapshot: try makeSnapshot(),
            prompt: ""
        )

        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(sleeps.values, [2])
    }

    func testRetryAfterIsBoundedAndSupportsHTTPDate() throws {
        let policy = TranscriptionRetryPolicy()
        let url = try XCTUnwrap(URL(string: "https://api.example/v1"))
        let numeric = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "9999"]
            )
        )
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: "2026-07-29T12:00:00Z"
            )
        )
        let dated = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: nil,
                headerFields: [
                    "Retry-After":
                        "Wed, 29 Jul 2026 12:00:30 GMT"
                ]
            )
        )

        XCTAssertEqual(
            policy.delay(
                after: numeric,
                failedAttempt: 0,
                now: now,
                jitter: { _ in 0 }
            ),
            60
        )
        XCTAssertEqual(
            policy.delay(
                after: dated,
                failedAttempt: 0,
                now: now,
                jitter: { _ in 0 }
            ),
            30
        )
    }

    func testConfiguration4xxStopsWithoutRetryingJSONRequest() async throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .http(status: 400, body: "{}"),
                .http(status: 422, body: "{}")
            ]
        )
        let sleeps = LockedValues<Double>()
        let client = makeClient(
            transport: transport,
            sleep: { sleeps.append($0) }
        )

        do {
            _ = try await client.transcribe(
                audioData: Data([1]),
                fileName: "chunk.m4a",
                snapshot: try makeSnapshot(),
                prompt: ""
            )
            XCTFail("Expected terminal configuration failure")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleTranscriptionError,
                .httpStatus(422)
            )
        }

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(sleeps.values, [])
    }

    func testRequestUsesCappedResponseAndNeverPersistsAuthorizationInError() async throws {
        let secret = "private-key-material"
        let transport = RecordingTranscriptionTransport(
            responses: [.http(status: 401, body: secret)]
        )
        let client = makeClient(transport: transport)
        let snapshot = try makeSnapshot(apiKey: secret)

        do {
            _ = try await client.transcribe(
                audioData: Data([1]),
                fileName: "chunk.m4a",
                snapshot: snapshot,
                prompt: ""
            )
            XCTFail("Expected authentication rejection")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleTranscriptionError,
                .authenticationRejected
            )
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }

        XCTAssertEqual(
            transport.maximumBodyBytes,
            [OpenAICompatibleTranscriptionClient.maximumResponseBytes]
        )
        XCTAssertEqual(
            transport.requests.first?.value(
                forHTTPHeaderField: "Authorization"
            ),
            "Bearer \(secret)"
        )
    }

    private func makeClient(
        transport: RecordingTranscriptionTransport,
        sleep: @escaping @Sendable (Double) async throws -> Void = { _ in }
    ) -> OpenAICompatibleTranscriptionClient {
        OpenAICompatibleTranscriptionClient(
            transport: transport,
            sleep: sleep,
            jitter: { _ in 0 },
            boundary: { "test-boundary" }
        )
    }

    private func makeSnapshot(
        apiKey: String? = nil
    ) throws -> OpenAICompatibleProviderSnapshot {
        .init(
            profile: try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example/v1",
                asrModel: "asr-model",
                llmModel: "llm-model",
                language: "yue",
                prompt: "profile prompt"
            ),
            apiKey: apiKey
        )
    }

    private func requestFormat(
        in request: URLRequest
    ) -> TranscriptionResponseFormat? {
        guard let body = request.httpBody else { return nil }
        let text = String(decoding: body, as: UTF8.self)
        if text.contains("verbose_json") {
            return .verboseJSON
        }
        return text.contains("\r\njson\r\n") ? .json : nil
    }
}

private final class RecordingTranscriptionTransport:
    ProviderHTTPTransport,
    @unchecked Sendable
{
    struct StubResponse {
        let status: Int
        let body: Data
        let headers: [String: String]

        static func http(
            status: Int,
            body: String,
            headers: [String: String] = [:]
        ) -> StubResponse {
            .init(
                status: status,
                body: Data(body.utf8),
                headers: headers
            )
        }
    }

    private let lock = NSLock()
    private var responses: [StubResponse]
    private(set) var requests: [URLRequest] = []
    private(set) var maximumBodyBytes: [Int] = []

    init(responses: [StubResponse]) {
        self.responses = responses
    }

    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let response = lock.withLock {
            requests.append(request)
            self.maximumBodyBytes.append(maximumBodyBytes)
            return responses.removeFirst()
        }
        return (
            response.body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
        )
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}
