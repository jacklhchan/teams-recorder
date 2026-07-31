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
        let generic = try makeProfile()
        let hkt = try OpenAICompatibleProviderProfile.hktValidated(groupID: "42", asrModel: "hkt-asr", llmModel: "hkt-llm", language: "en", prompt: "hkt")

        try store.save(generic)
        try store.save(hkt, makingActive: false)
        try store.setActiveProviderKind(.hktGenAI)

        XCTAssertEqual(try store.activeProviderKind(), .hktGenAI)
        XCTAssertEqual(try store.load(), hkt)
        XCTAssertEqual(try store.loadProfile(for: .openAICompatible), generic)
        XCTAssertEqual(try store.loadProfile(for: .hktGenAI), hkt)
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

    private func storedProfileData(baseURL: String, language: String = "yue") -> Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "baseURL": "\(baseURL)",
              "asrModel": "asr",
              "llmModel": "llm",
              "language": "\(language)",
              "prompt": ""
            }
            """.utf8
        )
    }
}
