import XCTest
@testable import RecorderApp

@MainActor
final class AIProviderSettingsModelTests: XCTestCase {
    func testBlankKeyOnSavePreservesStoredKey() throws {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr"
        model.llmModel = "llm"
        model.apiKeyReplacement = ""

        model.save()

        XCTAssertNil(repository.lastReplacementAPIKey)
        XCTAssertTrue(model.hasStoredAPIKey)
    }

    func testRemoveKeyIsExplicit() {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )

        model.removeAPIKey()

        XCTAssertEqual(repository.removeKeyCount, 1)
        XCTAssertFalse(model.hasStoredAPIKey)
    }

    func testConnectionFailureDoesNotDeleteManualModelValues() async {
        let model = makeModel(client: StubProviderClient(error: TestError.failed))
        model.asrModel = "manual-asr"
        model.llmModel = "manual-llm"

        await model.testConnection()

        XCTAssertEqual(model.asrModel, "manual-asr")
        XCTAssertEqual(model.llmModel, "manual-llm")
    }

    func testStartupMigrationFailureIsRedactedAndLeavesManualSetupUsable() {
        let repository = RecordingProviderRepository(
            migrationError: NSError(domain: "legacy-secret", code: 1)
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient(),
            loadImmediately: false
        )

        model.performStartupMigration(
            settingsURL: URL(fileURLWithPath: "/tmp/settings.json")
        )

        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(
            model.status,
            "Legacy provider settings could not be migrated. "
                + "Configure the AI provider manually."
        )
        XCTAssertFalse(model.status.contains("legacy-secret"))
    }

    private func makeModel(
        client: any ProviderConnectionTesting = StubProviderClient()
    ) -> AIProviderSettingsModel {
        let repository = RecordingProviderRepository(hasAPIKey: true)
        let model = AIProviderSettingsModel(repository: repository, client: client)
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr"
        model.llmModel = "llm"
        return model
    }
}

final class RecordingProviderRepository: OpenAICompatibleProviderManaging {
    private var profile: OpenAICompatibleProviderProfile?
    private var keyPresent: Bool
    private let migrationError: Error?
    private(set) var lastReplacementAPIKey: String?
    private(set) var removeKeyCount = 0

    init(
        profile: OpenAICompatibleProviderProfile? = nil,
        hasAPIKey: Bool = false,
        migrationError: Error? = nil
    ) {
        self.profile = profile
        keyPresent = hasAPIKey
        self.migrationError = migrationError
    }

    func loadProfile() throws -> OpenAICompatibleProviderProfile? { profile }

    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey: String?) throws {
        self.profile = profile
        lastReplacementAPIKey = replacementAPIKey
        if replacementAPIKey != nil { keyPresent = true }
    }

    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        guard let profile else { throw TestError.failed }
        return .init(profile: profile, apiKey: keyPresent ? "saved" : nil)
    }

    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot {
        .init(profile: profile, apiKey: keyPresent ? "saved" : nil)
    }

    func hasAPIKey() throws -> Bool { keyPresent }

    func removeAPIKey() throws {
        removeKeyCount += 1
        keyPresent = false
    }

    func migrateLegacyIfNeeded(settingsURL: URL) throws -> LegacyProviderMigrationOutcome {
        if let migrationError { throw migrationError }
        return .notFound
    }
}

private struct StubProviderClient: ProviderConnectionTesting {
    let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport {
        if let error { throw error }
        return .init(supportsModelDiscovery: true, models: [])
    }
}

private enum TestError: Error { case failed }
