import SwiftUI

struct TranscriptionRequestDraft: Identifiable, Equatable {
    let id = UUID()
    let sessionID: RecordingSession.ID
    let sessionName: String
    var language: MeetingLanguage = .cantonese
    var prompt = ""

    var options: TranscriptionRequestOptions {
        .init(language: language, prompt: prompt)
    }

}

struct TranscriptionRequestSheet: View {
    @State private var draft: TranscriptionRequestDraft
    let cancel: () -> Void
    let submit: (TranscriptionRequestOptions) -> Void

    init(
        draft: TranscriptionRequestDraft,
        cancel: @escaping () -> Void,
        submit: @escaping (TranscriptionRequestOptions) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.cancel = cancel
        self.submit = submit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcribe \(draft.sessionName)").font(.headline)
            Picker("Language", selection: $draft.language) {
                ForEach(MeetingLanguage.allCases, id: \.rawValue) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(RecorderActionID.transcriptionLanguage)
            .accessibilityValue(draft.language.displayName)
            .background(
                RecorderDestinationAccessibilityMarker(
                    identifier: RecorderActionID.transcriptionLanguage,
                    label: "Language",
                    value: draft.language.displayName
                )
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt (optional):")
                    .font(.subheadline.weight(.medium))
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: "\(RecorderActionID.transcriptionPrompt).label",
                            label: "Prompt (optional):"
                        )
                    )

                ZStack(alignment: .topLeading) {
                    Color(nsColor: .textBackgroundColor)

                    TextEditor(text: $draft.prompt)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(4)
                        .accessibilityLabel("Prompt")
                        .accessibilityIdentifier(RecorderActionID.transcriptionPrompt)
                        .background(
                            RecorderDestinationAccessibilityMarker(
                                identifier: RecorderActionID.transcriptionPrompt,
                                label: "Prompt"
                            )
                        )

                    if draft.prompt.isEmpty {
                        Text("Names, terminology, or transcription guidance…")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .background(
                                RecorderDestinationAccessibilityMarker(
                                    identifier: "\(RecorderActionID.transcriptionPrompt).placeholder",
                                    label: "Names, terminology, or transcription guidance…"
                                )
                            )
                    }
                }
                .frame(minHeight: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(RecorderActionID.transcriptionCancel)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.transcriptionCancel,
                            label: "Cancel"
                        )
                    )
                Button("Transcribe") {
                    submit(draft.options)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(RecorderActionID.transcriptionSubmit)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.transcriptionSubmit,
                            label: "Transcribe"
                        )
                    )
            }
        }
        .padding(18)
        .frame(width: 460)
        .frame(minHeight: 220)
        .accessibilityIdentifier(RecorderActionID.transcriptionSheet)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: RecorderActionID.transcriptionSheet
            )
        )
    }
}
