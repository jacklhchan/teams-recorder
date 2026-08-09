import Foundation
import XCTest
@testable import RecorderApp

final class OpenAICompatibleProviderClientTests: XCTestCase {
    override func tearDown() {
        ControlledURLProtocol.reset()
        super.tearDown()
    }

    func testURLSessionTransportUsesNoPersistentCacheAndReloadPolicy() async throws {
        let transport = URLSessionProviderHTTPTransport(
            configuration: controlledSessionConfiguration()
        )
        let request = URLRequest(url: URL(string: "https://provider.test/models")!)
        ControlledURLProtocol.install { protocolInstance in
            protocolInstance.respond(status: 200, body: Data("{}".utf8))
        }

        let (data, _) = try await transport.response(
            for: request,
            maximumBodyBytes: 32
        )

        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertEqual(
            ControlledURLProtocol.lastRequest?.cachePolicy,
            .reloadIgnoringLocalCacheData
        )
        XCTAssertNil(transport.configurationForTesting.urlCache)
        XCTAssertEqual(
            transport.configurationForTesting.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
    }

    func testURLSessionTransportRejectsDeclaredContentLengthAndCancelsTask() async {
        let transport = URLSessionProviderHTTPTransport(
            configuration: controlledSessionConfiguration()
        )
        ControlledURLProtocol.install { protocolInstance in
            protocolInstance.respond(
                status: 200,
                headers: ["Content-Length": "33"],
                body: Data()
            )
        }

        await assertTransportError(
            transport,
            maximumBodyBytes: 32,
            equals: .responseTooLarge
        )
        XCTAssertEqual(ControlledURLProtocol.stopLoadingCount, 1)
    }

    func testURLSessionTransportCancelsOnUnknownLengthChunkOverCapWithoutRetainingIt() async {
        let retainedByteCounts = LockedValues<Int>()
        let transport = URLSessionProviderHTTPTransport(
            configuration: controlledSessionConfiguration(),
            retainedBodyByteCountObserver: { retainedByteCounts.append($0) }
        )
        ControlledURLProtocol.install { protocolInstance in
            protocolInstance.respond(status: 200, body: nil)
            protocolInstance.send(Data(repeating: 1, count: 32))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                protocolInstance.send(Data([2]))
                protocolInstance.finishResponse()
            }
        }

        await assertTransportError(
            transport,
            maximumBodyBytes: 32,
            equals: .responseTooLarge
        )
        XCTAssertTrue(
            retainedByteCounts.values.allSatisfy { $0 <= 32 },
            "A chunk that crosses the cap must not increase retained bytes."
        )
        XCTAssertEqual(ControlledURLProtocol.stopLoadingCount, 1)
    }

    func testURLSessionTransportCapsNonSuccessResponseBeforeClientStatusHandling() async {
        let transport = URLSessionProviderHTTPTransport(
            configuration: controlledSessionConfiguration()
        )
        ControlledURLProtocol.install { protocolInstance in
            protocolInstance.respond(
                status: 500,
                headers: ["Content-Length": "33"],
                body: Data()
            )
        }

        await assertTransportError(
            transport,
            maximumBodyBytes: 32,
            equals: .responseTooLarge
        )
        XCTAssertEqual(ControlledURLProtocol.stopLoadingCount, 1)
    }

