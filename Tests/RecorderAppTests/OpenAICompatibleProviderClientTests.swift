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
            equals: .modelDiscoveryResponseTooLarge
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
            equals: .modelDiscoveryResponseTooLarge
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
            equals: .modelDiscoveryResponseTooLarge
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
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(ControlledURLProtocol.stopLoadingCount, 1)
        XCTAssertTrue(transport.hasReleasedTaskAndSessionForTesting)
    }

    func testListsModelsWithOptionalBearerHeader() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(
                status: 200,
                body: #"{"data":[{"id":"asr-a"},{"id":"llm-b"}]}"#
            ))
        )

        let report = try await OpenAICompatibleProviderClient(transport: transport)
            .testConnection(profile: try makeProfile(), apiKey: "secret")

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
            .testConnection(profile: try makeProfile(), apiKey: nil)

        XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnsupportedModelDiscoveryStillReportsReachable() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 404, body: ""))
        )

        let report = try await OpenAICompatibleProviderClient(transport: transport)
            .testConnection(profile: try makeProfile(), apiKey: nil)

        XCTAssertFalse(report.supportsModelDiscovery)
        XCTAssertTrue(report.models.isEmpty)
    }

    func testAuthenticationFailureIsTypedAndRedacted() async throws {
        let transport = RecordingProviderTransport(
            response: .success(.init(status: 401, body: "response-secret"))
        )

        do {
            _ = try await OpenAICompatibleProviderClient(transport: transport)
                .testConnection(profile: try makeProfile(), apiKey: "never-log")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? ProviderConnectionError, .authenticationRejected)
            XCTAssertFalse(error.localizedDescription.contains("never-log"))
            XCTAssertFalse(error.localizedDescription.contains("response-secret"))
        }
    }

    func testTransportReceivesResponseCapBeforeAnyStatusHandling() async throws {
        let transport = RecordingProviderTransport(
            response: .failure(ProviderConnectionError.modelDiscoveryResponseTooLarge)
        )

        do {
            _ = try await OpenAICompatibleProviderClient(transport: transport)
                .testConnection(profile: try makeProfile(), apiKey: nil)
            XCTFail("Expected capped transport failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderConnectionError,
                .modelDiscoveryResponseTooLarge
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
                .testConnection(profile: try makeProfile(), apiKey: nil)
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
            .testConnection(profile: try makeProfile(), apiKey: nil)

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

    private func controlledSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [ControlledURLProtocol.self]
        return configuration
    }

    private func assertTransportError(
        _ transport: URLSessionProviderHTTPTransport,
        maximumBodyBytes: Int,
        equals expected: ProviderConnectionError
    ) async {
        do {
            _ = try await transport.response(
                for: URLRequest(url: URL(string: "https://provider.test/models")!),
                maximumBodyBytes: maximumBodyBytes
            )
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual(error as? ProviderConnectionError, expected)
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
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "provider.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.request = request
            Self.latest = self
        }
        Self.handler?(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stopped += 1 }
    }

    func respond(
        status: Int,
        headers: [String: String] = [:],
        body: Data?
    ) {
        respond(status: status, headers: headers, bodyChunks: body.map { [$0] })
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
        }
    }

    static var lastRequest: URLRequest? { lock.withLock { request } }
    static var stopLoadingCount: Int { lock.withLock { stopped } }

    static func markRequestStarted() {
        lock.withLock { started = true }
    }

    static func waitForRequestStart() async {
        while !lock.withLock({ started }) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
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
