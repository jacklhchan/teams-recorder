import XCTest
@testable import RecorderApp

final class OpenAICompatibleProviderProfileTests: XCTestCase {
    func testNormalizesRootURLToV1() throws {
        let profile = try makeProfile(baseURL: "https://api.example.com/")

        XCTAssertEqual(profile.baseURL.absoluteString, "https://api.example.com/v1")
    }

    func testPreservesCustomPrefixAndAddsOneV1Suffix() throws {
        let profile = try makeProfile(baseURL: "https://host.example/openai/")

        XCTAssertEqual(profile.baseURL.absoluteString, "https://host.example/openai/v1")
    }

    func testAllowsLoopbackHTTP() throws {
        XCTAssertNoThrow(try makeProfile(baseURL: "http://127.0.0.1:8000/v1"))
        XCTAssertNoThrow(try makeProfile(baseURL: "http://[::1]:8765/v1"))
    }

    func testRejectsRemoteHTTPAndCredentialBearingURL() {
        XCTAssertThrowsError(try makeProfile(baseURL: "http://api.example.com/v1"))
        XCTAssertThrowsError(try makeProfile(baseURL: "https://user:pass@example.com/v1"))
    }

    func testRejectsQueryFragmentAndBlankModels() {
        XCTAssertThrowsError(
            try makeProfile(baseURL: "https://api.example.com/v1?key=value")
        )
        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example.com/v1",
                asrModel: " ",
                llmModel: "chat-model",
                language: "yue",
                prompt: ""
            )
        )
    }

    func testPreservesArbitraryModelIdentifiers() throws {
        let profile = try OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: "vendor/custom-asr:2026-07",
            llmModel: "local/my-meeting-llm",
            language: " yue ",
            prompt: " Hong Kong meeting "
        )

        XCTAssertEqual(profile.asrModel, "vendor/custom-asr:2026-07")
        XCTAssertEqual(profile.llmModel, "local/my-meeting-llm")
        XCTAssertEqual(profile.language, "yue")
        XCTAssertEqual(profile.prompt, "Hong Kong meeting")
    }

    private func makeProfile(
        baseURL: String = "https://api.example.com/v1"
    ) throws -> OpenAICompatibleProviderProfile {
        try OpenAICompatibleProviderProfile.validated(
            baseURLText: baseURL,
            asrModel: "asr-model",
            llmModel: "llm-model",
            language: "yue",
            prompt: ""
        )
    }
}
