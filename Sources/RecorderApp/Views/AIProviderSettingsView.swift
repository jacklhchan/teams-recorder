import AppKit
import SwiftUI

struct AIProviderSettingsView: View {
    @ObservedObject var model: AIProviderSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerSurface("Connection", systemImage: "server.rack") {
                Picker("Provider", selection: providerKindBinding) {
                    ForEach(model.providerKinds, id: \.rawValue) { kind in
                        Text(providerLabel(for: kind)).tag(kind.rawValue)
                    }
                }
                .providerAccessibility(RecorderActionID.providerKind)

                providerEndpointFields

                SecureField(model.apiKeyFieldLabel, text: $model.apiKeyReplacement)
                    .providerAccessibility(RecorderActionID.providerAPIKey)
            }

            providerSurface("Models", systemImage: "cpu") {
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
            }

            providerSurface("Transcription", systemImage: "waveform") {
                Picker("Language", selection: languageBinding) {
                    ForEach(model.languages, id: \.rawValue) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .providerAccessibility(RecorderActionID.providerLanguage)

                Text("ASR Prompt")
                    .font(.subheadline)
                Text("Optional transcription guidance sent only with future transcription jobs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.prompt)
                    .accessibilityLabel("ASR Prompt")
                    .providerAccessibility(RecorderActionID.providerPrompt)
                    .frame(minHeight: 58, maxHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }

            HStack(alignment: .center, spacing: 10) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Save", systemImage: "square.and.arrow.down") { model.save() }
                            .recorderGlassSurface(.primaryControls)
                            .providerAccessibility(RecorderActionID.providerSave)
                        Button("Test", systemImage: "network") {
                            Task { await model.testConnection() }
                        }
                        .recorderGlassSurface(.primaryControls)
                        .providerAccessibility(RecorderActionID.providerTest)
                        .disabled(model.isTesting)
                    }
                }

                Button("Remove Key", systemImage: "key.slash", role: .destructive) {
                    model.removeAPIKey()
                }
                .buttonStyle(.borderless)
                .providerAccessibility(RecorderActionID.providerRemoveKey)
                .disabled(!model.canRemoveAPIKey)

                Spacer(minLength: 0)
                if model.isTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing connection…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .background(ProviderSettingsAccessibilityMarker(label: "Testing connection…"))
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.statusIsError ? .orange : .secondary)
                    .providerAccessibility(RecorderActionID.providerStatus, label: model.status)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func providerSurface<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityLabel(title)
                .background(ProviderSettingsAccessibilityMarker(label: title))
            content()
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.55)))
    }

    @ViewBuilder
    private var providerEndpointFields: some View {
        switch model.selectedProviderKind {
        case .hktGenAI:
            TextField("Group ID", text: $model.groupIDText)
                .textFieldStyle(.roundedBorder)
                .providerAccessibility(RecorderActionID.providerHKTGroupID)
            LabeledContent("Resolved API Base URL") {
                Text(model.resolvedHKTURLText)
                    .textSelection(.enabled)
                    .font(.caption.monospaced())
                    .providerAccessibility(RecorderActionID.providerHKTResolvedURL)
            }
        case .openAICompatible:
            TextField("API Base URL", text: $model.baseURLText)
                .textFieldStyle(.roundedBorder)
                .providerAccessibility(RecorderActionID.providerBaseURL)
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
                .providerAccessibility(accessibilityIdentifier)
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

private extension View {
    func providerAccessibility(
        _ identifier: String, label: String? = nil
    ) -> some View {
        accessibilityIdentifier(identifier)
            .background(
                ProviderSettingsAccessibilityMarker(
                    identifier: identifier + ".marker", label: label
                )
            )
    }
}

private struct ProviderSettingsAccessibilityMarker: NSViewRepresentable {
    var identifier: String? = nil
    var label: String? = nil

    func makeNSView(context _: Context) -> ProviderSettingsAccessibilityMarkerView {
        let view = ProviderSettingsAccessibilityMarkerView(frame: .zero)
        if let identifier { view.setAccessibilityIdentifier(identifier) }
        if let label { view.setAccessibilityLabel(label) }
        return view
    }

    func updateNSView(_ view: ProviderSettingsAccessibilityMarkerView, context _: Context) {
        if let label { view.setAccessibilityLabel(label) }
    }
}

private final class ProviderSettingsAccessibilityMarkerView: NSView {}
