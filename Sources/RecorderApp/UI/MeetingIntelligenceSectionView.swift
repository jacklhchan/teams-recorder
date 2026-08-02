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
    let showsEdit: Bool
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
        let showsEdit: Bool
        switch presentation.phase {
        case .ready, .stale:
            showsEdit = presentation.editableContent.map {
                MeetingIntelligenceArtifactValidator.isValid($0.artifact)
            } ?? false
        case .notGenerated, .checkingAvailability, .generating, .failed, .cancelled, .interrupted:
            showsEdit = false
        }
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
            showsEdit: showsEdit,
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
    var saveEdit: (
        MeetingIntelligenceArtifact,
        String,
        String
    ) async -> MeetingIntelligenceEditSaveOutcome = { _, _, _ in
        .failed("Meeting intelligence edits are unavailable.")
    }
}

struct MeetingIntelligenceSectionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.meetingIntelligenceReduceMotionOverride) private var reduceMotionOverride
    let presentation: MeetingIntelligencePresentation
    let section: MeetingIntelligenceSectionPresentation
    let actions: MeetingIntelligenceActions
    private let palette: TranscriptDetailPalette
    private let observedSnapshot: RecorderObservedSnapshot?
    @State private var previousObservedSnapshot: RecorderObservedSnapshot?
    @State private var showsCompletionFeedback = false
    @State private var highlightsSuggestedTitle = false
    @State private var feedbackResetTask: Task<Void, Never>?
    @State private var revealsContent = false
    @State private var isEditing = false
    @State private var summaryDraft = ""
    @State private var suggestedTitleDraft = ""
    @State private var capturedArtifact: MeetingIntelligenceArtifact?
    @State private var capturedSessionIdentity: MeetingIntelligenceSessionPresentationIdentity?
    @State private var saveAttemptID: UUID?
    @State private var pendingSavedArtifact: MeetingIntelligenceArtifact?
    @State private var editStatus: String?
    @State private var requiresFreshEdit = false
    @State private var editResponseOwner = UUID()

    init(
        presentation: MeetingIntelligencePresentation,
        observedSnapshot: RecorderObservedSnapshot? = nil,
        actions: MeetingIntelligenceActions = .init(),
        palette: TranscriptDetailPalette = .light
    ) {
        self.presentation = presentation
        self.section = .make(presentation: presentation)
        self.observedSnapshot = observedSnapshot
        self.actions = actions
        self.palette = palette
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

            if isEditing {
                editFields
                editControls
            } else {
                readOnlyContent
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
                            if section.showsEdit {
                                markedButton("Edit", id: RecorderActionID.meetingIntelligenceEdit, action: beginEditing)
                            }
                        case let .recovery(checkAgain, applySuggestedTitle):
                            if checkAgain { markedButton("Check Again", id: RecorderActionID.meetingIntelligenceCheckAgain, action: actions.checkAgain) }
                            markedButton("Retry Generation", id: RecorderActionID.meetingIntelligenceRetryGeneration, action: actions.retryGeneration)
                            if applySuggestedTitle { markedButton("Apply Suggested Title", id: RecorderActionID.meetingIntelligenceApplyTitle, action: actions.applySuggestedTitle) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.hairline))
        .accessibilityIdentifier(RecorderActionID.meetingIntelligenceCard)
        .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceCard))
        .onAppear {
            resetObservedFeedback()
            previousObservedSnapshot = observedSnapshot
            revealsContent = true
            reconcileEditProjection(presentation)
        }
        .onChange(of: presentation) { _, current in
            reconcileEditProjection(current)
        }
        .onChange(of: observedSnapshot) { _, current in
            updateObservedFeedback(current)
            reconcileEditSession(current)
        }
        .onDisappear {
            resetObservedFeedback()
            editResponseOwner = UUID()
        }
        .animation(.easeInOut(duration: motionPolicy.revealDuration), value: showsCompletionFeedback)
        .animation(.easeInOut(duration: motionPolicy.revealDuration), value: highlightsSuggestedTitle)
        .animation(.easeInOut(duration: motionPolicy.revealDuration), value: revealsContent)
    }

    @ViewBuilder
    private var readOnlyContent: some View {
        if let summary = section.summary, !summary.isEmpty {
            Text(summary)
                .font(.callout)
                .foregroundStyle(palette.text)
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
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle)
                    .accessibilityLabel(title)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.meetingIntelligenceSuggestedTitle,
                            label: title
                        )
                    )
                    .contentTransition(.opacity)
            }
            .opacity(revealsContent ? 1 : 0)
            .offset(y: revealsContent ? 0 : motionPolicy.revealOffset)
            .transition(.opacity.combined(with: .offset(y: motionPolicy.revealOffset)))
            .animation(.easeInOut(duration: motionPolicy.revealDuration), value: section.suggestedTitle)
            if section.showsManualTitleProtection {
                Text(section.manualTitleProtectionCopy)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .accessibilityLabel(section.manualTitleProtectionAccessibilityLabel)
                    .accessibilityIdentifier(RecorderActionID.meetingIntelligenceManualTitleProtection)
                    .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceManualTitleProtection))
            }
        }
    }

    private var editFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondary)
                .accessibilityLabel("Summary")
            TextEditor(text: $summaryDraft)
                .font(.callout)
                .frame(minHeight: 96, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(palette.editor, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.hairline))
                .accessibilityIdentifier(RecorderActionID.meetingIntelligenceEditSummary)
                .accessibilityLabel("Summary")
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: RecorderActionID.meetingIntelligenceEditSummary,
                        label: "Summary"
                    )
                )

            Text("Suggested title")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondary)
                .accessibilityLabel("Suggested title")
            TextField("Suggested title", text: $suggestedTitleDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(RecorderActionID.meetingIntelligenceEditSuggestedTitle)
                .accessibilityLabel("Suggested title")
                .background(
                    RecorderDestinationAccessibilityMarker(
                        identifier: RecorderActionID.meetingIntelligenceEditSuggestedTitle,
                        label: "Suggested title"
                    )
                )

            if section.showsManualTitleProtection {
                Text(section.manualTitleProtectionCopy)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .accessibilityLabel(section.manualTitleProtectionAccessibilityLabel)
                    .accessibilityIdentifier(RecorderActionID.meetingIntelligenceManualTitleProtection)
                    .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceManualTitleProtection))
            }

            if let editStatus {
                Text(editStatus)
                    .font(.caption)
                    .foregroundStyle(editStatusColor)
                    .accessibilityIdentifier(RecorderActionID.meetingIntelligenceEditStatus)
                    .accessibilityLabel(editStatus)
                    .background(
                        RecorderDestinationAccessibilityMarker(
                            identifier: RecorderActionID.meetingIntelligenceEditStatus,
                            label: editStatus
                        )
                    )
            }
        }
    }

    private var editControls: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: cancelEditing)
                .disabled(isSaving)
                .accessibilityIdentifier(RecorderActionID.meetingIntelligenceEditCancel)
                .accessibilityLabel("Cancel meeting intelligence edit")
                .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceEditCancel, label: "Cancel meeting intelligence edit"))
            Button("Save", action: submitEdit)
                .disabled(isSaveDisabled)
                .accessibilityIdentifier(RecorderActionID.meetingIntelligenceEditSave)
                .accessibilityLabel(isSaving ? "Save meeting intelligence edit, saving" : "Save meeting intelligence edit")
                .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceEditSave, label: "Save meeting intelligence edit"))
        }
        .buttonStyle(.bordered)
    }

    private var isSaving: Bool { saveAttemptID != nil }

    private var isSaveDisabled: Bool {
        isSaving || pendingSavedArtifact != nil || requiresFreshEdit
    }

    private var editStatusColor: Color {
        isSaving ? .blue : .orange
    }

    private func beginEditing() {
        guard section.showsEdit,
              !isEditing,
              let artifact = presentation.editableContent?.artifact,
              MeetingIntelligenceArtifactValidator.isValid(artifact)
        else { return }

        capturedArtifact = artifact
        capturedSessionIdentity = observedSnapshot?.identity
        summaryDraft = section.summary ?? artifact.summary
        suggestedTitleDraft = section.suggestedTitle ?? artifact.suggestedTitle
        pendingSavedArtifact = nil
        editStatus = nil
        requiresFreshEdit = false
        editResponseOwner = UUID()
        isEditing = true
    }

    private func cancelEditing() {
        guard !isSaving else { return }
        editResponseOwner = UUID()
        isEditing = false
        summaryDraft = ""
        suggestedTitleDraft = ""
        capturedArtifact = nil
        capturedSessionIdentity = nil
        pendingSavedArtifact = nil
        editStatus = nil
        requiresFreshEdit = false
    }

    private func submitEdit() {
        guard isEditing,
              !isSaveDisabled,
              let artifact = capturedArtifact,
              MeetingIntelligenceArtifactValidator.isValid(artifact)
        else { return }

        guard MeetingIntelligenceArtifactValidator.summary(summaryDraft) != nil else {
            editStatus = "Enter a valid summary before saving."
            return
        }
        guard MeetingIntelligenceArtifactValidator.title(suggestedTitleDraft) != nil else {
            editStatus = "Enter a valid suggested title before saving."
            return
        }

        let attempt = UUID()
        let owner = editResponseOwner
        let summary = summaryDraft
        let suggestedTitle = suggestedTitleDraft
        let saveEdit = actions.saveEdit
        saveAttemptID = attempt
        editStatus = "Saving…"

        // This is intentionally an unstructured task.  The durable action may
        // outlive this view; response ownership below decides whether its
        // result may update local UI state, without cancelling the command.
        Task { @MainActor in
            let outcome = await saveEdit(artifact, summary, suggestedTitle)
            guard saveAttemptID == attempt else { return }
            saveAttemptID = nil
            guard editResponseOwner == owner else { return }
            handleEditSaveOutcome(outcome)
        }
    }

    private func handleEditSaveOutcome(_ outcome: MeetingIntelligenceEditSaveOutcome) {
        switch outcome {
        case let .saved(artifact):
            guard MeetingIntelligenceArtifactValidator.isValid(artifact) else {
                editStatus = "The saved meeting intelligence content was invalid. Your draft is still here."
                return
            }
            pendingSavedArtifact = artifact
            editStatus = "Saved. Waiting for updated meeting intelligence content."
            if isAcceptedProjection(artifact, in: presentation) {
                finishEditing()
            }
        case .invalidSummary:
            editStatus = "Enter a valid summary before saving."
        case .invalidSuggestedTitle:
            editStatus = "Enter a valid suggested title before saving."
        case .conflict:
            markConflict()
        case .failed:
            editStatus = "Could not save the edits. Your draft is still here. Try again."
        }
    }

    private func reconcileEditProjection(_ current: MeetingIntelligencePresentation) {
        guard isEditing else { return }

        if let pendingSavedArtifact,
           isAcceptedProjection(pendingSavedArtifact, in: current) {
            finishEditing()
            return
        }

        guard !requiresFreshEdit, let capturedArtifact else { return }
        guard current.phase == .ready || current.phase == .stale else {
            markConflict()
            return
        }
        guard current.editableContent?.artifact == capturedArtifact else {
            markConflict()
            return
        }
    }

    private func reconcileEditSession(_ current: RecorderObservedSnapshot?) {
        guard isEditing, !requiresFreshEdit,
              let capturedSessionIdentity,
              current?.identity != capturedSessionIdentity
        else { return }
        markConflict()
    }

    private func markConflict() {
        guard isEditing, !requiresFreshEdit else { return }
        // Dropping only the local attempt handle makes any late response a
        // no-op while the unstructured durable task is allowed to finish.
        saveAttemptID = nil
        editResponseOwner = UUID()
        pendingSavedArtifact = nil
        requiresFreshEdit = true
        editStatus = "This meeting intelligence content changed elsewhere. Review the latest content before trying again."
    }

    private func isAcceptedProjection(
        _ artifact: MeetingIntelligenceArtifact,
        in current: MeetingIntelligencePresentation
    ) -> Bool {
        guard current.phase == .ready || current.phase == .stale,
              current.editableContent?.artifact == artifact,
              current.summary == artifact.summary,
              current.suggestedTitle == artifact.suggestedTitle
        else { return false }
        return true
    }

    private func finishEditing() {
        editResponseOwner = UUID()
        isEditing = false
        summaryDraft = ""
        suggestedTitleDraft = ""
        capturedArtifact = nil
        capturedSessionIdentity = nil
        saveAttemptID = nil
        pendingSavedArtifact = nil
        editStatus = nil
        requiresFreshEdit = false
    }

    private var statusColor: Color {
        switch section.statusTone {
        case .neutral: palette.secondary
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
