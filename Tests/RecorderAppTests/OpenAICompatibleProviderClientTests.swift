import Foundation
import XCTest
@testable import RecorderApp

final class OpenAICompatibleProviderClientTests: XCTestCase {
    func testListsModelsWithOptionalBearerHeader() async throws {
        let loader = RecordingProviderDataLoader(
            response: .success(.init(
                status: 200,
                body: #"{"data":[{"id":"asr-a"},{"id":"llm-b"}]}"#
            ))
        )

        let report = try await OpenAICompatibleProviderClient(loader: loader)
            .testConnection(profile: try makeProfile(), apiKey: "secret")

        XCTAssertEqual(report.models, ["asr-a", "llm-b"])
        XCTAssertEqual(
            loader.lastRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret"
        )
        XCTAssertEqual(loader.lastRequest?.timeoutInterval, 15)
        XCTAssertEqual(loader.lastRequest?.url?.absoluteString, "https://api.example.com/v1/models")
    }

    func testNoAuthOmitsAuthorizationHeader() async throws {
        let loader = RecordingProviderDataLoader(
            response: .success(.init(status: 200, body: #"{"data":[]}"#))
        )

        _ = try await OpenAICompatibleProviderClient(loader: loader)
            .testConnection(profile: try makeProfile(), apiKey: nil)

        XCTAssertNil(loader.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnsupportedModelDiscoveryStillReportsReachable() async throws {
        let loader = RecordingProviderDataLoader(
            response: .success(.init(status: 404, body: ""))
        )

        let report = try await OpenAICompatibleProviderClient(loader: loader)
            .testConnection(profile: try makeProfile(), apiKey: nil)

        XCTAssertFalse(report.supportsModelDiscovery)
        XCTAssertTrue(report.models.isEmpty)
    }

    func testAuthenticationFailureIsTypedAndRedacted() async throws {
        let loader = RecordingProviderDataLoader(
            response: .success(.init(status: 401, body: "response-secret"))
        )

        do {
            _ = try await OpenAICompatibleProviderClient(loader: loader)
                .testConnection(profile: try makeProfile(), apiKey: "never-log")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? ProviderConnectionError, .authenticationRejected)
            XCTAssertFalse(error.localizedDescription.contains("never-log"))
            XCTAssertFalse(error.localizedDescription.contains("response-secret"))
        }
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

private final class RecordingProviderDataLoader: ProviderHTTPDataLoading, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: String
    }

    let response: Result<Response, Error>
    private(set) var lastRequest: URLRequest?

    init(response: Result<Response, Error>) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
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
