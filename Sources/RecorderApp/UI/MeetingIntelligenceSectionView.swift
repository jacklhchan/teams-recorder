import SwiftUI

private struct MeetingIntelligenceReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var meetingIntelligenceReduceMotionOverride: Bool? {
        get { self[MeetingIntelligenceReduceMotionOverrideKey.self] }
        set { self[MeetingIntelligenceReduceMotionOverrideKey.self] = newValue }
    }
}

enum MeetingIntelligenceActionGroup: Equatable, Sendable {
    case availability(checkAgain: Bool)
    case working
    case ready(checkAgain: Bool, applySuggestedTitle: Bool)
    case recovery(checkAgain: Bool, applySuggestedTitle: Bool)
}

enum RecorderStatusTone: Equatable, Sendable {
    case neutral
    case working
    case success
    case warning
}

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
    let actionGroup: MeetingIntelligenceActionGroup
    let statusTone: RecorderStatusTone
    let manualTitleProtectionCopy: String
    let manualTitleProtectionAccessibilityLabel: String

    static func make(presentation: MeetingIntelligencePresentation) -> Self {
        let isUnconfirmed = presentation.unavailableReason != nil
        let actionGroup: MeetingIntelligenceActionGroup
        let statusTone: RecorderStatusTone

        switch presentation.phase {
        case .notGenerated:
            actionGroup = .availability(checkAgain: isUnconfirmed)
            statusTone = .neutral
        case .checkingAvailability, .generating:
            actionGroup = .working
            statusTone = .working
        case .ready, .stale:
            actionGroup = .ready(
                checkAgain: isUnconfirmed,
                applySuggestedTitle: presentation.titleIsProtected && presentation.suggestedTitle != nil
            )
            statusTone = .success
        case .failed, .cancelled, .interrupted:
            actionGroup = .recovery(
                checkAgain: isUnconfirmed,
                applySuggestedTitle: presentation.titleIsProtected && presentation.suggestedTitle != nil
            )
            statusTone = .warning
        }

        let showsWorking = actionGroup == .working
        let showsApplySuggestedTitle: Bool
        switch actionGroup {
        case let .ready(_, apply), let .recovery(_, apply): showsApplySuggestedTitle = apply
        case .availability, .working: showsApplySuggestedTitle = false
        }

        return .init(
            status: presentation.statusMessage,
            summary: presentation.summary,
            suggestedTitle: presentation.suggestedTitle,
            showsGenerate: actionGroup != .working && actionGroup == .availability(checkAgain: isUnconfirmed),
            showsRegenerate: {
                if case .ready = actionGroup { return true }
                return false
            }(),
            showsCancel: showsWorking,
            showsCheckAgain: isUnconfirmed,
            showsRetryGeneration: {
                if case .recovery = actionGroup { return true }
                return false
            }(),
            showsApplySuggestedTitle: showsApplySuggestedTitle,
            showsManualTitleProtection: presentation.titleIsProtected && presentation.suggestedTitle != nil,
            showsProgress: showsWorking,
            actionGroup: actionGroup,
            statusTone: statusTone,
            manualTitleProtectionCopy: "The current title was edited manually. Apply the suggestion only if you want to replace it.",
            manualTitleProtectionAccessibilityLabel: "Manual title protected"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.meetingIntelligenceReduceMotionOverride) private var reduceMotionOverride
    let section: MeetingIntelligenceSectionPresentation
    let actions: MeetingIntelligenceActions
    private let observedSnapshot: RecorderObservedSnapshot?
    @State private var previousObservedSnapshot: RecorderObservedSnapshot?
    @State private var showsCompletionFeedback = false
    @State private var highlightsSuggestedTitle = false
    @State private var feedbackResetTask: Task<Void, Never>?
    @State private var revealsContent = false

    init(
        presentation: MeetingIntelligencePresentation,
        observedSnapshot: RecorderObservedSnapshot? = nil,
        actions: MeetingIntelligenceActions = .init()
    ) {
        self.section = .make(presentation: presentation)
        self.observedSnapshot = observedSnapshot
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Meeting Intelligence", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if section.showsProgress { RecorderIndeterminateProgress().controlSize(.small) }
                if showsCompletionFeedback {
                    completionCheck
                        .transition(.opacity.combined(with: .offset(y: motionPolicy.revealOffset)))
                }
                Text(section.status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
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
                    .opacity(revealsContent ? 1 : 0)
                    .offset(y: revealsContent ? 0 : motionPolicy.revealOffset)
                    .transition(.opacity.combined(with: .offset(y: motionPolicy.revealOffset)))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: motionPolicy.revealDuration), value: section.summary)
            }
            if let title = section.suggestedTitle, !title.isEmpty {
                ZStack {
                    if highlightsSuggestedTitle {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.16))
                            .accessibilityIdentifier("meeting-intelligence.feedback.generated-title")
                            .accessibilityValue("accent-overlay")
                            .background(RecorderDestinationAccessibilityMarker(identifier: "meeting-intelligence.feedback.generated-title"))
                            .transition(.opacity.combined(with: .offset(y: motionPolicy.revealOffset)))
                    }
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .accessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle)
                        .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceSuggestedTitle))
                        .contentTransition(.opacity)
                }
                .opacity(revealsContent ? 1 : 0)
                .offset(y: revealsContent ? 0 : motionPolicy.revealOffset)
                .transition(.opacity.combined(with: .offset(y: motionPolicy.revealOffset)))
                .animation(.easeInOut(duration: motionPolicy.revealDuration), value: section.suggestedTitle)
                if section.showsManualTitleProtection {
                    Text(section.manualTitleProtectionCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(section.manualTitleProtectionAccessibilityLabel)
                        .accessibilityIdentifier(RecorderActionID.meetingIntelligenceManualTitleProtection)
                        .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceManualTitleProtection))
                }
            }
            RecorderStatusTransition(value: section.actionGroup) { actionGroup in
                HStack(spacing: 8) {
                    switch actionGroup {
                    case let .availability(checkAgain):
                        if checkAgain { markedButton("Check Again", id: RecorderActionID.meetingIntelligenceCheckAgain, action: actions.checkAgain) }
                        markedButton("Generate", id: RecorderActionID.meetingIntelligenceGenerate, action: actions.generate)
                    case .working:
                        markedButton("Cancel", id: RecorderActionID.meetingIntelligenceCancel, action: actions.cancel)
                    case let .ready(checkAgain, applySuggestedTitle):
                        if checkAgain { markedButton("Check Again", id: RecorderActionID.meetingIntelligenceCheckAgain, action: actions.checkAgain) }
                        markedButton("Regenerate", id: RecorderActionID.meetingIntelligenceRegenerate, action: actions.regenerate)
                        if applySuggestedTitle { markedButton("Apply Suggested Title", id: RecorderActionID.meetingIntelligenceApplyTitle, action: actions.applySuggestedTitle) }
                    case let .recovery(checkAgain, applySuggestedTitle):
                        if checkAgain { markedButton("Check Again", id: RecorderActionID.meetingIntelligenceCheckAgain, action: actions.checkAgain) }
                        markedButton("Retry Generation", id: RecorderActionID.meetingIntelligenceRetryGeneration, action: actions.retryGeneration)
                        if applySuggestedTitle { markedButton("Apply Suggested Title", id: RecorderActionID.meetingIntelligenceApplyTitle, action: actions.applySuggestedTitle) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RecorderVisualStyle.cardSurface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier(RecorderActionID.meetingIntelligenceCard)
        .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceCard))
        .onAppear {
            resetObservedFeedback()
            previousObservedSnapshot = observedSnapshot
            revealsContent = true
        }
        .onChange(of: observedSnapshot) { _, current in
            updateObservedFeedback(current)
        }
        .onDisappear {
            resetObservedFeedback()
        }
        .animation(.easeInOut(duration: motionPolicy.revealDuration), value: showsCompletionFeedback)
        .animation(.easeInOut(duration: motionPolicy.revealDuration), value: highlightsSuggestedTitle)
        .animation(.easeInOut(duration: motionPolicy.revealDuration), value: revealsContent)
    }

    private var statusColor: Color {
        switch section.statusTone {
        case .neutral: .secondary
        case .working: .blue
        case .success: .green
        case .warning: .orange
        }
    }

    private var motionPolicy: RecorderMotionPolicy {
        RecorderMotionPolicy.make(reduceMotion: reduceMotionOverride ?? reduceMotion)
    }

    @ViewBuilder
    private var completionCheck: some View {
        if motionPolicy.drawsCompletionStroke {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.drawOn, isActive: showsCompletionFeedback)
                .accessibilityIdentifier("meeting-intelligence.feedback.completion")
                .accessibilityValue("draw-on")
                .background(RecorderDestinationAccessibilityMarker(identifier: "meeting-intelligence.feedback.completion"))
                .background(RecorderDestinationAccessibilityMarker(identifier: "meeting-intelligence.feedback.completion.draw-on"))
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("meeting-intelligence.feedback.completion")
                .accessibilityValue("static")
                .background(RecorderDestinationAccessibilityMarker(identifier: "meeting-intelligence.feedback.completion"))
                .background(RecorderDestinationAccessibilityMarker(identifier: "meeting-intelligence.feedback.completion.static"))
        }
    }

    private func updateObservedFeedback(_ current: RecorderObservedSnapshot?) {
        defer { previousObservedSnapshot = current }
        resetObservedFeedback()
        guard let previous = previousObservedSnapshot, let current else {
            showsCompletionFeedback = false
            highlightsSuggestedTitle = false
            return
        }

        let feedback = RecorderObservedTransition.feedback(previous: previous, current: current)
        showsCompletionFeedback = feedback.completed
        highlightsSuggestedTitle = feedback.generatedTitleChanged
        if feedback.completed || feedback.generatedTitleChanged {
            let snapshot = current
            feedbackResetTask = Task {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled, previousObservedSnapshot == snapshot else { return }
                showsCompletionFeedback = false
                highlightsSuggestedTitle = false
            }
        }
    }

    private func resetObservedFeedback() {
        feedbackResetTask?.cancel()
        feedbackResetTask = nil
        showsCompletionFeedback = false
        highlightsSuggestedTitle = false
    }

    private func markedButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .accessibilityIdentifier(id)
            .background(RecorderDestinationAccessibilityMarker(identifier: id))
    }
}