    func testURLSessionTransportCancellationDuringUploadCompletesOnceAndCleansUpLateCallbacks() async {
        let transport = URLSessionProviderHTTPTransport(
            configuration: controlledSessionConfiguration()
        )
        ControlledURLProtocol.install { protocolInstance in
            ControlledURLProtocol.markRequestStarted()
            protocolInstance.respond(status: 200, body: nil)
        }

        var request = URLRequest(
            url: URL(
                string:
                    "https://provider.test/v1/audio/transcriptions"
            )!
        )
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 7, count: 4_096)
        let uploadRequest = request
        let task = Task {
            try await transport.response(
                for: uploadRequest,
                maximumBodyBytes: 32
            )
        }
        await ControlledURLProtocol.waitForRequestStart()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        ControlledURLProtocol.finishLatestResponse()
        let didStopLoading = await ControlledURLProtocol.waitForStopLoadingCount(1)
        XCTAssertTrue(didStopLoading)
        XCTAssertEqual(ControlledURLProtocol.stopLoadingCount, 1)
        XCTAssertTrue(transport.hasReleasedTaskAndSessionForTesting)
    }

    func testModelDiscoveryRejectsActual307And308RedirectBeforeDestinationLoadsOrReceivesAuthorization() async {
        for status in [307, 308] {
            ControlledURLProtocol.reset()
            let transport = URLSessionProviderHTTPTransport(configuration: controlledSessionConfiguration())
            ControlledURLProtocol.install { instance in
                instance.redirect(status: status, to: URL(string: "https://provider.test/models-redirected")!)
            }
            var request = URLRequest(url: URL(string: "https://provider.test/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            await assertTransportError(transport, maximumBodyBytes: 32, equals: .redirectRejected, request: request)
            XCTAssertEqual(ControlledURLProtocol.requests.count, 1)
        }
    }

    func testRedirectDelegateAcceptsExactlyOneGenericOrHKTCredential() throws {
        for (contentType, status, header, value, other) in [("application/json", 307, "Authorization", "Bearer secret", "X-API-KEY"), ("multipart/form-data; boundary=CaseSensitive", 308, "X-API-KEY", "api-key", "Authorization")] {
            var source = URLRequest(url: try XCTUnwrap(URL(string: "https://provider.test/v1/original")))
            source.httpMethod = "POST"
            source.httpBody = Data("exact body".utf8)
            source.setValue(contentType, forHTTPHeaderField: "Content-Type")
            source.setValue(value, forHTTPHeaderField: header)
            var destination = source
            destination.url = try XCTUnwrap(URL(string: "https://provider.test/v1/redirected"))
            destination.setValue("leaked", forHTTPHeaderField: header)
            destination.setValue("leaked", forHTTPHeaderField: other)
            let redirected = try XCTUnwrap(ProviderRedirectDelegate(source: source).redirectedRequest(proposed: destination, statusCode: status))
            XCTAssertEqual(redirected.httpMethod, "POST")
            XCTAssertEqual(redirected.httpBody, Data("exact body".utf8))
            XCTAssertEqual(redirected.value(forHTTPHeaderField: "Content-Type"), contentType)
            XCTAssertEqual(redirected.value(forHTTPHeaderField: header), value)
            XCTAssertNil(redirected.value(forHTTPHeaderField: other))
        }
    }

    func testRedirectDelegateRejectsAmbiguousDualCredentialSource() throws {
        var source = URLRequest(url: try XCTUnwrap(URL(string: "https://provider.test/v1/original")))
        source.httpMethod = "POST"; source.httpBody = Data("body".utf8)
        source.setValue("application/json", forHTTPHeaderField: "Content-Type")
        source.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        source.setValue("api-key", forHTTPHeaderField: "X-API-KEY")
        var proposed = source
        proposed.url = try XCTUnwrap(URL(string: "https://provider.test/v1/redirected"))
        XCTAssertNil(ProviderRedirectDelegate(source: source).redirectedRequest(proposed: proposed, statusCode: 307))
    }

    func testRedirectDelegateRejectsMutationsWithoutReturningCredentials() throws {
        var source = URLRequest(url: try XCTUnwrap(URL(string: "https://provider.test/v1/original")))
        source.httpMethod = "POST"
        source.httpBody = Data("body".utf8)
        source.setValue("application/json", forHTTPHeaderField: "Content-Type")
        source.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        for mutate in ["origin", "downgrade", "port", "status", "method", "body", "type"] {
            var proposed = source
            proposed.url = try XCTUnwrap(URL(string: "https://provider.test/v1/redirected"))
            switch mutate {
            case "origin": proposed.url = try XCTUnwrap(URL(string: "https://evil.test/v1/redirected"))
            case "downgrade": proposed.url = try XCTUnwrap(URL(string: "http://provider.test/v1/redirected"))
            case "port": proposed.url = try XCTUnwrap(URL(string: "https://provider.test:444/v1/redirected"))
            case "method": proposed.httpMethod = "GET"
            case "body": proposed.httpBody = Data("changed".utf8)
            case "type": proposed.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            default: break
            }
            let status = mutate == "status" ? 302 : 307
            XCTAssertNil(ProviderRedirectDelegate(source: source).redirectedRequest(proposed: proposed, statusCode: status), mutate)
        }
    }

    func testListsModelsWithOptionalBearerHeader() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(
                status: 200,
                body: #"{"data":[{"id":"asr-a"},{"id":"llm-b"}]}"#
            ))
        )

        let report = try await OpenAICompatibleProviderClient(transport: transport)
            .testConnection(for: try snapshot(apiKey: "secret"))

        XCTAssertEqual(report.models, ["asr-a", "llm-b"])
        XCTAssertEqual(
            transport.lastRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret"
        )
        XCTAssertEqual(transport.lastRequest?.timeoutInterval, 15)
        XCTAssertEqual(transport.lastRequest?.url?.absoluteString, "https://api.example.com/v1/models")
    }

    func testNoAuthOmitsAuthorizationHeader() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 200, body: #"{"data":[]}"#))
        )

        _ = try await OpenAICompatibleProviderClient(transport: transport)
            .testConnection(for: try snapshot())

        XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAuthenticationApplicatorClearsBothHeadersBeforeApplyingSnapshotChoice() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://provider.test/v1/models")))
        request.setValue("Bearer stale", forHTTPHeaderField: "Authorization")
        request.setValue("stale-key", forHTTPHeaderField: "X-API-KEY")

        ProviderRequestAuthentication.apply(
            snapshot: try .validated(profile: makeProfile(), apiKey: nil),
            to: &request
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-KEY"))
    }

    func testModelDiscoveryUsesOnlySnapshotSelectedHKTHeader() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 200, body: #"{"data":[{"id":"hkt-asr"},{"id":"hkt-llm"}]}"#))
        )
        let snapshot = try OpenAICompatibleProviderSnapshot.validated(
            profile: .hktValidated(
                groupID: "12345",
                asrModel: "hkt-asr",
                llmModel: "hkt-llm",
                language: "yue",
                prompt: "prompt"
            ),
            apiKey: "hkt-secret"
        )

        let report = try await OpenAICompatibleProviderClient(transport: transport)
            .testConnection(for: snapshot)

        XCTAssertEqual(report.models, ["hkt-asr", "hkt-llm"])
        XCTAssertEqual(
            transport.lastRequest?.url?.absoluteString,
            "https://api.uat.bot-builder.pccw.com/v1/groups/12345/openai/models"
        )
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "X-API-KEY"), "hkt-secret")
        XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testMalformedHKTProfileCannotProduceSnapshotOrReachTransport() throws {
        let malformed = try JSONDecoder().decode(
            OpenAICompatibleProviderProfile.self,
            from: Data(#"{"schemaVersion":1,"providerKind":"hktGenAI","baseURL":"https://evil.example/v1","groupID":"42","asrModel":"asr","llmModel":"llm","language":"yue","prompt":""}"#.utf8)
        )
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 200, body: #"{"data":[]}"#))
        )

        XCTAssertThrowsError(
            try OpenAICompatibleProviderSnapshot.validated(
                profile: malformed,
                apiKey: "hkt-secret"
            )
        ) { error in
            XCTAssertEqual(error as? ProviderProfileValidationError, .invalidProviderConfiguration)
            XCTAssertFalse(error.localizedDescription.contains("hkt-secret"))
        }
        XCTAssertNil(transport.lastRequest)
    }

    func testUnsupportedModelDiscoveryStillReportsReachable() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 404, body: ""))
        )

        let report = try await OpenAICompatibleProviderClient(transport: transport)
            .testConnection(for: try snapshot())

        XCTAssertFalse(report.supportsModelDiscovery)
        XCTAssertTrue(report.models.isEmpty)
    }

    func testAuthenticationFailureIsTypedAndRedacted() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 401, body: "response-secret"))
        )

        do {
            _ = try await OpenAICompatibleProviderClient(transport: transport)
                .testConnection(for: try snapshot(apiKey: "never-log"))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? ProviderConnectionError, .authenticationRejected)
            XCTAssertFalse(error.localizedDescription.contains("never-log"))
            XCTAssertFalse(error.localizedDescription.contains("response-secret"))
        }
    }

    func testTransportReceivesResponseCapBeforeAnyStatusHandling() async throws {
        let transport = RecordingProviderTransport(
            response: .failure(
                ProviderHTTPTransportError.responseTooLarge
            )
        )

        do {
            _ = try await OpenAICompatibleProviderClient(transport: transport)
                .testConnection(for: try snapshot())
            XCTFail("Expected capped transport failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderHTTPTransportError,
                .responseTooLarge
            )
        }
        XCTAssertEqual(
            transport.lastMaximumBodyBytes,
            OpenAICompatibleProviderClient.maximumModelDiscoveryResponseBytes
        )
    }

    func testExcessiveModelDiscoveryItemsAreRejectedBeforeRender() async throws {
        let itemCount = OpenAICompatibleProviderClient
            .maximumDiscoveredModelCount + 1
        let body = #"{"data":["#
            + Array(repeating: #"{"id":"any/provider:model"}"#, count: itemCount)
                .joined(separator: ",")
            + "]}"
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 200, body: body))
        )

        do {
            _ = try await OpenAICompatibleProviderClient(transport: transport)
                .testConnection(for: try snapshot())
            XCTFail("Expected excessive model item failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderConnectionError,
                .tooManyDiscoveredModels
            )
            XCTAssertFalse(error.localizedDescription.contains("any/provider:model"))
        }
    }

    func testDeduplicatesExactModelIDsBeforeSorting() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(
                status: 200,
                body: #"{"data":[{"id":"z"},{"id":"a"},{"id":"z"},{"id":"A"}]}"#
            ))
        )

        let report = try await OpenAICompatibleProviderClient(transport: transport)
            .testConnection(for: try snapshot())

        XCTAssertEqual(report.models, ["A", "a", "z"])
    }

    private func makeProfile() throws -> OpenAICompatibleProviderProfile {
        try OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: "asr",
            llmModel: "llm",
            language: "yue",
            prompt: ""
        )
    }

    private func snapshot(
        apiKey: String? = nil
    ) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(profile: try makeProfile(), apiKey: apiKey)
    }

    private func controlledSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [ControlledURLProtocol.self]
        return configuration
    }

    private func assertTransportError(
        _ transport: URLSessionProviderHTTPTransport,
        maximumBodyBytes: Int,
        equals expected: ProviderHTTPTransportError,
        request: URLRequest = URLRequest(url: URL(string: "https://provider.test/models")!)
    ) async {
        do {
            _ = try await transport.response(
                for: request,
                maximumBodyBytes: maximumBodyBytes
            )
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderHTTPTransportError,
                expected
            )
        }
        XCTAssertTrue(transport.hasReleasedTaskAndSessionForTesting)
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

