import Foundation
import XCTest
@testable import RecorderApp

final class OpenAICompatibleProviderRepositoryTests: XCTestCase {
    func testSnapshotCombinesProfileAndOptionalKey() throws {
        let profileStore = InMemoryProfileStore(profile: try makeProfile())
        let secure = InMemorySecureValueStore(stored: Data("secret-key".utf8))
        let repository = makeRepository(
            profileStore: profileStore,
            secureStore: secure
        )

        XCTAssertEqual(
            try repository.snapshot(),
            OpenAICompatibleProviderSnapshot(
                profile: try XCTUnwrap(profileStore.profile),
                apiKey: "secret-key"
            )
        )
    }

    func testSavingProfileWithoutReplacementPreservesKey() throws {
        let secure = InMemorySecureValueStore(stored: Data("existing-key".utf8))
        let repository = makeRepository(secureStore: secure)

        try repository.save(
            profile: try makeProfile(),
            replacementAPIKey: nil
        )

        XCTAssertEqual(secure.stored, Data("existing-key".utf8))
    }

    func testExplicitRemoveDeletesKey() throws {
        let secure = InMemorySecureValueStore(stored: Data("existing-key".utf8))
        let repository = makeRepository(secureStore: secure)

        try repository.removeAPIKey()

        XCTAssertNil(secure.stored)
    }

    func testMigrationDoesNothingWithoutLegacyFile() throws {
        let repository = makeRepository()
        let missingURL = temporaryDirectoryURL
            .appendingPathComponent("missing-settings.json")

        XCTAssertEqual(
            try repository.migrateLegacyIfNeeded(settingsURL: missingURL),
            .notFound
        )
        XCTAssertNil(try repository.loadProfile())
    }

    func testMigrationUsesPriorModelOnlyAsLegacyDefault() throws {
        let settingsURL = try writeLegacySettings(
            """
            {
              "server": {"host": "127.0.0.1", "port": 8000},
              "auth": {"api_key": "legacy-secret"}
            }
            """
        )
        let repository = makeRepository()

        XCTAssertEqual(
            try repository.migrateLegacyIfNeeded(settingsURL: settingsURL),
            .migrated
        )
        let profile = try XCTUnwrap(repository.loadProfile())
        XCTAssertEqual(profile.asrModel, "mlx-community--Qwen3-ASR-1.7B-4bit")
        XCTAssertEqual(profile.language, "yue")
    }

    func testExistingDifferentKeyFailsWithoutMutation() throws {
        let secure = InMemorySecureValueStore(stored: Data("already-saved".utf8))
        let settingsURL = try writeLegacySettings(
            """
            {
              "server": {"host": "127.0.0.1", "port": 8000},
              "auth": {"api_key": "legacy-secret"}
            }
            """
        )
        let repository = makeRepository(secureStore: secure)

        XCTAssertThrowsError(
            try repository.migrateLegacyIfNeeded(settingsURL: settingsURL)
        ) {
            XCTAssertEqual($0 as? ProviderRepositoryError, .legacyCredentialMismatch)
        }
        XCTAssertNil(try repository.loadProfile())
        XCTAssertEqual(secure.stored, Data("already-saved".utf8))
    }

    private var temporaryDirectoryURL: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeLegacySettings(_ contents: String) throws -> URL {
        let file = temporaryDirectoryURL.appendingPathComponent("settings.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func makeRepository(
        profileStore: InMemoryProfileStore = .init(),
        secureStore: InMemorySecureValueStore = .init()
    ) -> OpenAICompatibleProviderRepository {
        OpenAICompatibleProviderRepository(
            profiles: profileStore,
            secureStore: secureStore
        )
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

private final class InMemoryProfileStore: ProviderProfileStoring, @unchecked Sendable {
    var profile: OpenAICompatibleProviderProfile?

    init(profile: OpenAICompatibleProviderProfile? = nil) {
        self.profile = profile
    }

    func load() throws -> OpenAICompatibleProviderProfile? {
        profile
    }

    func save(_ profile: OpenAICompatibleProviderProfile) throws {
        self.profile = profile
    }
}

private final class InMemorySecureValueStore: SecureValueStoring, @unchecked Sendable {
    var stored: Data?

    init(stored: Data? = nil) {
        self.stored = stored
    }

    func load(service: String, account: String) throws -> Data? {
        stored
    }

    func save(_ data: Data, service: String, account: String) throws {
        stored = data
    }

    func delete(service: String, account: String) throws {
        stored = nil
    }
}
