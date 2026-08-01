import SwiftUI

enum APIKeyStatus: Equatable {
    case present
    case absent
    case unavailable
}

enum MeetingLanguage: String, CaseIterable, Sendable {
    case cantonese = "yue"
    case english = "en"
    case mandarin = "zh"

    var displayName: String {
        switch self {
        case .cantonese: "Cantonese"
        case .english: "English"
        case .mandarin: "Mandarin"
        }
    }
}

@MainActor
final class AIProviderSettingsModel: ObservableObject {
    @Published var selectedProviderKind: AIProviderKind = .openAICompatible {
        didSet { selectProvider(from: oldValue) }
    }
    @Published var baseURLText = "" { didSet { invalidateConnectionTest() } }
    @Published var groupIDText = "" { didSet { invalidateConnectionTest() } }
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

    /// Delivers exactly once for each repository save that has committed. A
    /// later API-key status lookup is presentation-only and cannot suppress it.
    var onProviderSettingsSaved: ((ProviderSettingsSaved) -> Void)? {
        get { providerSettingsSavedCallback }
        set { replaceProviderSettingsSavedObserver(with: newValue) }
    }

    var hasStoredAPIKey: Bool { apiKeyStatus == .present }
    var canRemoveAPIKey: Bool { apiKeyStatus != .absent }
    var providerKinds: [AIProviderKind] { [.hktGenAI, .openAICompatible] }
    var languages: [MeetingLanguage] { MeetingLanguage.allCases }

    var selectedLanguage: MeetingLanguage {
        get { MeetingLanguage(rawValue: language) ?? .cantonese }
        set { language = newValue.rawValue }
    }

    var resolvedHKTURLText: String {
        OpenAICompatibleProviderProfile.hktBaseURLPrefix + groupIDText + "/openai"
    }

    var apiKeyFieldLabel: String {
        switch apiKeyStatus {
        case .present: "API Key (saved)"
        case .absent: "API Key (optional)"
        case .unavailable: "API Key (status unavailable)"
        }
    }

    private struct Draft: Equatable {
        var baseURLText = ""
        var groupIDText = ""
        var asrModel = ""
        var llmModel = ""
        var language = ""
        var prompt = ""

        static func blank(for kind: AIProviderKind) -> Self {
            switch kind {
            case .openAICompatible:
                Self(language: MeetingLanguage.cantonese.rawValue)
            case .hktGenAI:
                Self(
                    asrModel: "private-ai/whisper-large-v3-cantonese-v2",
                    llmModel: "gpt-5.5",
                    language: MeetingLanguage.cantonese.rawValue
                )
            }
        }

        init(profile: OpenAICompatibleProviderProfile) {
            baseURLText = profile.baseURL.absoluteString
            groupIDText = profile.groupID ?? ""
            asrModel = profile.asrModel
            llmModel = profile.llmModel
            language = profile.language
            prompt = profile.prompt
        }

        init(
            baseURLText: String = "", groupIDText: String = "", asrModel: String = "",
            llmModel: String = "", language: String = "", prompt: String = ""
        ) {
            self.baseURLText = baseURLText
            self.groupIDText = groupIDText
            self.asrModel = asrModel
            self.llmModel = llmModel
            self.language = language
            self.prompt = prompt
        }
    }

    private let repository: any OpenAICompatibleProviderManaging
    /// Settings owns only the UI projection. This identity proves its saves
    /// target the same mutable repository observed by future ASR/MI jobs.
    let providerRepositoryIdentity: ObjectIdentifier
    private let client: any ProviderConnectionTesting
    private var drafts: [AIProviderKind: Draft] = [:]
    private var replacements: [AIProviderKind: String] = [:]
    private var savedKinds: Set<AIProviderKind> = []
    private var applyingDraft = false
    private var connectionTestGeneration: UInt64 = 0
    private var providerSettingsSavedToken: UUID?
    private var providerSettingsSavedCallback: ((ProviderSettingsSaved) -> Void)?

