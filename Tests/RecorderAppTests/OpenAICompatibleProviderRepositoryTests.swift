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

    func testSnapshotsUseSeparateCredentialIdentitiesAndRemainImmutableAfterSwitch() throws {
        let store = OpenAICompatibleProviderProfileStore(defaults: makeDefaults())
        let secure = KeyedSecureValueStore()
        let repository = OpenAICompatibleProviderRepository(profiles: store, secureStore: secure)
        let generic = try makeProfile()
        let hkt = try OpenAICompatibleProviderProfile.hktValidated(groupID: "42", asrModel: "hkt-asr", llmModel: "hkt-llm", language: "en", prompt: "")

        try repository.save(profile: generic, replacementAPIKey: "generic-key")
        let captured = try repository.snapshot()
        try repository.save(profile: hkt, replacementAPIKey: "hkt-key")

        XCTAssertEqual(captured.providerKind, .openAICompatible)
        XCTAssertEqual(captured.authentication, .bearer)
        XCTAssertEqual(captured.apiKey, "generic-key")
        XCTAssertEqual(captured.profile.baseURL.absoluteString, generic.baseURL.absoluteString)
        XCTAssertEqual(captured.profile.asrModel, generic.asrModel)
        XCTAssertEqual(captured.profile.llmModel, generic.llmModel)
        XCTAssertEqual(try repository.snapshot().authentication, .hktAPIKey)
        XCTAssertEqual(secure.value(for: .openAICompatible), Data("generic-key".utf8))
        XCTAssertEqual(secure.value(for: .hktGenAI), Data("hkt-key".utf8))
    }

    func testInvalidTamperedProfileIsRejectedBeforeKeychainRead() throws {
        let profile = try JSONDecoder().decode(
            OpenAICompatibleProviderProfile.self,
            from: Data(#"{"schemaVersion":1,"providerKind":"hktGenAI","baseURL":"https://evil.example/v1","groupID":"42","asrModel":"asr","llmModel":"llm","language":"yue","prompt":""}"#.utf8)
        )
        let secure = KeyedSecureValueStore()
        let repository = makeRepository(profileStore: InMemoryProfileStore(profile: profile), secureStore: secure)
        XCTAssertThrowsError(try repository.snapshot()) {
            XCTAssertEqual($0 as? ProviderProfileValidationError, .invalidProviderConfiguration)
        }
        XCTAssertTrue(secure.operations.isEmpty)
    }

    func testRemovingActiveHKTKeyDoesNotDeleteGenericKey() throws {
        let store = OpenAICompatibleProviderProfileStore(defaults: makeDefaults())
        let secure = KeyedSecureValueStore()
        let repository = OpenAICompatibleProviderRepository(profiles: store, secureStore: secure)
        try repository.save(profile: makeProfile(), replacementAPIKey: "generic-key")
        try repository.save(profile: .hktValidated(groupID: "42", asrModel: "asr", llmModel: "llm", language: "yue", prompt: ""), replacementAPIKey: "hkt-key")

        try repository.removeAPIKey()

        XCTAssertEqual(secure.value(for: .openAICompatible), Data("generic-key".utf8))
        XCTAssertNil(secure.value(for: .hktGenAI))
        XCTAssertEqual(secure.operations.last, .delete(service: OpenAICompatibleProviderCredential.hktService, account: OpenAICompatibleProviderCredential.hktAccount))
    }

    func testSnapshotDerivesHKTAuthenticationFromProfileWithoutOverrides() throws {
        let profile = try OpenAICompatibleProviderProfile.hktValidated(groupID: "42", asrModel: "asr", llmModel: "llm", language: "yue", prompt: "")
        let snapshot = OpenAICompatibleProviderSnapshot(profile: profile, apiKey: "hkt-key")
        XCTAssertEqual(snapshot.providerKind, .hktGenAI)
        XCTAssertEqual(snapshot.authentication, .hktAPIKey)
    }

    func testSnapshotDerivesGenericAuthenticationFromProfileWithoutOverrides() throws {
        let snapshot = OpenAICompatibleProviderSnapshot(profile: try makeProfile(), apiKey: "generic-key")
        XCTAssertEqual(snapshot.providerKind, .openAICompatible)
        XCTAssertEqual(snapshot.authentication, .bearer)
    }

    func testReplacementHKTKeyIsDeletedWhenProfileSaveFailsWithoutPriorHKTKey() throws {
        let secure = KeyedSecureValueStore()
        secure.seed("generic-key", for: .openAICompatible)
        let repository = OpenAICompatibleProviderRepository(profiles: InMemoryProfileStore(saveError: TestError.failed), secureStore: secure)
        XCTAssertThrowsError(try repository.save(profile: .hktValidated(groupID: "42", asrModel: "asr", llmModel: "llm", language: "yue", prompt: ""), replacementAPIKey: "replacement"))
        XCTAssertNil(secure.value(for: .hktGenAI))
        XCTAssertEqual(secure.value(for: .openAICompatible), Data("generic-key".utf8))
    }

    func testReplacementHKTKeyRestoresPriorHKTKeyWhenProfileSaveFails() throws {
        let secure = KeyedSecureValueStore()
        secure.seed("old-hkt-key", for: .hktGenAI)
        secure.seed("generic-key", for: .openAICompatible)
        let repository = OpenAICompatibleProviderRepository(profiles: InMemoryProfileStore(saveError: TestError.failed), secureStore: secure)
        XCTAssertThrowsError(try repository.save(profile: .hktValidated(groupID: "42", asrModel: "asr", llmModel: "llm", language: "yue", prompt: ""), replacementAPIKey: "replacement"))
        XCTAssertEqual(secure.value(for: .hktGenAI), Data("old-hkt-key".utf8))
        XCTAssertEqual(secure.value(for: .openAICompatible), Data("generic-key".utf8))
    }

    func testRemoveUsesActiveHKTKindEvenWhenItHasNoProfile() throws {
        let store = OpenAICompatibleProviderProfileStore(defaults: makeDefaults())
        try store.save(makeProfile())
        try store.setActiveProviderKind(.hktGenAI)
        let secure = KeyedSecureValueStore()
        secure.seed("generic-key", for: .openAICompatible)
        let repository = OpenAICompatibleProviderRepository(profiles: store, secureStore: secure)

        try repository.removeAPIKey()

        XCTAssertEqual(secure.value(for: .openAICompatible), Data("generic-key".utf8))
        XCTAssertNil(secure.value(for: .hktGenAI))
    }

    func testCredentialRollbackFailureIsTypedAndRedacted() throws {
        let secure = KeyedSecureValueStore(failDeletes: true)
        let repository = OpenAICompatibleProviderRepository(profiles: InMemoryProfileStore(saveError: TestError.failed), secureStore: secure)
        XCTAssertThrowsError(try repository.save(profile: .hktValidated(groupID: "42", asrModel: "asr", llmModel: "llm", language: "yue", prompt: ""), replacementAPIKey: "replacement")) {
            XCTAssertEqual($0 as? ProviderRepositoryError, .credentialRollbackFailed)
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "Provider credential update could not be rolled back.")
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
        secureStore: any SecureValueStoring = InMemorySecureValueStore()
    ) -> OpenAICompatibleProviderRepository {
        OpenAICompatibleProviderRepository(
            profiles: profileStore,
            secureStore: secureStore
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "OpenAICompatibleProviderRepositoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
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

private final class KeyedSecureValueStore: SecureValueStoring, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private(set) var operations: [InMemorySecureValueStore.Operation] = []
    private let failDeletes: Bool
    init(failDeletes: Bool = false) { self.failDeletes = failDeletes }
    func load(service: String, account: String) throws -> Data? {
        operations.append(.load(service: service, account: account))
        return values[service + "|" + account]
    }
    func save(_ data: Data, service: String, account: String) throws {
        operations.append(.save(service: service, account: account))
        values[service + "|" + account] = data
    }
    func delete(service: String, account: String) throws {
        operations.append(.delete(service: service, account: account))
        if failDeletes { throw TestError.failed }
        values.removeValue(forKey: service + "|" + account)
    }
    func value(for kind: AIProviderKind) -> Data? {
        let identity = OpenAICompatibleProviderCredential.identity(for: kind)
        return values[identity.service + "|" + identity.account]
    }
    func seed(_ value: String, for kind: AIProviderKind) {
        let identity = OpenAICompatibleProviderCredential.identity(for: kind)
        values[identity.service + "|" + identity.account] = Data(value.utf8)
    }
}
