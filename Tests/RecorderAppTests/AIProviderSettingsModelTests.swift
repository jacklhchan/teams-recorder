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

    func testBlockedOldConnectionCannotOverwriteStatusAfterSavingDifferentSettings() async {
        let client = DeferredProviderClient()
        let model = makeModel(client: client)
        let testTask = Task { await model.testConnection() }
        await client.waitForRequestCount(1)

        model.baseURLText = "https://new.example.com/v1"
        model.save()
        await client.completeNext(
            with: .success(.init(
                supportsModelDiscovery: true,
                models: ["old-model"]
            ))
        )
        await testTask.value

        XCTAssertEqual(model.status, "Provider settings saved")
        XCTAssertFalse(model.statusIsError)
        XCTAssertTrue(model.discoveredModels.isEmpty)
        XCTAssertFalse(model.isTesting)
    }

    func testDirectFormEditInvalidatesBlockedConnectionResult() async {
        let client = DeferredProviderClient()
        let model = makeModel(client: client)
        let testTask = Task { await model.testConnection() }
        await client.waitForRequestCount(1)

        model.asrModel = "edited-asr"
        await client.completeNext(
            with: .success(.init(
                supportsModelDiscovery: true,
                models: ["old-model"]
            ))
        )
        await testTask.value

        XCTAssertEqual(model.asrModel, "edited-asr")
        XCTAssertEqual(model.status, "Not configured")
        XCTAssertTrue(model.discoveredModels.isEmpty)
        XCTAssertFalse(model.isTesting)
    }

    func testReloadAndRemoveKeyInvalidateBlockedConnectionResult() async {
        let client = DeferredProviderClient()
        let repository = RecordingProviderRepository(
            profile: try! makeProfile(),
            hasAPIKey: true
        )
        let model = AIProviderSettingsModel(repository: repository, client: client)
        let firstTest = Task { await model.testConnection() }
        await client.waitForRequestCount(1)

        model.reload()
        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["old"]))
        )
        await firstTest.value
        XCTAssertEqual(model.status, "Provider settings loaded")
        XCTAssertTrue(model.discoveredModels.isEmpty)

        let secondTest = Task { await model.testConnection() }
        await client.waitForRequestCount(2)
        model.removeAPIKey()
        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["old"]))
        )
        await secondTest.value
        XCTAssertEqual(model.status, "API key removed")
        XCTAssertTrue(model.discoveredModels.isEmpty)
    }

    func testOldConnectionCannotClearTestingStateForNewerConnection() async {
        let client = DeferredProviderClient()
        let model = makeModel(client: client)
        let oldTest = Task { await model.testConnection() }
        await client.waitForRequestCount(1)
        let newTest = Task { await model.testConnection() }
        await client.waitForRequestCount(2)

        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["old"]))
        )
        await oldTest.value

        XCTAssertTrue(model.isTesting)
        XCTAssertTrue(model.discoveredModels.isEmpty)

        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["new"]))
        )
        await newTest.value

        XCTAssertFalse(model.isTesting)
        XCTAssertEqual(model.discoveredModels, ["new"])
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

private actor DeferredProviderClient: ProviderConnectionTesting {
    private var continuations: [CheckedContinuation<ProviderConnectionReport, Error>] = []
    private var requestsStarted = 0

    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport {
        try await withCheckedThrowingContinuation { continuation in
            requestsStarted += 1
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while requestsStarted < count {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func completeNext(
        with result: Result<ProviderConnectionReport, Error>
    ) {
        continuations.removeFirst().resume(with: result)
    }
}

private enum TestError: Error { case failed }
