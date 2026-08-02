import XCTest
@testable import RecorderApp

final class OpenAICompatibleProviderProfileTests: XCTestCase {
    func testSchemaV2MigratesV1ASRPromptAndRoundTripsMeetingIntelligencePrompt() throws {
        let v1Data = Data(
            #"{"schemaVersion":1,"baseURL":"https://api.example.com/v1","asrModel":"asr","llmModel":"llm","language":"yue","prompt":"ASR guidance"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(
            OpenAICompatibleProviderProfile.self,
            from: v1Data
        )
        let migrated = try OpenAICompatibleProviderProfile.validatedPersisted(decoded)

        XCTAssertEqual(OpenAICompatibleProviderProfile.currentSchemaVersion, 2)
        XCTAssertEqual(decoded.meetingIntelligencePrompt, "")
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.prompt, "ASR guidance")
        XCTAssertEqual(migrated.meetingIntelligencePrompt, "")

        let profile = try OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: "asr",
            llmModel: "llm",
            language: "yue",
            prompt: "ASR guidance",
            meetingIntelligencePrompt: " Summarize decisions "
        )
        let roundTripped = try JSONDecoder().decode(
            OpenAICompatibleProviderProfile.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(roundTripped.meetingIntelligencePrompt, "Summarize decisions")
    }

    func testMeetingIntelligencePromptNormalizesWhitespaceAndNFC() throws {
        let profile = try makeProfile(
            meetingIntelligencePrompt: "\n\tCafe\u{301}\n\t"
        )

        XCTAssertEqual(profile.meetingIntelligencePrompt, "Café")

        let multiline = try makeProfile(
            meetingIntelligencePrompt: "\n\tSummarize\tdecisions\nnext steps\t\n"
        )
        XCTAssertEqual(
            multiline.meetingIntelligencePrompt,
            "Summarize\tdecisions\nnext steps"
        )
    }

    func testMeetingIntelligencePromptAccepts8192UTF8BytesAndRejects8193() throws {
        let accepted = String(repeating: "é", count: 4_096)
        XCTAssertEqual(accepted.utf8.count, 8_192)
        XCTAssertNoThrow(try makeProfile(meetingIntelligencePrompt: accepted))

        let submitted = accepted + "a"
        XCTAssertEqual(submitted.utf8.count, 8_193)
        XCTAssertThrowsError(try makeProfile(meetingIntelligencePrompt: submitted)) {
            XCTAssertEqual(
                $0 as? ProviderProfileValidationError,
                .meetingIntelligencePromptTooLarge
            )
            XCTAssertFalse($0.localizedDescription.contains(submitted))
        }
    }

    func testMeetingIntelligencePromptRejectsC0C1AndFormatScalarsWithoutEchoingValue() {
        for submitted in [
            "contains\u{0001}control",
            "contains\u{0085}control",
            "contains\u{200B}format"
        ] {
            XCTAssertThrowsError(try makeProfile(meetingIntelligencePrompt: submitted)) {
                XCTAssertEqual(
                    $0 as? ProviderProfileValidationError,
                    .unsafeMeetingIntelligencePrompt
                )
                XCTAssertFalse($0.localizedDescription.contains(submitted))
            }
        }
    }

    func testRejectsFutureProfileSchemaV3() {
        let future = Data(
            #"{"schemaVersion":3,"baseURL":"https://api.example.com/v1","asrModel":"asr","llmModel":"llm","language":"yue","prompt":"ASR guidance","meetingIntelligencePrompt":"future"}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(OpenAICompatibleProviderProfile.self, from: future)
        ) {
            XCTAssertEqual(
                $0 as? ProviderProfileValidationError,
                .unsupportedSchemaVersion(3)
            )
            XCTAssertFalse($0.localizedDescription.contains("future"))
        }
    }

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
        baseURL: String = "https://api.example.com/v1",
        meetingIntelligencePrompt: String = ""
    ) throws -> OpenAICompatibleProviderProfile {
        try OpenAICompatibleProviderProfile.validated(
            baseURLText: baseURL,
            asrModel: "asr-model",
            llmModel: "llm-model",
            language: "yue",
            prompt: "",
            meetingIntelligencePrompt: meetingIntelligencePrompt
        )
    }
}
