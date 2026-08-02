import Combine
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

/// Owns the edit attempt lifecycle independently from SwiftUI rendering.
/// Every save response must still belong to the active attempt and the
/// canonical projection before the editor can leave edit mode.
@MainActor
final class MeetingIntelligenceEditController: ObservableObject {
    struct Submission: Equatable, Sendable {
        let attemptID: UUID
        let artifact: MeetingIntelligenceArtifact
        let summary: String
        let suggestedTitle: String
    }

    @Published private(set) var isEditing = false
    @Published private(set) var isSaving = false
    @Published private(set) var draftSummary = ""
    @Published private(set) var draftSuggestedTitle = ""
    @Published private(set) var editStatus: String?

    private var capturedArtifact: MeetingIntelligenceArtifact?
    private var capturedPhase: MeetingIntelligencePresentation.Phase?
    private var capturedIdentity: MeetingIntelligenceSessionPresentationIdentity?
    private var observedProjection: MeetingIntelligencePresentation?
    private var observedIdentity: MeetingIntelligenceSessionPresentationIdentity?
    private var activeAttemptID: UUID?
    private var pendingSavedArtifact: MeetingIntelligenceArtifact?
    private var conflictArtifact: MeetingIntelligenceArtifact?
    private var conflictPhase: MeetingIntelligencePresentation.Phase?
    private var conflictIdentity: MeetingIntelligenceSessionPresentationIdentity?
    private var requiresFreshEdit = false

    private static let conflictReloadingStatus = "Edit conflict: content changed. Reloading canonical content…"
    private static let conflictLoadedStatus = "Edit conflict: latest content loaded."

    var isDirty: Bool {
        guard let capturedArtifact else { return false }
        return draftSummary != capturedArtifact.summary ||
            draftSuggestedTitle != capturedArtifact.suggestedTitle
    }

    var isIdentityMismatch: Bool {
        guard let capturedIdentity else { return false }
        return observedIdentity != capturedIdentity
    }

    var isSaveDisabled: Bool {
        guard isEditing, capturedArtifact != nil else { return true }
        return isSaving ||
            pendingSavedArtifact != nil ||
            requiresFreshEdit ||
            isIdentityMismatch ||
            !currentProjectionMatchesCapture ||
            !isDirty
    }

    func begin(
        projection: MeetingIntelligencePresentation,
        identity: MeetingIntelligenceSessionPresentationIdentity?
    ) {
        guard !isEditing,
              projection.phase == .ready || projection.phase == .stale,
              let artifact = projection.editableContent?.artifact,
              MeetingIntelligenceArtifactValidator.isValid(artifact)
        else { return }

        observedProjection = projection
        observedIdentity = identity
        capturedArtifact = artifact
        capturedPhase = projection.phase
        capturedIdentity = identity
        draftSummary = projection.summary ?? artifact.summary
        draftSuggestedTitle = projection.suggestedTitle ?? artifact.suggestedTitle
        activeAttemptID = nil
        pendingSavedArtifact = nil
        clearConflictState()
        requiresFreshEdit = false
        editStatus = nil
        isSaving = false
        isEditing = true
    }

    func edit(summary: String, suggestedTitle: String) {
        guard isEditing, !isSaving, pendingSavedArtifact == nil, !requiresFreshEdit else { return }
        draftSummary = summary
        draftSuggestedTitle = suggestedTitle
        editStatus = nil
    }

    func submit() -> Submission? {
        guard isEditing,
              !isSaveDisabled,
              let artifact = capturedArtifact,
              MeetingIntelligenceArtifactValidator.isValid(artifact)
        else { return nil }

        guard MeetingIntelligenceArtifactValidator.summary(draftSummary) != nil else {
            editStatus = "Enter a valid summary before saving."
            return nil
        }
        guard MeetingIntelligenceArtifactValidator.title(draftSuggestedTitle) != nil else {
            editStatus = "Enter a valid suggested title before saving."
            return nil
        }

        let submission = Submission(
            attemptID: UUID(),
            artifact: artifact,
            summary: draftSummary,
            suggestedTitle: draftSuggestedTitle
        )
        activeAttemptID = submission.attemptID
        isSaving = true
        editStatus = "Saving…"
        return submission
    }