private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((ControlledURLProtocol) -> Void)?
    private static var latest: ControlledURLProtocol?
    private static var started = false
    private static var stopped = 0
    private static var request: URLRequest?
    private static var requestHistory: [URLRequest] = []
    private static var generation = 0
    private var finished = false
    private var instanceGeneration = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "provider.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            instanceGeneration = Self.generation
            Self.request = request
            Self.requestHistory.append(request)
            Self.latest = self
        }
        Self.handler?(self)
    }

    override func stopLoading() {
        Self.lock.withLock {
            if instanceGeneration == Self.generation { Self.stopped += 1 }
        }
    }

    func respond(
        status: Int,
        headers: [String: String] = [:],
        body: Data?
    ) {
        respond(status: status, headers: headers, bodyChunks: body.map { [$0] })
    }

    func redirect(status: Int, to url: URL) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Location": url.absoluteString])!
        var proposed = URLRequest(url: url)
        proposed.httpMethod = request.httpMethod
        proposed.httpBody = request.httpBody
        proposed.allHTTPHeaderFields = request.allHTTPHeaderFields
        client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
    }

    func respond(
        status: Int,
        headers: [String: String] = [:],
        bodyChunks: [Data]?
    ) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        bodyChunks?.forEach { client?.urlProtocol(self, didLoad: $0) }
        if bodyChunks != nil { Self.finishLatestResponse() }
    }

    func send(_ data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    func finishResponse() {
        finish()
    }

    static func install(_ handler: @escaping (ControlledURLProtocol) -> Void) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            latest = nil
            started = false
            stopped = 0
            request = nil
            requestHistory = []
            generation += 1
        }
    }

    static var lastRequest: URLRequest? { lock.withLock { request } }
    static var requests: [URLRequest] { lock.withLock { requestHistory } }
    static var stopLoadingCount: Int { lock.withLock { stopped } }

    static func markRequestStarted() {
        lock.withLock { started = true }
    }

    static func waitForRequestStart() async {
        while !lock.withLock({ started }) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    static func waitForStopLoadingCount(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if lock.withLock({ stopped >= expected }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return lock.withLock { stopped >= expected }
    }

    static func finishLatestResponse() {
        let instance = lock.withLock { latest }
        instance?.finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class RecordingProviderTransport: ProviderHTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: String
    }

    let response: Result<Response, Error>
    private(set) var lastRequest: URLRequest?
    private(set) var lastMaximumBodyBytes: Int?

    init(response: Result<Response, Error>) {
        self.response = response
    }

    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        lastMaximumBodyBytes = maximumBodyBytes
        let response = try response.get()
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}
