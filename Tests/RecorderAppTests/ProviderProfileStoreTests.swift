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

    private func storedProfileData(baseURL: String) -> Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "baseURL": "\(baseURL)",
              "asrModel": "asr",
              "llmModel": "llm",
              "language": "yue",
              "prompt": ""
            }
            """.utf8
        )
    }
}
