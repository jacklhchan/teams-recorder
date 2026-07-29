import SwiftUI

@MainActor
final class AIProviderSettingsModel: ObservableObject {
    @Published var baseURLText = ""
    @Published var apiKeyReplacement = ""
    @Published var asrModel = ""
    @Published var llmModel = ""
    @Published var language = ""
    @Published var prompt = ""
    @Published private(set) var discoveredModels: [String] = []
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var hasSavedProfile = false
    @Published private(set) var isTesting = false
    @Published private(set) var status = "Not configured"
    @Published private(set) var statusIsError = false

    private let repository: any OpenAICompatibleProviderManaging
    private let client: any ProviderConnectionTesting

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
        do {
            let profile = try draftProfile()
            try repository.save(
                profile: profile,
                replacementAPIKey: apiKeyReplacement.isEmpty ? nil : apiKeyReplacement
            )
            apiKeyReplacement = ""
            hasStoredAPIKey = try repository.hasAPIKey()
            hasSavedProfile = true
            status = "Provider settings saved"
            statusIsError = false
        } catch {
            present(error)
        }
    }

    func removeAPIKey() {
        do {
            try repository.removeAPIKey()
            apiKeyReplacement = ""
            hasStoredAPIKey = false
            status = "API key removed"
            statusIsError = false
        } catch {
            present(error)
        }
    }

    func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let profile = try draftProfile()
            let snapshot = try repository.snapshot(overriding: profile)
            let report = try await client.testConnection(
                profile: profile,
                apiKey: snapshot.apiKey
            )
            discoveredModels = report.models
            status = report.supportsModelDiscovery
                ? "Connected; model list available"
                : "Connected; enter models manually"
            statusIsError = false
        } catch {
            present(error)
        }
    }

    func performStartupMigration(settingsURL: URL) {
        do {
            _ = try repository.migrateLegacyIfNeeded(settingsURL: settingsURL)
            reload()
        } catch {
            status = "Legacy provider settings could not be migrated. "
                + "Configure the AI provider manually."
            statusIsError = true
        }
    }

    private func reload() {
        do {
            guard let profile = try repository.loadProfile() else {
                hasSavedProfile = false
                hasStoredAPIKey = try repository.hasAPIKey()
                status = "Not configured"
                statusIsError = false
                return
            }
            baseURLText = profile.baseURL.absoluteString
            asrModel = profile.asrModel
            llmModel = profile.llmModel
            language = profile.language
            prompt = profile.prompt
            apiKeyReplacement = ""
            hasStoredAPIKey = try repository.hasAPIKey()
            hasSavedProfile = true
            status = "Provider settings loaded"
            statusIsError = false
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
}
