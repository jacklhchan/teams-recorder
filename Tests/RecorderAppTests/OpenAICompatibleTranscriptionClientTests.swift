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

    func testRetryPolicyRetriesOnlySelectedTransientTransportErrors() {
        let policy = TranscriptionRetryPolicy()

        for code in [
            URLError.timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ] {
            XCTAssertTrue(policy.shouldRetry(error: URLError(code)))
        }
        for code in [
            URLError.cancelled,
            .userAuthenticationRequired,
            .badURL,
            .serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .secureConnectionFailed
        ] {
            XCTAssertFalse(policy.shouldRetry(error: URLError(code)))
        }
        XCTAssertFalse(policy.shouldRetry(error: CancellationError()))
        XCTAssertFalse(
            policy.shouldRetry(
                error: NSError(domain: "permanent", code: 1)
            )
        )
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

    func testRedirectedRequestCarriesAuthorizationOnlyToSameOrigin() throws {
        let source = try uploadRequest(
            url:
                "https://api.example/v1/audio/transcriptions",
            authorization: "Bearer private-key"
        )
        let sameOrigin = try uploadRequest(
            url:
                "https://api.example/v2/audio/transcriptions"
        )
        let crossOrigin = try uploadRequest(
            url: "https://evil.example/steal",
            authorization: "Bearer private-key"
        )

        XCTAssertEqual(
            ProviderRedirectPolicy.redirectedRequest(
                from: source,
                proposed: sameOrigin,
                statusCode: 307
            )?.value(forHTTPHeaderField: "Authorization"),
            "Bearer private-key"
        )
        XCTAssertNil(
            ProviderRedirectPolicy.redirectedRequest(
                from: source,
                proposed: crossOrigin,
                statusCode: 307
            ),
            "Rejecting the request prevents the bearer token from leaving "
                + "the configured origin."
        )
    }

    func testRedirectPolicyAllowsOnlyUploadPreservingStatusCodes() throws {
        let source = try uploadRequest(
            url:
                "https://api.example/v1/audio/transcriptions"
        )
        let proposed = try uploadRequest(
            url:
                "https://api.example/v2/audio/transcriptions"
        )

        for status in [307, 308] {
            XCTAssertNotNil(
                ProviderRedirectPolicy.redirectedRequest(
                    from: source,
                    proposed: proposed,
                    statusCode: status
                )
            )
        }
        for status in [301, 302, 303, 305] {
            XCTAssertNil(
                ProviderRedirectPolicy.redirectedRequest(
                    from: source,
                    proposed: proposed,
                    statusCode: status
                )
            )
        }
    }

    func testRedirectPolicyRejectsChangedMethodAndMissingBody() throws {
        let source = try uploadRequest(
            url:
                "https://api.example/v1/audio/transcriptions"
        )
        var changedMethod = try uploadRequest(
            url:
                "https://api.example/v2/audio/transcriptions"
        )
        changedMethod.httpMethod = "GET"
        var missingBody = try uploadRequest(
            url:
                "https://api.example/v2/audio/transcriptions"
        )
        missingBody.httpBody = nil

        XCTAssertNil(
            ProviderRedirectPolicy.redirectedRequest(
                from: source,
                proposed: changedMethod,
                statusCode: 307
            )
        )
        XCTAssertNil(
            ProviderRedirectPolicy.redirectedRequest(
                from: source,
                proposed: missingBody,
                statusCode: 308
            )
        )
    }

    func testRedirectPolicyAcceptsNormalizedJSONAndRejectsGETOrContentTypeChangesWithoutAuthorization() throws {
        var source = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example/v1/chat/completions")))
        source.httpMethod = "POST"
        source.httpBody = Data("{}".utf8)
        source.setValue("Application/JSON; charset=utf-8", forHTTPHeaderField: "Content-Type")
        source.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        var proposed = source
        proposed.url = try XCTUnwrap(URL(string: "https://api.example/v1/chat/redirected"))
        proposed.setValue("application/json", forHTTPHeaderField: "Content-Type")
        proposed.setValue("Bearer leaked", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(ProviderRedirectPolicy.redirectedRequest(from: source, proposed: proposed, statusCode: 308)?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        proposed.httpMethod = "GET"
        XCTAssertNil(ProviderRedirectPolicy.redirectedRequest(from: source, proposed: proposed, statusCode: 307))
        proposed.httpMethod = "POST"
        proposed.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        XCTAssertNil(ProviderRedirectPolicy.redirectedRequest(from: source, proposed: proposed, statusCode: 307))

        let multipart = try uploadRequest(url: "https://api.example/v1/audio/transcriptions")
        var changedBoundary = multipart
        changedBoundary.url = try XCTUnwrap(URL(string: "https://api.example/v1/audio/redirected"))
        changedBoundary.setValue("multipart/form-data; boundary=changed", forHTTPHeaderField: "Content-Type")
        XCTAssertNil(ProviderRedirectPolicy.redirectedRequest(from: multipart, proposed: changedBoundary, statusCode: 307))
        changedBoundary.setValue("multipart/form-data; boundary=test-BOUNDARY", forHTTPHeaderField: "Content-Type")
        XCTAssertNil(ProviderRedirectPolicy.redirectedRequest(from: multipart, proposed: changedBoundary, statusCode: 307))
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

    func testTransientFailuresStopAtMaximumRetryBudget() async throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .http(status: 503, body: "{}"),
                .http(status: 503, body: "{}"),
                .http(status: 503, body: "{}"),
                .http(status: 200, body: #"{"text":"too late"}"#)
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
            XCTFail("Expected the retry budget to be exhausted")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleTranscriptionError,
                .httpStatus(503)
            )
        }

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(sleeps.values.count, 2)
    }

    func testTransientTransportFailureRetriesThenSucceeds() async throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .urlError(.timedOut),
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
        XCTAssertEqual(sleeps.values.count, 1)
    }

    func testTransientTransportFailuresStopAtMaximumRetryBudget() async throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .urlError(.networkConnectionLost),
                .urlError(.networkConnectionLost),
                .urlError(.networkConnectionLost),
                .http(status: 200, body: #"{"text":"too late"}"#)
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
            XCTFail("Expected the retry budget to be exhausted")
        } catch {
            XCTAssertEqual(
                (error as? URLError)?.code,
                .networkConnectionLost
            )
        }

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(sleeps.values.count, 2)
    }

    func testCancellationDuringTransportRetryDelayStopsAnotherUpload() throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .urlError(.cannotConnectToHost),
                .http(status: 200, body: #"{"text":"too late"}"#)
            ]
        )
        let retryDelayStarted = expectation(
            description: "Transport retry delay started"
        )
        let sleeper = ManualTranscriptionSleeper {
            retryDelayStarted.fulfill()
        }
        let client = makeClient(
            transport: transport,
            sleep: { seconds in
                try await sleeper.sleep(seconds)
            }
        )
        let snapshot = try makeSnapshot()
        let cancellationOutcomes = LockedValues<Bool>()
        let cancellationFinished = expectation(
            description: "Transport retry cancellation finished"
        )
        let task = Task {
            defer { cancellationFinished.fulfill() }
            do {
                _ = try await client.transcribe(
                    audioData: Data([1]),
                    fileName: "chunk.m4a",
                    snapshot: snapshot,
                    prompt: ""
                )
                cancellationOutcomes.append(false)
            } catch {
                cancellationOutcomes.append(error is CancellationError)
            }
        }
        wait(for: [retryDelayStarted], timeout: 5)

        task.cancel()
        wait(for: [cancellationFinished], timeout: 5)

        XCTAssertEqual(cancellationOutcomes.values, [true])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCancellationDuringRetryDelayStopsBeforeAnotherUpload() throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .http(status: 503, body: "{}"),
                .http(status: 200, body: #"{"text":"too late"}"#)
            ]
        )
        let retryDelayStarted = expectation(
            description: "HTTP retry delay started"
        )
        let sleeper = ManualTranscriptionSleeper {
            retryDelayStarted.fulfill()
        }
        let client = makeClient(
            transport: transport,
            sleep: { seconds in
                try await sleeper.sleep(seconds)
            }
        )
        let snapshot = try makeSnapshot()
        let cancellationOutcomes = LockedValues<Bool>()
        let cancellationFinished = expectation(
            description: "HTTP retry cancellation finished"
        )
        let task = Task {
            defer { cancellationFinished.fulfill() }
            do {
                _ = try await client.transcribe(
                    audioData: Data([1]),
                    fileName: "chunk.m4a",
                    snapshot: snapshot,
                    prompt: ""
                )
                cancellationOutcomes.append(false)
            } catch {
                cancellationOutcomes.append(error is CancellationError)
            }
        }
        wait(for: [retryDelayStarted], timeout: 5)

        task.cancel()
        wait(for: [cancellationFinished], timeout: 5)

        XCTAssertEqual(cancellationOutcomes.values, [true])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCancellationBeforeResponseProcessingRejectsCompletedBody() async throws {
        let transport = RecordingTranscriptionTransport(
            responses: [
                .http(
                    status: 200,
                    body: #"{"text":"must not publish"}"#,
                    cancelTaskBeforeReturning: true
                )
            ]
        )
        let client = makeClient(transport: transport)
        let task = Task {
            try await client.transcribe(
                audioData: Data([1]),
                fileName: "chunk.m4a",
                snapshot: try makeSnapshot(),
                prompt: ""
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before response processing")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            Task.isCancelled,
            "The XCTest harness task must remain active."
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

    private func uploadRequest(
        url: String,
        authorization: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
        request.httpMethod = "POST"
        request.httpBody = Data("multipart-body".utf8)
        request.setValue(
            "multipart/form-data; boundary=test-boundary",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            authorization,
            forHTTPHeaderField: "Authorization"
        )
        return request
    }
}

private final class RecordingTranscriptionTransport:
    ProviderHTTPTransport,
    @unchecked Sendable
{
    enum StubResponse {
        case response(
            status: Int,
            body: Data,
            headers: [String: String],
            cancelTaskBeforeReturning: Bool
        )
        case urlError(URLError.Code)

        static func http(
            status: Int,
            body: String,
            headers: [String: String] = [:],
            cancelTaskBeforeReturning: Bool = false
        ) -> StubResponse {
            .response(
                status: status,
                body: Data(body.utf8),
                headers: headers,
                cancelTaskBeforeReturning: cancelTaskBeforeReturning
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
        switch response {
        case .urlError(let code):
            throw URLError(code)
        case .response(
            let status,
            let body,
            let headers,
            let cancelTaskBeforeReturning
        ):
            if cancelTaskBeforeReturning {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
            )
        }
    }
}

private final class ManualTranscriptionSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var wasCancelled = false

    init(onStart: @escaping @Sendable () -> Void) {
        self.onStart = onStart
    }

    func sleep(_: Double) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let cancelImmediately = lock.withLock {
                    if wasCancelled {
                        return true
                    }
                    self.continuation = continuation
                    return false
                }
                onStart()
                if cancelImmediately {
                    continuation.resume(
                        throwing: CancellationError()
                    )
                }
            }
        }, onCancel: {
            let continuation = self.lock.withLock {
                self.wasCancelled = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        })
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