    init(
        repository: any OpenAICompatibleProviderManaging,
        client: any ProviderConnectionTesting = OpenAICompatibleProviderClient(),
        loadImmediately: Bool = true,
        initialErrorStatus: String? = nil
    ) {
        self.repository = repository
        providerRepositoryIdentity = repository.compositionIdentity
        self.client = client
        if loadImmediately { reload() }
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
            onProviderSettingsSaved?(.init(profileRevision: UUID()))
            savedKinds.insert(selectedProviderKind)
            drafts[selectedProviderKind] = Draft(profile: profile)
            apply(draft: drafts[selectedProviderKind]!)
            replacements[selectedProviderKind] = ""
            apiKeyReplacement = ""
            hasSavedProfile = true
            updateAPIKeyStatus(after: "Provider settings saved")
        } catch {
            hasSavedProfile = savedKinds.contains(selectedProviderKind)
            present(error)
        }
    }

    @discardableResult
    func observeProviderSettingsSaved(
        _ observer: @escaping (ProviderSettingsSaved) -> Void
    ) -> UUID {
        let token = UUID()
        providerSettingsSavedToken = token
        providerSettingsSavedCallback = observer
        return token
    }

    func removeProviderSettingsSavedObserver(_ token: UUID) {
        guard providerSettingsSavedToken == token else { return }
        providerSettingsSavedToken = nil
        providerSettingsSavedCallback = nil
    }

    func removeAPIKey() {
        invalidateConnectionTest()
        do {
            try repository.removeAPIKey(for: selectedProviderKind)
            replacements[selectedProviderKind] = ""
            apiKeyReplacement = ""
            apiKeyStatus = .absent
            status = "API key removed"
            statusIsError = false
        } catch {
            if apiKeyStatus != .present { apiKeyStatus = .unavailable }
            status = "Could not remove API key."
            statusIsError = true
        }
    }

    private func replaceProviderSettingsSavedObserver(
        with observer: ((ProviderSettingsSaved) -> Void)?
    ) {
        guard let observer else {
            providerSettingsSavedToken = nil
            providerSettingsSavedCallback = nil
            return
        }
        _ = observeProviderSettingsSaved(observer)
    }

    func testConnection() async {
        let generation = beginConnectionTest()
        do {
            let snapshot = try repository.snapshot(overriding: draftProfile())
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
            status = "Legacy provider settings could not be migrated. Configure the AI provider manually."
            statusIsError = true
        }
    }

    func selectDiscoveredASRModel(_ id: String) { selectDiscoveredModel(id) { self.asrModel = id } }
    func selectDiscoveredLLMModel(_ id: String) { selectDiscoveredModel(id) { self.llmModel = id } }

    func reload() {
        invalidateConnectionTest()
        do {
            var loadedDrafts: [AIProviderKind: Draft] = [:]
            var loadedKinds: Set<AIProviderKind> = []
            for kind in AIProviderKind.allCases {
                if let profile = try repository.loadProfile(for: kind) {
                    loadedDrafts[kind] = Draft(profile: profile)
                    loadedKinds.insert(kind)
                }
            }
            let active = try repository.activeProviderKind()
            drafts = loadedDrafts
            replacements = [:]
            savedKinds = loadedKinds
            applyingDraft = true
            selectedProviderKind = active
            apply(draft: loadedDrafts[active] ?? .blank(for: active))
            applyingDraft = false
            hasSavedProfile = loadedKinds.contains(active)
            updateAPIKeyStatus(after: hasSavedProfile ? "Provider settings loaded" : "Not configured")
        } catch {
            hasSavedProfile = false
            present(error)
        }
    }

    private func selectProvider(from previous: AIProviderKind) {
        guard !applyingDraft, previous != selectedProviderKind else { return }
        invalidateConnectionTest()
        drafts[previous] = currentDraft()
        replacements[previous] = apiKeyReplacement
        apply(draft: drafts[selectedProviderKind] ?? .blank(for: selectedProviderKind))
        apiKeyReplacement = replacements[selectedProviderKind] ?? ""
        hasSavedProfile = savedKinds.contains(selectedProviderKind)
        updateAPIKeyStatus(after: hasSavedProfile ? "Provider settings loaded" : "Not configured")
    }

    private func currentDraft() -> Draft {
        .init(
            baseURLText: baseURLText, groupIDText: groupIDText, asrModel: asrModel,
            llmModel: llmModel, language: language, prompt: prompt
        )
    }

    private func apply(draft: Draft) {
        applyingDraft = true
        baseURLText = draft.baseURLText
        groupIDText = draft.groupIDText
        asrModel = draft.asrModel
        llmModel = draft.llmModel
        language = draft.language
        prompt = draft.prompt
        applyingDraft = false
    }

    private func draftProfile() throws -> OpenAICompatibleProviderProfile {
        switch selectedProviderKind {
        case .openAICompatible:
            try OpenAICompatibleProviderProfile.validated(
                baseURLText: baseURLText, asrModel: asrModel, llmModel: llmModel,
                language: language, prompt: prompt
            )
        case .hktGenAI:
            try OpenAICompatibleProviderProfile.hktValidated(
                groupID: groupIDText, asrModel: asrModel, llmModel: llmModel,
                language: language, prompt: prompt
            )
        }
    }

    private func present(_: Error) {
        status = "Could not update provider settings."
        statusIsError = true
    }

    private func updateAPIKeyStatus(after successfulProfileStatus: String) {
        do {
            apiKeyStatus = try repository.hasAPIKey(for: selectedProviderKind) ? .present : .absent
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
        guard !applyingDraft else { return }
        connectionTestGeneration &+= 1
        isTesting = false
        discoveredModels = []
        status = "Not configured"
        statusIsError = false
    }
}
