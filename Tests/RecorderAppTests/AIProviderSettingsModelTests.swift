import XCTest
@testable import RecorderApp

@MainActor
final class AIProviderSettingsModelTests: XCTestCase {
    func testStartupSelectsActivePresetAndRetainsIndependentDraftsWithoutSaving() throws {
        let generic = try makeProfile()
        let hkt = try OpenAICompatibleProviderProfile.hktValidated(
            groupID: "12345",
            asrModel: "hkt-asr",
            llmModel: "hkt-llm",
            language: "yue",
            prompt: "hkt prompt"
        )
        let repository = RecordingProviderRepository(
            profiles: [.openAICompatible: generic, .hktGenAI: hkt],
            activeKind: .hktGenAI,
            keys: [.openAICompatible: true, .hktGenAI: false]
        )
        let model = AIProviderSettingsModel(repository: repository, client: StubProviderClient())

        XCTAssertEqual(model.selectedProviderKind, .hktGenAI)
        XCTAssertEqual(model.groupIDText, "12345")
        XCTAssertEqual(model.asrModel, "hkt-asr")
        XCTAssertFalse(model.hasStoredAPIKey)

        model.asrModel = "unsaved-hkt-asr"
        model.selectedProviderKind = .openAICompatible
        XCTAssertEqual(model.asrModel, "asr")
        XCTAssertTrue(model.hasStoredAPIKey)
        model.selectedProviderKind = .hktGenAI

        XCTAssertEqual(model.asrModel, "unsaved-hkt-asr")
        XCTAssertEqual(repository.saveCount, 0)
        XCTAssertEqual(repository.activeKind, .hktGenAI)
    }

    func testPickerKeepsReplacementKeyWithItsUnsavedPresetDraft() throws {
        let generic = try makeProfile()
        let hkt = try OpenAICompatibleProviderProfile.hktValidated(
            groupID: "12345", asrModel: "hkt-asr", llmModel: "hkt-llm",
            language: "yue", prompt: ""
        )
        let repository = RecordingProviderRepository(
            profiles: [.openAICompatible: generic, .hktGenAI: hkt],
            activeKind: .openAICompatible,
            keys: [:]
        )
        let model = AIProviderSettingsModel(repository: repository, client: StubProviderClient())
        model.apiKeyReplacement = "generic-replacement"

        model.selectedProviderKind = .hktGenAI
        XCTAssertEqual(model.apiKeyReplacement, "")
        model.apiKeyReplacement = "hkt-replacement"
        model.selectedProviderKind = .openAICompatible

        XCTAssertEqual(model.apiKeyReplacement, "generic-replacement")
        model.selectedProviderKind = .hktGenAI
        XCTAssertEqual(model.apiKeyReplacement, "hkt-replacement")
        XCTAssertEqual(repository.saveCount, 0)
    }

    func testSaveHKTValidatesGroupIDAndDoesNotTouchGenericProfileOrKey() throws {
        let generic = try makeProfile()
        let repository = RecordingProviderRepository(
            profiles: [.openAICompatible: generic],
            activeKind: .openAICompatible,
            keys: [.openAICompatible: true, .hktGenAI: false]
        )
        let model = AIProviderSettingsModel(repository: repository, client: StubProviderClient())
        model.selectedProviderKind = .hktGenAI
        model.groupIDText = "not-a-number"

        model.save()

        XCTAssertEqual(repository.saveCount, 0)
        XCTAssertEqual(repository.profiles[.openAICompatible], generic)
        XCTAssertTrue(repository.keys[.openAICompatible] ?? false)
        XCTAssertTrue(model.statusIsError)

        model.groupIDText = "123456"
        model.apiKeyReplacement = "hkt-key"
        model.save()

        XCTAssertEqual(repository.saveCount, 1)
        XCTAssertEqual(repository.activeKind, .hktGenAI)
        XCTAssertEqual(repository.profiles[.openAICompatible], generic)
        XCTAssertTrue(repository.keys[.openAICompatible] ?? false)
        XCTAssertTrue(repository.keys[.hktGenAI] ?? false)
    }

    func testRemoveKeyOnlyRemovesSelectedPresetKey() throws {
        let generic = try makeProfile()
        let hkt = try OpenAICompatibleProviderProfile.hktValidated(
            groupID: "12345", asrModel: "hkt-asr", llmModel: "hkt-llm",
            language: "yue", prompt: ""
        )
        let repository = RecordingProviderRepository(
            profiles: [.openAICompatible: generic, .hktGenAI: hkt],
            activeKind: .openAICompatible,
            keys: [.openAICompatible: true, .hktGenAI: true]
        )
        let model = AIProviderSettingsModel(repository: repository, client: StubProviderClient())
        model.selectedProviderKind = .hktGenAI

        model.removeAPIKey()

        XCTAssertFalse(repository.keys[.hktGenAI] ?? true)
        XCTAssertTrue(repository.keys[.openAICompatible] ?? false)
        XCTAssertFalse(model.hasStoredAPIKey)
    }

