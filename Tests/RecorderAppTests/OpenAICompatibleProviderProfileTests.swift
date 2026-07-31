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

    func testGenericAcceptsOnlyExactSupportedLanguageCodesAfterOuterWhitespaceTrim() throws {
        for language in [" yue ", "\ten\n", " zh "] {
            let profile = try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example.com/v1",
                asrModel: "asr",
                llmModel: "llm",
                language: language,
                prompt: ""
            )
            XCTAssertTrue(["yue", "en", "zh"].contains(profile.language))
        }

        for language in ["", " \n ", "fr", "English", "zh-HK", "YUE", "en\u{0000}", "粵語"] {
            XCTAssertThrowsError(
                try OpenAICompatibleProviderProfile.validated(
                    baseURLText: "https://api.example.com/v1",
                    asrModel: "asr",
                    llmModel: "llm",
                    language: language,
                    prompt: ""
                )
            ) {
                XCTAssertEqual($0 as? ProviderProfileValidationError, .invalidLanguage)
            }
        }
    }

    func testHKTBuildsExactFixedUATURLAtBothGroupIDBoundaries() throws {
        for groupID in ["1", String(repeating: "8", count: 32)] {
            let profile = try OpenAICompatibleProviderProfile.hktValidated(
                groupID: groupID, asrModel: "asr", llmModel: "llm", language: "yue", prompt: ""
            )
            XCTAssertEqual(profile.providerKind, .hktGenAI)
            XCTAssertEqual(profile.baseURL.absoluteString, "https://api.uat.bot-builder.pccw.com/v1/groups/\(groupID)/openai")
            XCTAssertEqual(profile.groupID, groupID)
        }
    }

    func testHKTRejectsAnythingOtherThanOneTo32ASCIIDigits() {
        for groupID in ["", String(repeating: "1", count: 33), " 1", "+1", "１２", "١٢", "https://example.test"] {
            XCTAssertThrowsError(try OpenAICompatibleProviderProfile.hktValidated(groupID: groupID, asrModel: "asr", llmModel: "llm", language: "yue", prompt: "")) {
                XCTAssertEqual($0 as? ProviderProfileValidationError, .invalidHKTGroupID)
            }
        }
    }

    func testHKTAcceptsOnlyExactSupportedLanguageCodesAfterOuterWhitespaceTrim() throws {
        for language in [" yue ", "\ten\n", " zh "] {
            let profile = try OpenAICompatibleProviderProfile.hktValidated(
                groupID: "42", asrModel: "asr", llmModel: "llm", language: language, prompt: ""
            )
            XCTAssertTrue(["yue", "en", "zh"].contains(profile.language))
        }

        for language in ["", "fr", "English", "zh-HK", "En", "en\u{0001}", "中文"] {
            XCTAssertThrowsError(
                try OpenAICompatibleProviderProfile.hktValidated(
                    groupID: "42", asrModel: "asr", llmModel: "llm", language: language, prompt: ""
                )
            ) {
                XCTAssertEqual($0 as? ProviderProfileValidationError, .invalidLanguage)
            }
        }
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
