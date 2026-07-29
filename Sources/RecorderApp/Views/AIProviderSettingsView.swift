import SwiftUI

struct AIProviderSettingsView: View {
    @ObservedObject var model: AIProviderSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI Provider", systemImage: "server.rack")
                .font(.headline)

            TextField("API Base URL", text: $model.baseURLText)
                .textFieldStyle(.roundedBorder)
            SecureField(
                model.hasStoredAPIKey ? "API Key (saved)" : "API Key (optional)",
                text: $model.apiKeyReplacement
            )
            modelField("ASR Model", text: $model.asrModel)
            modelField("LLM Model", text: $model.llmModel)
            TextField("Language", text: $model.language)
                .textFieldStyle(.roundedBorder)
            Text("Prompt")
                .font(.subheadline)
            TextEditor(text: $model.prompt)
                .accessibilityLabel("Prompt")
                .frame(minHeight: 58, maxHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator)
                )

            HStack {
                Button("Save", systemImage: "square.and.arrow.down") {
                    model.save()
                }
                Button("Test", systemImage: "network") {
                    Task { await model.testConnection() }
                }
                .disabled(model.isTesting)
                Button("Remove Key", systemImage: "key.slash", role: .destructive) {
                    model.removeAPIKey()
                }
                .disabled(!model.hasStoredAPIKey)
                Spacer()
                if model.isTesting {
                    ProgressView().controlSize(.small)
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.statusIsError ? .orange : .secondary)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55))
        )
    }

    private func modelField(
        _ title: String,
        text: Binding<String>
    ) -> some View {
        HStack {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
            if !model.discoveredModels.isEmpty {
                Menu {
                    ForEach(model.discoveredModels, id: \.self) { value in
                        Button(value) { text.wrappedValue = value }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .help("Choose a discovered model")
                .accessibilityLabel("Choose discovered \(title) model")
            }
        }
    }
}
