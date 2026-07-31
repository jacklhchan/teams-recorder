import SwiftUI

enum APIKeyStatus: Equatable {
    case present
    case absent
    case unavailable
}

@MainActor
final class AIProviderSettingsModel: ObservableObject {
    @Published var baseURLText = "" { didSet { invalidateConnectionTest() } }
    @Published var apiKeyReplacement = "" { didSet { invalidateConnectionTest() } }
    @Published var asrModel = "" { didSet { invalidateConnectionTest() } }
    @Published var llmModel = "" { didSet { invalidateConnectionTest() } }
    @Published var language = "" { didSet { invalidateConnectionTest() } }
    @Published var prompt = "" { didSet { invalidateConnectionTest() } }
    @Published private(set) var discoveredModels: [String] = []
    @Published private(set) var apiKeyStatus: APIKeyStatus = .absent
    @Published private(set) var hasSavedProfile = false
    @Published private(set) var isTesting = false
    @Published private(set) var status = "Not configured"
    @Published private(set) var statusIsError = false

    var hasStoredAPIKey: Bool {
        apiKeyStatus == .present
    }

    var canRemoveAPIKey: Bool {
        apiKeyStatus != .absent
    }

    var apiKeyFieldLabel: String {
        switch apiKeyStatus {
        case .present:
            "API Key (saved)"
        case .absent:
            "API Key (optional)"
        case .unavailable:
            "API Key (status unavailable)"
        }
    }

    private let repository: any OpenAICompatibleProviderManaging
    private let client: any ProviderConnectionTesting
    private var connectionTestGeneration: UInt64 = 0

    init(
        repository: any OpenAICompatibleProviderManaging,
        client: any ProviderConnectionTesting = OpenAICompatibleProviderClient(),
        loadImmediately: Bool = true,
        initialErrorStatus: String? = nil
    ) {
        self.repository = repository
        self.client = client
        if loadImmediately {
            reload()
        }
        if let initialErrorStatus {
            status = initialErrorStatus
            statusIsError = true
        }
    }

    func save() {
        invalidateConnectionTest()
        do {
            let profile = try draftProfile()
            try repository.save(
                profile: profile,
                replacementAPIKey: apiKeyReplacement.isEmpty ? nil : apiKeyReplacement
            )
            apiKeyReplacement = ""
            hasSavedProfile = true
            updateAPIKeyStatus(after: "Provider settings saved")
        } catch {
            hasSavedProfile = false
            present(error)
        }
    }

    func removeAPIKey() {
        invalidateConnectionTest()
        do {
            try repository.removeAPIKey()
            apiKeyReplacement = ""
            apiKeyStatus = .absent
            status = "API key removed"
            statusIsError = false
        } catch {
            if apiKeyStatus != .present {
                apiKeyStatus = .unavailable
            }
            status = "Could not remove API key."
            statusIsError = true
        }
    }

    func testConnection() async {
        let generation = beginConnectionTest()
        do {
            let profile = try draftProfile()
            let snapshot = try repository.snapshot(overriding: profile)
            let report = try await client.testConnection(for: snapshot)
            guard generation == connectionTestGeneration else { return }
            discoveredModels = report.models
            status = report.supportsModelDiscovery
                ? "Connected; model list available"
                : "Connected; enter models manually"
            statusIsError = false
            isTesting = false
        } catch {
            guard generation == connectionTestGeneration else { return }
            present(error)
            isTesting = false
        }
    }

    func performStartupMigration(settingsURL: URL) {
        invalidateConnectionTest()
        do {
            _ = try repository.migrateLegacyIfNeeded(settingsURL: settingsURL)
            reload()
        } catch {
            status = "Legacy provider settings could not be migrated. "
                + "Configure the AI provider manually."
            statusIsError = true
        }
    }

    func selectDiscoveredASRModel(_ id: String) {
        selectDiscoveredModel(id) { self.asrModel = id }
    }

    func selectDiscoveredLLMModel(_ id: String) {
        selectDiscoveredModel(id) { self.llmModel = id }
    }

    func reload() {
        invalidateConnectionTest()
        do {
            guard let profile = try repository.loadProfile() else {
                hasSavedProfile = false
                updateAPIKeyStatus(after: "Not configured")
                return
            }
            baseURLText = profile.baseURL.absoluteString
            asrModel = profile.asrModel
            llmModel = profile.llmModel
            language = profile.language
            prompt = profile.prompt
            apiKeyReplacement = ""
            hasSavedProfile = true
            updateAPIKeyStatus(after: "Provider settings loaded")
        } catch {
            hasSavedProfile = false
            present(error)
        }
    }

    private func draftProfile() throws -> OpenAICompatibleProviderProfile {
        try OpenAICompatibleProviderProfile.validated(
            baseURLText: baseURLText,
            asrModel: asrModel,
            llmModel: llmModel,
            language: language,
            prompt: prompt
        )
    }

    private func present(_: Error) {
        status = "Could not update provider settings."
        statusIsError = true
    }

    private func updateAPIKeyStatus(after successfulProfileStatus: String) {
        do {
            apiKeyStatus = try repository.hasAPIKey() ? .present : .absent
            status = successfulProfileStatus
            statusIsError = false
        } catch {
            apiKeyStatus = .unavailable
            status = successfulProfileStatus + "; API key status unavailable"
            statusIsError = true
        }
    }

    private func beginConnectionTest() -> UInt64 {
        invalidateConnectionTest()
        isTesting = true
        return connectionTestGeneration
    }

    private func selectDiscoveredModel(_ id: String, apply: () -> Void) {
        guard discoveredModels.contains(id) else { return }
        let discoveredModels = discoveredModels
        apply()
        self.discoveredModels = discoveredModels
    }

    private func invalidateConnectionTest() {
        connectionTestGeneration &+= 1
        isTesting = false
        discoveredModels = []
        status = "Not configured"
        statusIsError = false
    }
}
