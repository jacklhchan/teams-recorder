import Foundation
import XCTest
@testable import RecorderApp

final class OpenAICompatibleProviderClientTests: XCTestCase {
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