    func testOldPresetConnectionResultCannotOverwriteAfterPickerSwitch() async throws {
        let generic = try makeProfile()
        let hkt = try OpenAICompatibleProviderProfile.hktValidated(
            groupID: "12345",
            asrModel: "hkt-asr",
            llmModel: "hkt-llm",
            language: "yue",
            prompt: ""
        )
        let repository = RecordingProviderRepository(
            profiles: [.openAICompatible: generic, .hktGenAI: hkt],
            activeKind: .openAICompatible,
            keys: [.openAICompatible: true, .hktGenAI: true]
        )
        let client = DeferredProviderClient()
        let model = AIProviderSettingsModel(repository: repository, client: client)
        let testTask = Task { await model.testConnection() }
        await client.waitForRequestCount(1)

        model.selectedProviderKind = .hktGenAI
        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["old-generic"]))
        )
        await testTask.value

        XCTAssertEqual(model.selectedProviderKind, .hktGenAI)
        XCTAssertEqual(model.status, "Provider settings loaded")
        XCTAssertTrue(model.discoveredModels.isEmpty)
    }

    func testConnectionUsesSelectedHKTDraftSnapshot() async throws {
        let repository = RecordingProviderRepository()
        let client = DeferredProviderClient()
        let model = AIProviderSettingsModel(repository: repository, client: client, loadImmediately: false)
        model.selectedProviderKind = .hktGenAI
        model.groupIDText = "9876"

        let testTask = Task { await model.testConnection() }
        await client.waitForRequestCount(1)
        let snapshot = await client.snapshot(at: 0)
        await client.completeNext(with: .success(.init(supportsModelDiscovery: false, models: [])))
        await testTask.value

        XCTAssertEqual(snapshot?.providerKind, .hktGenAI)
        XCTAssertEqual(snapshot?.authentication, .hktAPIKey)
        XCTAssertEqual(snapshot?.profile.baseURL.absoluteString, "https://api.uat.bot-builder.pccw.com/v1/groups/9876/openai")
    }

    func testHKTBlankDraftUsesDefaultsAndTypedLanguages() {
        let model = AIProviderSettingsModel(
            repository: RecordingProviderRepository(),
            client: StubProviderClient(),
            loadImmediately: false
        )

        model.selectedProviderKind = .hktGenAI

        XCTAssertEqual(model.groupIDText, "")
        XCTAssertEqual(model.asrModel, "private-ai/whisper-large-v3-cantonese-v2")
        XCTAssertEqual(model.llmModel, "gpt-5.5")
        XCTAssertEqual(model.selectedLanguage, .cantonese)
        XCTAssertEqual(MeetingLanguage.allCases.map(\.rawValue), ["yue", "en", "zh"])
        model.selectedLanguage = .mandarin
        XCTAssertEqual(model.language, "zh")
    }

    func testFreshGenericDraftSavesCantoneseWithoutPickerInteraction() {
        let repository = RecordingProviderRepository()
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr"
        model.llmModel = "llm"

        model.save()

        XCTAssertEqual(repository.saveCount, 1)
        XCTAssertEqual(repository.profiles[.openAICompatible]?.language, "yue")
        XCTAssertFalse(model.statusIsError)
    }

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

    func testReloadKeepsSavedProfileWhenAPIKeyStatusFails() throws {
        let repository = RecordingProviderRepository(
            profile: try makeProfile(),
            apiKeyStatusError: TestError.failed
        )

        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )

        XCTAssertTrue(model.hasSavedProfile)
        XCTAssertFalse(model.hasStoredAPIKey)
        XCTAssertEqual(model.apiKeyStatus, .unavailable)
        XCTAssertEqual(model.status, "Provider settings loaded; API key status unavailable")
        XCTAssertTrue(model.statusIsError)
    }

    func testUnavailableAPIKeyStatusKeepsRemovalAvailable() throws {
        let repository = RecordingProviderRepository(
            profile: try makeProfile(),
            apiKeyStatusError: TestError.failed
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )

        XCTAssertTrue(model.hasSavedProfile)
        XCTAssertEqual(model.apiKeyStatus, .unavailable)
        XCTAssertTrue(model.canRemoveAPIKey)
    }

    func testRemovalFromUnavailableStatusReturnsKnownAbsent() throws {
        let repository = RecordingProviderRepository(
            profile: try makeProfile(),
            apiKeyStatusError: TestError.failed
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )

        model.removeAPIKey()

        XCTAssertEqual(repository.removeKeyCount, 1)
        XCTAssertTrue(model.hasSavedProfile)
        XCTAssertEqual(model.apiKeyStatus, .absent)
        XCTAssertFalse(model.canRemoveAPIKey)
        XCTAssertEqual(model.status, "API key removed")
        XCTAssertFalse(model.statusIsError)
    }

    func testFailedRemovalPreservesRecoveryAndRedactsError() throws {
        let repository = RecordingProviderRepository(
            profile: try makeProfile(),
            apiKeyStatusError: TestError.failed,
            removeKeyError: NSError(domain: "secret-keychain-error", code: 1)
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )

        model.removeAPIKey()

        XCTAssertEqual(repository.removeKeyCount, 1)
        XCTAssertTrue(model.hasSavedProfile)
        XCTAssertEqual(model.apiKeyStatus, .unavailable)
        XCTAssertTrue(model.canRemoveAPIKey)
        XCTAssertEqual(model.status, "Could not remove API key.")
        XCTAssertTrue(model.statusIsError)
        XCTAssertFalse(model.status.contains("secret-keychain-error"))
    }

    func testSaveKeepsSavedProfileWhenAPIKeyStatusFails() {
        let repository = RecordingProviderRepository(
            apiKeyStatusError: TestError.failed
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient(),
            loadImmediately: false
        )
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr"
        model.llmModel = "llm"
        model.selectedLanguage = .cantonese

        model.save()

        XCTAssertTrue(model.hasSavedProfile)
        XCTAssertFalse(model.hasStoredAPIKey)
        XCTAssertEqual(model.status, "Provider settings saved; API key status unavailable")
        XCTAssertTrue(model.statusIsError)
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

    func testEditingDraftClearsCompletedDiscoveryAndConnectionStatus() async {
        let client = DeferredProviderClient()
        let model = makeModel(client: client)
        let testTask = Task { await model.testConnection() }
        await client.waitForRequestCount(1)
        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["found"]))
        )
        await testTask.value

        model.prompt = "updated prompt"

        XCTAssertTrue(model.discoveredModels.isEmpty)
        XCTAssertEqual(model.status, "Not configured")
        XCTAssertFalse(model.statusIsError)
    }

    func testSaveAndRemoveKeyClearCompletedDiscoveryAndConnectionStatus() async {
        let client = DeferredProviderClient()
        let model = makeModel(client: client)

        let firstTest = Task { await model.testConnection() }
        await client.waitForRequestCount(1)
        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["found"]))
        )
        await firstTest.value
        model.save()
        XCTAssertTrue(model.discoveredModels.isEmpty)
        XCTAssertEqual(model.status, "Provider settings saved")

        let secondTest = Task { await model.testConnection() }
        await client.waitForRequestCount(2)
        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["found"]))
        )
        await secondTest.value
        model.removeAPIKey()
        XCTAssertTrue(model.discoveredModels.isEmpty)
        XCTAssertEqual(model.status, "API key removed")
    }

    func testNewFailedConnectionClearsPreviousDiscoveryBeforeAndAfterFailure() async {
        let client = DeferredProviderClient()
        let model = makeModel(client: client)
        let successfulTest = Task { await model.testConnection() }
        await client.waitForRequestCount(1)
        await client.completeNext(
            with: .success(.init(supportsModelDiscovery: true, models: ["old"]))
        )
        await successfulTest.value

        let failedTest = Task { await model.testConnection() }
        await client.waitForRequestCount(2)
        XCTAssertTrue(model.discoveredModels.isEmpty)
        await client.completeNext(with: .failure(TestError.failed))
        await failedTest.value

        XCTAssertTrue(model.discoveredModels.isEmpty)
        XCTAssertTrue(model.statusIsError)
    }

    func testSelectingDiscoveredASRThenLLMPreservesDiscoveryAndInvalidatesConnectionOwnership() async {
        let client = DeferredProviderClient()
        let model = makeModel(client: client)
        let testTask = Task { await model.testConnection() }
        await client.waitForRequestCount(1)
        await client.completeNext(
            with: .success(.init(
                supportsModelDiscovery: true,
                models: ["asr-discovered", "llm-discovered"]
            ))
        )
        await testTask.value

        model.selectDiscoveredASRModel("asr-discovered")
        model.selectDiscoveredLLMModel("llm-discovered")

        XCTAssertEqual(model.asrModel, "asr-discovered")
        XCTAssertEqual(model.llmModel, "llm-discovered")
        XCTAssertEqual(model.discoveredModels, ["asr-discovered", "llm-discovered"])
        XCTAssertEqual(model.status, "Not configured")
        XCTAssertFalse(model.isTesting)
    }

    func testSelectingUnknownDiscoveredModelDoesNotChangeDraft() {
        let model = makeModel()
        model.selectDiscoveredASRModel("not-discovered")
        model.selectDiscoveredLLMModel("also-not-discovered")

        XCTAssertEqual(model.asrModel, "asr")
        XCTAssertEqual(model.llmModel, "llm")
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
    var profiles: [AIProviderKind: OpenAICompatibleProviderProfile]
    var keys: [AIProviderKind: Bool]
    private(set) var activeKind: AIProviderKind
    private let migrationError: Error?
    private let apiKeyStatusError: Error?
    private let removeKeyError: Error?
    private(set) var lastReplacementAPIKey: String?
    private(set) var removeKeyCount = 0
    private(set) var saveCount = 0

    init(
        profile: OpenAICompatibleProviderProfile? = nil,
        hasAPIKey: Bool = false,
        migrationError: Error? = nil,
        apiKeyStatusError: Error? = nil,
        removeKeyError: Error? = nil
    ) {
        profiles = profile.map { [.openAICompatible: $0] } ?? [:]
        keys = [.openAICompatible: hasAPIKey, .hktGenAI: false]
        activeKind = .openAICompatible
        self.migrationError = migrationError
        self.apiKeyStatusError = apiKeyStatusError
        self.removeKeyError = removeKeyError
    }

    init(
        profiles: [AIProviderKind: OpenAICompatibleProviderProfile],
        activeKind: AIProviderKind,
        keys: [AIProviderKind: Bool]
    ) {
        self.profiles = profiles
        self.activeKind = activeKind
        self.keys = keys
        migrationError = nil
        apiKeyStatusError = nil
        removeKeyError = nil
    }

    func loadProfile() throws -> OpenAICompatibleProviderProfile? { profiles[activeKind] }

    func loadProfile(for kind: AIProviderKind) throws -> OpenAICompatibleProviderProfile? {
        profiles[kind]
    }

    func activeProviderKind() throws -> AIProviderKind { activeKind }

    func setActiveProviderKind(_ kind: AIProviderKind) throws { activeKind = kind }

    func save(profile: OpenAICompatibleProviderProfile, replacementAPIKey: String?) throws {
        profiles[profile.providerKind] = profile
        activeKind = profile.providerKind
        saveCount += 1
        lastReplacementAPIKey = replacementAPIKey
        if replacementAPIKey != nil { keys[profile.providerKind] = true }
    }

    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        guard let profile = profiles[activeKind] else { throw TestError.failed }
        return try .validated(
            profile: profile,
            apiKey: keys[profile.providerKind] == true ? "saved" : nil
        )
    }

    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot {
        try .validated(
            profile: profile,
            apiKey: keys[profile.providerKind] == true ? "saved" : nil
        )
    }

    func hasAPIKey() throws -> Bool {
        if let apiKeyStatusError { throw apiKeyStatusError }
        return keys[activeKind] == true
    }

    func hasAPIKey(for kind: AIProviderKind) throws -> Bool {
        if let apiKeyStatusError { throw apiKeyStatusError }
        return keys[kind] == true
    }

    func removeAPIKey() throws {
        removeKeyCount += 1
        if let removeKeyError { throw removeKeyError }
        keys[activeKind] = false
    }

    func removeAPIKey(for kind: AIProviderKind) throws {
        removeKeyCount += 1
        if let removeKeyError { throw removeKeyError }
        keys[kind] = false
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
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async throws -> ProviderConnectionReport {
        if let error { throw error }
        return .init(supportsModelDiscovery: true, models: [])
    }
}

private actor DeferredProviderClient: ProviderConnectionTesting {
    private var continuations: [CheckedContinuation<ProviderConnectionReport, Error>] = []
    private var snapshots: [OpenAICompatibleProviderSnapshot] = []
    private var requestsStarted = 0

    func testConnection(
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async throws -> ProviderConnectionReport {
        try await withCheckedThrowingContinuation { continuation in
            requestsStarted += 1
            snapshots.append(snapshot)
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

    func snapshot(at index: Int) -> OpenAICompatibleProviderSnapshot? {
        snapshots.indices.contains(index) ? snapshots[index] : nil
    }
}

private enum TestError: Error { case failed }
