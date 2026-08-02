import Foundation
import XCTest
@testable import RecorderApp

final class ProviderProfileStoreTests: XCTestCase {
    func testRoundTripsProfileAsJSONData() throws {
        let defaults = makeDefaults()
        let store = OpenAICompatibleProviderProfileStore(defaults: defaults)
        let profile = try makeProfile()

        try store.save(profile)

        XCTAssertEqual(try store.load(), profile)
        XCTAssertNil(defaults.string(forKey: OpenAICompatibleProviderProfileStore.key))
        XCTAssertNotNil(defaults.data(forKey: OpenAICompatibleProviderProfileStore.key))
    }

    func testLegacyV1DirectProfileMigratesAndRewritesAsV2Envelope() throws {
        let defaults = makeDefaults()
        defaults.set(
            storedProfileData(
                baseURL: "https://api.example.com/v1",
                prompt: "ASR guidance"
            ),
            forKey: OpenAICompatibleProviderProfileStore.key
        )

        let profile = try XCTUnwrap(
            OpenAICompatibleProviderProfileStore(defaults: defaults).load()
        )

        XCTAssertEqual(profile.schemaVersion, 2)
        XCTAssertEqual(profile.prompt, "ASR guidance")
        XCTAssertEqual(profile.meetingIntelligencePrompt, "")

        let savedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(defaults.data(forKey: OpenAICompatibleProviderProfileStore.key))
            ) as? [String: Any]
        )
        XCTAssertEqual(savedJSON["schemaVersion"] as? Int, 2)
        let genericJSON = try XCTUnwrap(savedJSON["genericProfile"] as? [String: Any])
        XCTAssertEqual(genericJSON["schemaVersion"] as? Int, 2)
        XCTAssertEqual(genericJSON["meetingIntelligencePrompt"] as? String, "")
    }

    func testCurrentEnvelopeMigratesV1ProfilesAndRewritesBothPresets() throws {
        let defaults = makeDefaults()
        defaults.set(
            Data(
                #"{"schemaVersion":2,"activeProviderKind":"hktGenAI","genericProfile":{"schemaVersion":1,"baseURL":"https://api.example.com/v1","asrModel":"generic-asr","llmModel":"generic-llm","language":"yue","prompt":"generic ASR"},"hktProfile":{"schemaVersion":1,"providerKind":"hktGenAI","baseURL":"https://api.uat.bot-builder.pccw.com/v1/groups/42/openai","groupID":"42","asrModel":"hkt-asr","llmModel":"hkt-llm","language":"en","prompt":"hkt ASR"}}"#.utf8
            ),
            forKey: OpenAICompatibleProviderProfileStore.key
        )

        let store = OpenAICompatibleProviderProfileStore(defaults: defaults)
        let generic = try XCTUnwrap(try store.loadProfile(for: .openAICompatible))
        let hkt = try XCTUnwrap(try store.loadProfile(for: .hktGenAI))

        XCTAssertEqual(generic.schemaVersion, 2)
        XCTAssertEqual(generic.prompt, "generic ASR")
        XCTAssertEqual(generic.meetingIntelligencePrompt, "")
        XCTAssertEqual(hkt.schemaVersion, 2)
        XCTAssertEqual(hkt.prompt, "hkt ASR")
        XCTAssertEqual(hkt.meetingIntelligencePrompt, "")

        let savedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(defaults.data(forKey: OpenAICompatibleProviderProfileStore.key))
            ) as? [String: Any]
        )
        XCTAssertEqual(savedJSON["schemaVersion"] as? Int, 2)
        for key in ["genericProfile", "hktProfile"] {
            let profileJSON = try XCTUnwrap(savedJSON[key] as? [String: Any])
            XCTAssertEqual(profileJSON["schemaVersion"] as? Int, 2)
            XCTAssertEqual(profileJSON["meetingIntelligencePrompt"] as? String, "")
        }
    }

    func testCurrentEnvelopeRejectsFutureNestedProfileSchemaV3() {
        let defaults = makeDefaults()
        defaults.set(
            Data(
                #"{"schemaVersion":2,"activeProviderKind":"openAICompatible","genericProfile":{"schemaVersion":3,"baseURL":"https://api.example.com/v1","asrModel":"asr","llmModel":"llm","language":"yue","prompt":"ASR guidance","meetingIntelligencePrompt":"future"},"hktProfile":null}"#.utf8
            ),
            forKey: OpenAICompatibleProviderProfileStore.key
        )

        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfileStore(defaults: defaults).load()
        ) {
            XCTAssertEqual(
                $0 as? ProviderProfileValidationError,
                .unsupportedSchemaVersion(3)
            )
        }
    }

    func testRejectsUnsupportedStoredSchema() throws {
        let defaults = makeDefaults()
        let data = Data(
            """
            {
              "schemaVersion": 99,
              "baseURL": "https://api.example.com/v1",
              "asrModel": "asr",
              "llmModel": "llm",
              "language": "yue",
              "prompt": ""
            }
            """.utf8
        )
        defaults.set(data, forKey: OpenAICompatibleProviderProfileStore.key)

        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfileStore(defaults: defaults).load()
        )
    }

    func testRejectsStoredRemoteHTTPBeforeCredentialUse() {
        let defaults = makeDefaults()
        defaults.set(
            storedProfileData(baseURL: "http://attacker.example/v1"),
            forKey: OpenAICompatibleProviderProfileStore.key
        )

        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfileStore(defaults: defaults).load()
        ) {
            XCTAssertEqual(
                $0 as? ProviderProfileValidationError,
                .insecureRemoteURL
            )
        }
    }

    func testSaveRevalidatesDecodedCredentialBearingURL() throws {
        let defaults = makeDefaults()
        let untrusted = try JSONDecoder().decode(
            OpenAICompatibleProviderProfile.self,
            from: storedProfileData(
                baseURL: "https://user:pass@api.example.com/v1"
            )
        )

        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfileStore(defaults: defaults).save(untrusted)
        )
        XCTAssertNil(defaults.data(forKey: OpenAICompatibleProviderProfileStore.key))
    }

    func testIndependentPresetsAndActiveKindRoundTripWithoutCopyingFields() throws {
        let store = OpenAICompatibleProviderProfileStore(defaults: makeDefaults())
        let generic = try OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: "asr",
            llmModel: "llm",
            language: "yue",
            prompt: "generic ASR",
            meetingIntelligencePrompt: "generic MI"
        )
        let hkt = try OpenAICompatibleProviderProfile.hktValidated(
            groupID: "42", asrModel: "hkt-asr", llmModel: "hkt-llm",
            language: "en", prompt: "hkt ASR",
            meetingIntelligencePrompt: "hkt MI"
        )

        try store.save(generic)
        try store.save(hkt, makingActive: false)
        try store.setActiveProviderKind(.hktGenAI)

        XCTAssertEqual(try store.activeProviderKind(), .hktGenAI)
        XCTAssertEqual(try store.load(), hkt)
        XCTAssertEqual(try store.loadProfile(for: .openAICompatible), generic)
        XCTAssertEqual(try store.loadProfile(for: .hktGenAI), hkt)
        XCTAssertEqual(try store.loadProfile(for: .openAICompatible)?.prompt, "generic ASR")
        XCTAssertEqual(try store.loadProfile(for: .openAICompatible)?.meetingIntelligencePrompt, "generic MI")
        XCTAssertEqual(try store.loadProfile(for: .hktGenAI)?.prompt, "hkt ASR")
        XCTAssertEqual(try store.loadProfile(for: .hktGenAI)?.meetingIntelligencePrompt, "hkt MI")
    }

    func testLegacyV1ProfileMigratesAsGenericAndFutureEnvelopeIsRejected() throws {
        let defaults = makeDefaults()
        defaults.set(storedProfileData(baseURL: "https://api.example.com/v1"), forKey: OpenAICompatibleProviderProfileStore.key)
        let store = OpenAICompatibleProviderProfileStore(defaults: defaults)
        XCTAssertEqual(try store.load()?.providerKind, .openAICompatible)
        XCTAssertEqual(try store.activeProviderKind(), .openAICompatible)

        defaults.set(Data(#"{"schemaVersion":99,"activeProviderKind":"hktGenAI","genericProfile":null,"hktProfile":null}"#.utf8), forKey: OpenAICompatibleProviderProfileStore.key)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ProviderProfileValidationError, .unsupportedSchemaVersion(99))
        }
    }

    func testTamperedHKTFixedEndpointIsRejected() throws {
        let defaults = makeDefaults()
        defaults.set(Data(#"{"schemaVersion":2,"activeProviderKind":"hktGenAI","genericProfile":null,"hktProfile":{"schemaVersion":1,"providerKind":"hktGenAI","baseURL":"https://attacker.example/v1","groupID":"42","asrModel":"asr","llmModel":"llm","language":"yue","prompt":""}}"#.utf8), forKey: OpenAICompatibleProviderProfileStore.key)
        XCTAssertThrowsError(try OpenAICompatibleProviderProfileStore(defaults: defaults).load()) {
            XCTAssertEqual($0 as? ProviderProfileValidationError, .invalidProviderConfiguration)
        }
    }

    func testTamperedEnvelopeAndLegacyProfileRejectUnsupportedLanguage() {
        let envelopeDefaults = makeDefaults()
        envelopeDefaults.set(Data(#"{"schemaVersion":2,"activeProviderKind":"openAICompatible","genericProfile":{"schemaVersion":1,"providerKind":"openAICompatible","baseURL":"https://api.example.com/v1","asrModel":"asr","llmModel":"llm","language":"zh-HK","prompt":""},"hktProfile":null}"#.utf8), forKey: OpenAICompatibleProviderProfileStore.key)

        XCTAssertThrowsError(try OpenAICompatibleProviderProfileStore(defaults: envelopeDefaults).load()) {
            XCTAssertEqual($0 as? ProviderProfileValidationError, .invalidLanguage)
        }

        let legacyDefaults = makeDefaults()
        legacyDefaults.set(storedProfileData(baseURL: "https://api.example.com/v1", language: ""), forKey: OpenAICompatibleProviderProfileStore.key)

        XCTAssertThrowsError(try OpenAICompatibleProviderProfileStore(defaults: legacyDefaults).load()) {
            XCTAssertEqual($0 as? ProviderProfileValidationError, .invalidLanguage)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ProviderProfileStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
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

    private func storedProfileData(
        baseURL: String,
        language: String = "yue",
        prompt: String = ""
    ) -> Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "baseURL": "\(baseURL)",
              "asrModel": "asr",
              "llmModel": "llm",
              "language": "\(language)",
              "prompt": "\(prompt)"
            }
            """.utf8
        )
    }
}