    func cancel() {
        guard isEditing, !isSaving else { return }
        invalidateEdit()
    }

    func receiveOutcome(_ outcome: MeetingIntelligenceEditSaveOutcome, for attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        isSaving = false
        guard isEditing else { return }

        switch outcome {
        case let .saved(artifact):
            guard MeetingIntelligenceArtifactValidator.isValid(artifact) else {
                editStatus = "The saved meeting intelligence content was invalid. Your draft is still here."
                return
            }
            pendingSavedArtifact = artifact
            editStatus = "Saved. Waiting for updated meeting intelligence content."
            if let observedProjection,
               !isIdentityMismatch,
               isAcceptedProjection(artifact, in: observedProjection) {
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

    func observeProjection(
        _ projection: MeetingIntelligencePresentation,
        identity: MeetingIntelligenceSessionPresentationIdentity?
    ) {
        observedProjection = projection
        observedIdentity = identity

        if conflictArtifact != nil {
            guard identity == conflictIdentity else {
                invalidateEdit()
                return
            }

            if conflictProjectionMatchesSource(projection) {
                editStatus = Self.conflictReloadingStatus
            } else {
                clearConflictState()
                requiresFreshEdit = false
                editStatus = Self.conflictLoadedStatus
            }
            return
        }

        guard isEditing else { return }

        guard !isIdentityMismatch else {
            invalidateEdit()
            return
        }

        if let pendingSavedArtifact,
           isAcceptedProjection(pendingSavedArtifact, in: projection) {
            finishEditing()
            return
        }

        guard let capturedArtifact,
              let capturedPhase,
              projection.phase == capturedPhase,
              projection.editableContent?.artifact == capturedArtifact,
              projection.summary == capturedArtifact.summary,
              projection.suggestedTitle == capturedArtifact.suggestedTitle
        else {
            markConflict(observedProjection: projection, observedIdentity: identity)
            return
        }
    }

    func disappear() {
        invalidateEdit()
        observedProjection = nil
        observedIdentity = nil
    }

    private var currentProjectionMatchesCapture: Bool {
        guard let observedProjection, let capturedArtifact, let capturedPhase else { return false }
        guard !isIdentityMismatch,
              observedProjection.phase == capturedPhase,
              observedProjection.editableContent?.artifact == capturedArtifact,
              observedProjection.summary == capturedArtifact.summary,
              observedProjection.suggestedTitle == capturedArtifact.suggestedTitle
        else { return false }
        return true
    }

    private func isAcceptedProjection(
        _ artifact: MeetingIntelligenceArtifact,
        in projection: MeetingIntelligencePresentation
    ) -> Bool {
        (projection.phase == .ready || projection.phase == .stale) &&
            projection.editableContent?.artifact == artifact &&
            projection.summary == artifact.summary &&
            projection.suggestedTitle == artifact.suggestedTitle
    }

    private func markConflict(
        observedProjection: MeetingIntelligencePresentation? = nil,
        observedIdentity: MeetingIntelligenceSessionPresentationIdentity? = nil
    ) {
        guard isEditing else { return }

        let sourceArtifact = capturedArtifact
        let sourcePhase = capturedPhase
        let sourceIdentity = capturedIdentity

        activeAttemptID = nil
        isSaving = false
        pendingSavedArtifact = nil
        isEditing = false
        draftSummary = ""
        draftSuggestedTitle = ""
        capturedArtifact = nil
        capturedPhase = nil
        capturedIdentity = nil

        guard let sourceArtifact, let sourcePhase else {
            clearConflictState()
            requiresFreshEdit = false
            editStatus = Self.conflictReloadingStatus
            return
        }

        conflictArtifact = sourceArtifact
        conflictPhase = sourcePhase
        conflictIdentity = sourceIdentity
        requiresFreshEdit = true

        if let observedProjection,
           observedIdentity == sourceIdentity,
           !conflictProjectionMatchesSource(observedProjection) {
            clearConflictState()
            requiresFreshEdit = false
            editStatus = Self.conflictLoadedStatus
        } else {
            editStatus = Self.conflictReloadingStatus
        }
    }

    private func conflictProjectionMatchesSource(_ projection: MeetingIntelligencePresentation) -> Bool {
        guard let conflictArtifact,
              let conflictPhase,
              projection.phase == conflictPhase,
              projection.editableContent?.artifact == conflictArtifact,
              projection.summary == conflictArtifact.summary,
              projection.suggestedTitle == conflictArtifact.suggestedTitle
        else { return false }
        return true
    }

    private func clearConflictState() {
        conflictArtifact = nil
        conflictPhase = nil
        conflictIdentity = nil
    }

    private func finishEditing() {
        invalidateEdit()
    }

    private func invalidateEdit() {
        activeAttemptID = nil
        isSaving = false
        isEditing = false
        draftSummary = ""
        draftSuggestedTitle = ""
        capturedArtifact = nil
        capturedPhase = nil
        capturedIdentity = nil
        pendingSavedArtifact = nil
        clearConflictState()
        requiresFreshEdit = false
        editStatus = nil
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
    @StateObject private var editController: MeetingIntelligenceEditController
    @State private var previousObservedSnapshot: RecorderObservedSnapshot?
    @State private var showsCompletionFeedback = false
    @State private var highlightsSuggestedTitle = false
    @State private var feedbackResetTask: Task<Void, Never>?
    @State private var revealsContent = false

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
        _editController = StateObject(wrappedValue: MeetingIntelligenceEditController())
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

            if editController.isEditing {
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
            editController.observeProjection(presentation, identity: observedSnapshot?.identity)
        }
        .onChange(of: presentation) { _, current in
            editController.observeProjection(current, identity: observedSnapshot?.identity)
        }
        .onChange(of: observedSnapshot) { _, current in
            updateObservedFeedback(current)
            editController.observeProjection(presentation, identity: current?.identity)
        }
        .onDisappear {
            resetObservedFeedback()
            editController.disappear()
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
        if let editStatus = editController.editStatus, !editController.isEditing {
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

    private var editFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondary)
                .accessibilityLabel("Summary")
            TextEditor(
                text: Binding(
                    get: { editController.draftSummary },
                    set: { editController.edit(summary: $0, suggestedTitle: editController.draftSuggestedTitle) }
                )
            )
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
            TextField(
                "Suggested title",
                text: Binding(
                    get: { editController.draftSuggestedTitle },
                    set: { editController.edit(summary: editController.draftSummary, suggestedTitle: $0) }
                )
            )
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

            if let editStatus = editController.editStatus {
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
                .disabled(editController.isSaving)
                .accessibilityIdentifier(RecorderActionID.meetingIntelligenceEditCancel)
                .accessibilityLabel("Cancel meeting intelligence edit")
                .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceEditCancel, label: "Cancel meeting intelligence edit"))
            Button("Save", action: submitEdit)
                .disabled(editController.isSaveDisabled)
                .accessibilityIdentifier(RecorderActionID.meetingIntelligenceEditSave)
                .accessibilityLabel(editController.isSaving ? "Save meeting intelligence edit, saving" : "Save meeting intelligence edit")
                .background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.meetingIntelligenceEditSave, label: "Save meeting intelligence edit"))
        }
        .buttonStyle(.bordered)
    }

    private var editStatusColor: Color {
        editController.isSaving ? .blue : .orange
    }

    private func beginEditing() {
        guard section.showsEdit else { return }
        editController.begin(projection: presentation, identity: observedSnapshot?.identity)
    }

    private func cancelEditing() {
        editController.cancel()
    }

    private func submitEdit() {
        guard let submission = editController.submit() else { return }
        let controller = editController
        let saveEdit = actions.saveEdit

        Task { @MainActor in
            let outcome = await saveEdit(
                submission.artifact,
                submission.summary,
                submission.suggestedTitle
            )
            controller.receiveOutcome(outcome, for: submission.attemptID)
        }
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
