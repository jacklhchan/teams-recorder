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

    func testMigrationInvalidProfileMutatesNoCredential() throws {
        let secure = InMemorySecureValueStore()
        let settingsURL = try writeLegacySettings(
            """
            {
              "server": {"host": "example.com", "port": 8000},
              "auth": {"api_key": "legacy-secret"}
            }
            """
        )

        XCTAssertThrowsError(
            try makeRepository(secureStore: secure)
                .migrateLegacyIfNeeded(settingsURL: settingsURL)
        ) {
            XCTAssertEqual($0 as? ProviderProfileValidationError, .insecureRemoteURL)
        }
        XCTAssertNil(secure.stored)
        XCTAssertTrue(secure.operations.isEmpty)
    }

    func testMigrationReadBackMismatchDeletesNewKey() throws {
        let secure = InMemorySecureValueStore(readResults: [nil, Data("wrong-key".utf8)])
        let repository = makeRepository(secureStore: secure)

        XCTAssertThrowsError(
            try repository.migrateLegacyIfNeeded(
                settingsURL: try writeValidLegacySettings()
            )
        ) {
            XCTAssertEqual($0 as? ProviderRepositoryError, .migrationVerificationFailed)
        }
        XCTAssertNil(secure.stored)
        XCTAssertEqual(
            secure.operations,
            [
                .load(service: OpenAICompatibleProviderCredential.service,
                      account: OpenAICompatibleProviderCredential.account),
                .save(service: OpenAICompatibleProviderCredential.service,
                      account: OpenAICompatibleProviderCredential.account),
                .load(service: OpenAICompatibleProviderCredential.service,
                      account: OpenAICompatibleProviderCredential.account),
                .delete(service: OpenAICompatibleProviderCredential.service,
                        account: OpenAICompatibleProviderCredential.account)
            ]
        )
    }

    func testMigrationProfileSaveFailureRollsBackNewKey() throws {
        let profiles = InMemoryProfileStore(saveError: TestError.failed)
        let secure = InMemorySecureValueStore()
        let repository = makeRepository(profileStore: profiles, secureStore: secure)

        XCTAssertThrowsError(
            try repository.migrateLegacyIfNeeded(
                settingsURL: try writeValidLegacySettings()
            )
        )
        XCTAssertNil(secure.stored)
        XCTAssertEqual(secure.operations.last, .delete(
            service: OpenAICompatibleProviderCredential.service,
            account: OpenAICompatibleProviderCredential.account
        ))
    }

    func testMigrationRollbackFailureIsRedacted() throws {
        let profiles = InMemoryProfileStore(saveError: TestError.failed)
        let secure = InMemorySecureValueStore(deleteError: TestError.secretBearingFailure)
        let repository = makeRepository(profileStore: profiles, secureStore: secure)

        XCTAssertThrowsError(
            try repository.migrateLegacyIfNeeded(
                settingsURL: try writeValidLegacySettings()
            )
        ) {
            XCTAssertEqual($0 as? ProviderRepositoryError, .migrationRollbackFailed)
            XCTAssertEqual(
                ($0 as? LocalizedError)?.errorDescription,
                "Provider credential migration could not be rolled back."
            )
        }
        XCTAssertEqual(secure.stored, Data("legacy-secret".utf8))
    }

    func testMigrationProfileSaveFailurePreservesExistingMatchingKey() throws {
        let profiles = InMemoryProfileStore(saveError: TestError.failed)
        let secure = InMemorySecureValueStore(stored: Data("legacy-secret".utf8))
        let repository = makeRepository(profileStore: profiles, secureStore: secure)

        XCTAssertThrowsError(
            try repository.migrateLegacyIfNeeded(
                settingsURL: try writeValidLegacySettings()
            )
        )
        XCTAssertEqual(secure.stored, Data("legacy-secret".utf8))
        XCTAssertEqual(secure.operations.count, 1)
        XCTAssertEqual(secure.operations.first, .load(
            service: OpenAICompatibleProviderCredential.service,
            account: OpenAICompatibleProviderCredential.account
        ))
    }

    func testAlreadyConfiguredMigrationDoesNotReadLegacySettingsOrCredentials() throws {
        let profiles = InMemoryProfileStore(profile: try makeProfile())
        let secure = InMemorySecureValueStore()

        XCTAssertEqual(
            try makeRepository(profileStore: profiles, secureStore: secure)
                .migrateLegacyIfNeeded(
                    settingsURL: temporaryDirectoryURL.appendingPathComponent("missing.json")
                ),
            .alreadyConfigured
        )
        XCTAssertTrue(secure.operations.isEmpty)
    }

    func testMigrationSuccessVerifiesKeyWithExactCredentialIdentity() throws {
        let secure = InMemorySecureValueStore()
        let repository = makeRepository(secureStore: secure)

        XCTAssertEqual(
            try repository.migrateLegacyIfNeeded(settingsURL: try writeValidLegacySettings()),
            .migrated
        )
        XCTAssertEqual(secure.operations.count, 3)
        XCTAssertEqual(secure.operations.dropLast().last, .save(
            service: OpenAICompatibleProviderCredential.service,
            account: OpenAICompatibleProviderCredential.account
        ))
        XCTAssertEqual(secure.operations.last, .load(
            service: OpenAICompatibleProviderCredential.service,
            account: OpenAICompatibleProviderCredential.account
        ))
    }

    func testSnapshotRejectsInvalidAPIKeyEncoding() throws {
        let repository = makeRepository(
            profileStore: InMemoryProfileStore(profile: try makeProfile()),
            secureStore: InMemorySecureValueStore(stored: Data([0xFF]))
        )

        XCTAssertThrowsError(try repository.snapshot()) {
            XCTAssertEqual($0 as? ProviderRepositoryError, .invalidAPIKeyEncoding)
        }
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

    private func writeValidLegacySettings() throws -> URL {
        try writeLegacySettings(
            """
            {
              "server": {"host": "127.0.0.1", "port": 8000},
              "auth": {"api_key": "legacy-secret"}
            }
            """
        )
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
    private let saveError: Error?

    init(profile: OpenAICompatibleProviderProfile? = nil, saveError: Error? = nil) {
        self.profile = profile
        self.saveError = saveError
    }

    func load() throws -> OpenAICompatibleProviderProfile? {
        profile
    }

    func save(_ profile: OpenAICompatibleProviderProfile) throws {
        if let saveError { throw saveError }
        self.profile = profile
    }
}

private final class InMemorySecureValueStore: SecureValueStoring, @unchecked Sendable {
    enum Operation: Equatable {
        case load(service: String, account: String)
        case save(service: String, account: String)
        case delete(service: String, account: String)
    }

    var stored: Data?
    private var scriptedReadResults: [Data?]
    private(set) var operations: [Operation] = []
    private let deleteError: Error?

    init(
        stored: Data? = nil,
        readResults: [Data?] = [],
        deleteError: Error? = nil
    ) {
        self.stored = stored
        scriptedReadResults = readResults
        self.deleteError = deleteError
    }

    func load(service: String, account: String) throws -> Data? {
        operations.append(.load(service: service, account: account))
        if !scriptedReadResults.isEmpty {
            return scriptedReadResults.removeFirst()
        }
        return stored
    }

    func save(_ data: Data, service: String, account: String) throws {
        operations.append(.save(service: service, account: account))
        stored = data
    }

    func delete(service: String, account: String) throws {
        operations.append(.delete(service: service, account: account))
        if let deleteError { throw deleteError }
        stored = nil
    }
}

private enum TestError: Error {
    case failed
    case secretBearingFailure
}
