import SwiftUI

struct AIProviderSettingsView: View {
    @ObservedObject var model: AIProviderSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI Provider", systemImage: "server.rack")
                .font(.headline)

            Picker("Provider", selection: providerKindBinding) {
                ForEach(model.providerKinds, id: \.rawValue) { kind in
                    Text(providerLabel(for: kind)).tag(kind.rawValue)
                }
            }
            .accessibilityIdentifier(RecorderActionID.providerKind)

            providerEndpointFields

            SecureField(model.apiKeyFieldLabel, text: $model.apiKeyReplacement)
                .accessibilityIdentifier(RecorderActionID.providerAPIKey)
            modelField(
                "ASR Model", text: $model.asrModel,
                accessibilityIdentifier: RecorderActionID.providerASRModel,
                selectDiscoveredModel: model.selectDiscoveredASRModel
            )
            Text("Used for transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
            modelField(
                "LLM Model", text: $model.llmModel,
                accessibilityIdentifier: RecorderActionID.providerLLMModel,
                selectDiscoveredModel: model.selectDiscoveredLLMModel
            )
            Text("Used for summary and contextual title generation. Automatic meeting intelligence requires this model to appear in the provider model list.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Language", selection: languageBinding) {
                ForEach(model.languages, id: \.rawValue) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .accessibilityIdentifier(RecorderActionID.providerLanguage)

            Text("ASR Prompt")
                .font(.subheadline)
            Text("Optional transcription guidance sent only with future transcription jobs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.prompt)
                .accessibilityLabel("ASR Prompt")
                .accessibilityIdentifier(RecorderActionID.providerPrompt)
                .frame(minHeight: 58, maxHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator)
                )

            HStack {
                Button("Save", systemImage: "square.and.arrow.down") { model.save() }
                    .accessibilityIdentifier(RecorderActionID.providerSave)
                Button("Test", systemImage: "network") {
                    Task { await model.testConnection() }
                }
                .accessibilityIdentifier(RecorderActionID.providerTest)
                .disabled(model.isTesting)
                Button("Remove Key", systemImage: "key.slash", role: .destructive) {
                    model.removeAPIKey()
                }
                .accessibilityIdentifier(RecorderActionID.providerRemoveKey)
                .disabled(!model.canRemoveAPIKey)
                Spacer()
                if model.isTesting { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.statusIsError ? .orange : .secondary)
                    .accessibilityIdentifier(RecorderActionID.providerStatus)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55))
        )
    }

    @ViewBuilder
    private var providerEndpointFields: some View {
        switch model.selectedProviderKind {
        case .hktGenAI:
            TextField("Group ID", text: $model.groupIDText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(RecorderActionID.providerHKTGroupID)
            LabeledContent("Resolved API Base URL") {
                Text(model.resolvedHKTURLText)
                    .textSelection(.enabled)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier(RecorderActionID.providerHKTResolvedURL)
            }
        case .openAICompatible:
            TextField("API Base URL", text: $model.baseURLText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(RecorderActionID.providerBaseURL)
        }
    }

    private var providerKindBinding: Binding<String> {
        Binding(
            get: { model.selectedProviderKind.rawValue },
            set: { if let kind = AIProviderKind(rawValue: $0) { model.selectedProviderKind = kind } }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(get: { model.selectedLanguage.rawValue }, set: {
            if let language = MeetingLanguage(rawValue: $0) { model.selectedLanguage = language }
        })
    }

    private func providerLabel(for kind: AIProviderKind) -> String {
        switch kind {
        case .hktGenAI: "HKT GenAI Platform"
        case .openAICompatible: "OpenAI-compatible API"
        }
    }

    private func modelField(
        _ title: String,
        text: Binding<String>,
        accessibilityIdentifier: String,
        selectDiscoveredModel: @escaping (String) -> Void
    ) -> some View {
        HStack {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(accessibilityIdentifier)
            if !model.discoveredModels.isEmpty {
                Menu {
                    ForEach(model.discoveredModels, id: \.self) { value in
                        Button(value) { selectDiscoveredModel(value) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .help("Choose discovered \(title)")
                .accessibilityLabel("Choose discovered \(title)")
            }
        }
    }
}
