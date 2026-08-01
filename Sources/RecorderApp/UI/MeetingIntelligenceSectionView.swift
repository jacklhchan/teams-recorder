import SwiftUI

/// Pure, deterministic projection of a meeting-intelligence job state.
/// It deliberately owns no model, task, or session lifetime.
struct MeetingIntelligenceSectionPresentation: Equatable, Sendable {
    let status: String
    let summary: String?
    let suggestedTitle: String?
    let showsGenerate: Bool
    let showsRegenerate: Bool
    let showsCancel: Bool
    let showsCheckAgain: Bool
    let showsRetryGeneration: Bool
    let showsApplySuggestedTitle: Bool
    let showsManualTitleProtection: Bool
    let showsProgress: Bool

    static func make(presentation: MeetingIntelligencePresentation) -> Self {
        let isUnconfirmed = presentation.unavailableReason != nil
        let isWorking: Bool
        let showsGenerate: Bool
        let showsRegenerate: Bool
        let showsRetry: Bool

        switch presentation.phase {
        case .notGenerated:
            isWorking = false
            showsGenerate = true
            showsRegenerate = false
            showsRetry = false
        case .checkingAvailability, .generating:
            isWorking = true
            showsGenerate = false
            showsRegenerate = false
            showsRetry = false
        case .ready, .stale:
            isWorking = false
            showsGenerate = false
            showsRegenerate = true
            showsRetry = false
        case .failed, .cancelled, .interrupted:
            isWorking = false
            showsGenerate = false
            showsRegenerate = false
            showsRetry = true
        }

        return .init(
            status: presentation.statusMessage,
            summary: presentation.summary,
            suggestedTitle: presentation.suggestedTitle,
            showsGenerate: showsGenerate,
            showsRegenerate: showsRegenerate,
            showsCancel: isWorking,
            showsCheckAgain: isUnconfirmed,
            showsRetryGeneration: showsRetry,
            showsApplySuggestedTitle: presentation.titleIsProtected && presentation.suggestedTitle != nil,
            showsManualTitleProtection: presentation.titleIsProtected && presentation.suggestedTitle != nil,
            showsProgress: isWorking
        )
    }
}

struct MeetingIntelligenceActions {
    var generate: () -> Void = {}
    var regenerate: () -> Void = {}
    var checkAgain: () -> Void = {}
    var retryGeneration: () -> Void = {}
    var cancel: () -> Void = {}
    var applySuggestedTitle: () -> Void = {}
}

struct MeetingIntelligenceSectionView: View {
    let section: MeetingIntelligenceSectionPresentation
    let actions: MeetingIntelligenceActions

    init(
        presentation: MeetingIntelligencePresentation,
        actions: MeetingIntelligenceActions = .init()
    ) {
        self.section = .make(presentation: presentation)
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Meeting Intelligence", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if section.showsProgress { ProgressView().controlSize(.small) }
                Text(section.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(RecorderActionID.meetingIntelligenceStatus)
                    .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceStatus))
            }
            .accessibilityIdentifier(RecorderActionID.meetingIntelligenceCard)

            if let summary = section.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(RecorderActionID.meetingIntelligenceSummary)
                    .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceSummary))
            }
            if let title = section.suggestedTitle, !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle)
                    .accessibilityLabel(title)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.meetingIntelligenceSuggestedTitle,
                            label: title
                        )
                    )
                if section.showsManualTitleProtection {
                    Text("The current title was edited manually. Apply the suggestion only if you want to replace it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(RecorderActionID.meetingIntelligenceManualTitleProtection)
                        .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceManualTitleProtection))
                }
            }
            HStack(spacing: 8) {
                if section.showsCheckAgain { markedButton("Check Again", id: RecorderActionID.meetingIntelligenceCheckAgain, action: actions.checkAgain) }
                if section.showsGenerate { markedButton("Generate", id: RecorderActionID.meetingIntelligenceGenerate, action: actions.generate) }
                if section.showsRegenerate { markedButton("Regenerate", id: RecorderActionID.meetingIntelligenceRegenerate, action: actions.regenerate) }
                if section.showsRetryGeneration { markedButton("Retry Generation", id: RecorderActionID.meetingIntelligenceRetryGeneration, action: actions.retryGeneration) }
                if section.showsCancel { markedButton("Cancel", id: RecorderActionID.meetingIntelligenceCancel, action: actions.cancel) }
                if section.showsApplySuggestedTitle { markedButton("Apply Suggested Title", id: RecorderActionID.meetingIntelligenceApplyTitle, action: actions.applySuggestedTitle) }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(RecorderVisualStyle.cardSurface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier(RecorderActionID.meetingIntelligenceCard)
        .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceCard))
    }

    private func markedButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .accessibilityIdentifier(id)
            .background(RecorderDestinationAccessibilityMarker(identifier: id))
    }
}
