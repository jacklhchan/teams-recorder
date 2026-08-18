# Per-job Transcription and Floating Panel Collapse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-recording transcription sheet with one-attempt language and prompt options, and make both floating-panel eye controls collapse or expand the complete panel.

**Architecture:** A typed `TranscriptionRequestOptions` value overrides only language and prompt on one immutable provider snapshot; it is never persisted. Recordings owns a short-lived sheet draft and revalidates the session at submission. A shared `FloatingPanelPresentationState` and frame calculator drive two panel-specific renderers while preserving each controller's lifecycle.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPanel`, Combine, XCTest, Swift Package Manager.

## Global Constraints

- Supported transcription languages are exactly Cantonese (`yue`), English (`en`), and Mandarin (`zh`).
- Every sheet opens with Cantonese and a blank optional prompt; neither value is remembered.
- Provider Settings must not display or persist a universal ASR language or prompt after the next save.
- Per-job prompts stay in memory and must not enter UserDefaults, metadata, diagnostics, or artifact logs.
- Existing provider credentials, Privacy Mode, redirect policy, workspace fences, mutation gate, transcription publication, and single-job admission remain authoritative.
- Both floating panels start expanded for every new episode.
- Collapsed size is exactly `132 × 40`; collapsed content is exactly `Running` plus the eye control.
- Collapsed content has no red indicator, `Recording` text, timer, waveform, signal, microphone, screen, stop, countdown, or cancel control.
- Expanded content retains existing controls but uses `Running` as the recording-controller heading.
- Native minimize behavior remains unchanged.
- Use focused tests only; do not run the full test suite.
- Preserve the user's unrelated modified and untracked files.

---

## File Map

- Create `Sources/RecorderApp/Transcription/TranscriptionRequestOptions.swift`: typed language enum and immutable one-attempt options.
- Create `Sources/RecorderApp/Views/TranscriptionRequestSheet.swift`: draft state and modal sheet UI.
- Create `Sources/RecorderApp/Views/FloatingPanelCollapse.swift`: shared expanded/collapsed state, sizes, accessibility copy, and anchored-frame calculation.
- Modify `Sources/RecorderApp/Transcription/OpenAICompatibleProviderProfile.swift`: derive a validated profile with attempt-specific language/prompt.
- Modify `Sources/RecorderApp/Transcription/OpenAICompatibleProviderRepository.swift`: derive an immutable attempt snapshot without another credential read.
- Modify `Sources/RecorderApp/Transcription/TranscriptionFeatureModel.swift`: accept typed options.
- Modify `Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift`: apply options before starting the task.
- Modify `Sources/RecorderApp/AppModel.swift`: revalidate a session ID and dispatch typed options.
- Modify `Sources/RecorderApp/UI/RecordingsLibraryView.swift`: present, cancel, and submit the sheet.
- Modify `Sources/RecorderApp/Views/AIProviderSettingsView.swift`: remove universal ASR language/prompt controls.
- Modify `Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift`: save compatibility `yue` plus empty prompt.
- Modify `Sources/RecorderApp/UI/RecorderActionID.swift`: add sheet identifiers; retain old provider identifiers only for compatibility tests if referenced.
- Modify `Sources/RecorderApp/Views/RecordingControllerPanel.swift`: render and resize complete expanded/collapsed states.
- Modify `Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift`: render and resize complete expanded/collapsed states.
- Test only the directly corresponding files under `Tests/RecorderAppTests/`.

---

### Task 1: Typed Per-job Transcription Options

**Files:**
- Create: `Sources/RecorderApp/Transcription/TranscriptionRequestOptions.swift`
- Modify: `Sources/RecorderApp/Transcription/OpenAICompatibleProviderProfile.swift`
- Modify: `Sources/RecorderApp/Transcription/OpenAICompatibleProviderRepository.swift`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionFeatureModel.swift`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift`
- Test: `Tests/RecorderAppTests/OpenAICompatibleProviderRepositoryTests.swift`
- Test: `Tests/RecorderAppTests/TranscriptionJobCoordinatorTests.swift`

**Interfaces:**
- Produces: `MeetingLanguage`, `TranscriptionRequestOptions`, `OpenAICompatibleProviderProfile.applyingTranscriptionOptions(_:)`, `OpenAICompatibleProviderSnapshot.applyingTranscriptionOptions(_:)`.
- Produces: `TranscriptionFeatureModel.start(session:providerIsConfigured:options:)` and `TranscriptionJobCoordinator.start(session:options:)`.
- Consumes: the existing immutable repository snapshot, provider-profile validators, and coordinator task lifecycle.

- [ ] **Step 1: Write failing option and snapshot tests**

Add tests that demand the new types and prove the override is narrow:

```swift
func testTranscriptionRequestOptionsDefaultToCantoneseAndBlankPrompt() {
    let options = TranscriptionRequestOptions()
    XCTAssertEqual(options.language, .cantonese)
    XCTAssertEqual(options.prompt, "")
    XCTAssertEqual(MeetingLanguage.allCases.map(\.rawValue), ["yue", "en", "zh"])
}

func testAttemptOptionsReplaceOnlyLanguageAndPrompt() throws {
    let stored = try OpenAICompatibleProviderProfile.validated(
        baseURLText: "https://api.example.com/v1",
        asrModel: "asr", llmModel: "llm",
        language: "en", prompt: "stored universal",
        meetingIntelligencePrompt: "keep summary guidance"
    )
    let snapshot = try OpenAICompatibleProviderSnapshot.validated(
        profile: stored, apiKey: "secret"
    )
    let attempt = try snapshot.applyingTranscriptionOptions(
        .init(language: .mandarin, prompt: "  names: Alice  ")
    )

    XCTAssertEqual(attempt.profile.language, "zh")
    XCTAssertEqual(attempt.profile.prompt, "names: Alice")
    XCTAssertEqual(attempt.profile.baseURL, stored.baseURL)
    XCTAssertEqual(attempt.profile.asrModel, stored.asrModel)
    XCTAssertEqual(attempt.profile.llmModel, stored.llmModel)
    XCTAssertEqual(attempt.profile.meetingIntelligencePrompt, "keep summary guidance")
    XCTAssertEqual(attempt.apiKey, "secret")
}
```

- [ ] **Step 2: Run the RED tests**

Run:

```bash
swift test --disable-sandbox --filter 'OpenAICompatibleProviderRepositoryTests/testTranscriptionRequestOptionsDefaultToCantoneseAndBlankPrompt|OpenAICompatibleProviderRepositoryTests/testAttemptOptionsReplaceOnlyLanguageAndPrompt'
```

Expected: compile failure because `TranscriptionRequestOptions` and `applyingTranscriptionOptions` do not exist.

- [ ] **Step 3: Implement the typed value and immutable snapshot derivation**

Create the focused value:

```swift
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

struct TranscriptionRequestOptions: Equatable, Sendable {
    let language: MeetingLanguage
    let prompt: String

    init(language: MeetingLanguage = .cantonese, prompt: String = "") {
        self.language = language
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Move the existing `MeetingLanguage` declaration out of `AIProviderSettingsModel.swift`. Add `OpenAICompatibleProviderProfile.applyingTranscriptionOptions(_:)` using the existing `validated` or `hktValidated` factory according to `providerKind`, preserving all fields except language/prompt. Add this snapshot method inside the snapshot type:

```swift
func applyingTranscriptionOptions(
    _ options: TranscriptionRequestOptions
) throws -> Self {
    try .validated(
        profile: profile.applyingTranscriptionOptions(options),
        apiKey: apiKey
    )
}
```

- [ ] **Step 4: Add a coordinator RED test for the actual service request**

Extend the existing coordinator fixture/spies so the service records its last request, then add:

```swift
func testStartUsesPerJobOptionsInsteadOfStoredUniversalPrompt() async throws {
    let fixture = makeFixture(
        storedLanguage: "en",
        storedPrompt: "stored universal"
    )
    fixture.coordinator.start(
        session: fixture.session,
        options: .init(language: .cantonese, prompt: "  meeting names  ")
    )

    await fixture.service.waitForRequest()
    XCTAssertEqual(fixture.service.lastRequest?.snapshot.profile.language, "yue")
    XCTAssertEqual(fixture.service.lastRequest?.snapshot.profile.prompt, "meeting names")
}
```

- [ ] **Step 5: Run the coordinator RED test**

Run:

```bash
swift test --disable-sandbox --filter 'TranscriptionJobCoordinatorTests/testStartUsesPerJobOptionsInsteadOfStoredUniversalPrompt'
```

Expected: compile failure because the coordinator start signature does not accept options.

- [ ] **Step 6: Thread options through the existing feature boundary**

Change the feature and coordinator signatures without adding another task owner:

```swift
func start(
    session: RecordingSession,
    providerIsConfigured: Bool,
    options: TranscriptionRequestOptions
) {
    // Existing shutdown, Privacy Mode, and provider checks remain first.
    coordinator.start(session: session, options: options)
}
```

```swift
func start(session: RecordingSession, options: TranscriptionRequestOptions) {
    guard !isRunning else { /* existing status */ return }
    let snapshot: OpenAICompatibleProviderSnapshot
    do {
        snapshot = try providerRepository.snapshot()
            .applyingTranscriptionOptions(options)
    } catch {
        lastTranscriptionSessionID = session.id
        lastTranscriptionStatus = error.localizedDescription
        lastTranscriptionDidFail = true
        publishGlobalStatus(error.localizedDescription)
        return
    }
    generation &+= 1
    // Keep the remainder of the existing start body byte-for-byte equivalent.
}
```

Do not extract or refactor the existing attempt body. Change only the method signature and snapshot assignment, then leave generation values, statement order, task ownership, callbacks, mutation gate, and cleanup unchanged.

- [ ] **Step 7: Run the focused GREEN tests and commit**

Run:

```bash
swift test --disable-sandbox --filter 'OpenAICompatibleProviderRepositoryTests/testTranscriptionRequestOptions|OpenAICompatibleProviderRepositoryTests/testAttemptOptions|TranscriptionJobCoordinatorTests/testStartUsesPerJobOptions'
```

Expected: selected tests pass with zero failures.

Commit only Task 1 files:

```bash
git add Sources/RecorderApp/Transcription/TranscriptionRequestOptions.swift Sources/RecorderApp/Transcription/OpenAICompatibleProviderProfile.swift Sources/RecorderApp/Transcription/OpenAICompatibleProviderRepository.swift Sources/RecorderApp/Transcription/TranscriptionFeatureModel.swift Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift Tests/RecorderAppTests/OpenAICompatibleProviderRepositoryTests.swift Tests/RecorderAppTests/TranscriptionJobCoordinatorTests.swift
git commit -m "feat: add per-job transcription options"
```

---

### Task 2: Transcription Sheet and Provider Settings Cleanup

**Files:**
- Create: `Sources/RecorderApp/Views/TranscriptionRequestSheet.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/UI/RecordingsLibraryView.swift`
- Modify: `Sources/RecorderApp/Views/AIProviderSettingsView.swift`
- Modify: `Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift`
- Modify: `Sources/RecorderApp/UI/RecorderActionID.swift`
- Test: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`
- Test: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- Test: `Tests/RecorderAppTests/AIProviderSettingsModelTests.swift`
- Test: `Tests/RecorderAppTests/AIProviderSettingsRenderTests.swift`

**Interfaces:**
- Consumes: Task 1 `MeetingLanguage` and `TranscriptionRequestOptions`.
- Produces: `TranscriptionRequestDraft`, `TranscriptionRequestSheet`, and `AppModel.transcribe(sessionID:options:)`.
- Produces accessibility IDs: `transcriptionSheet`, `transcriptionLanguage`, `transcriptionPrompt`, `transcriptionCancel`, and `transcriptionSubmit`.

- [ ] **Step 1: Write model RED tests for canonical revalidation**

Use the existing AppModel transcription fixture and add:

```swift
func testPerJobTranscriptionRevalidatesCanonicalSessionAndForwardsOptions() {
    let fixture = makeFixtureWithConfiguredProvider()
    fixture.model.transcribe(
        sessionID: fixture.session.id,
        options: .init(language: .english, prompt: "speaker names")
    )
    XCTAssertEqual(fixture.coordinator.startedSessionID, fixture.session.id)
    XCTAssertEqual(fixture.coordinator.startedOptions,
                   .init(language: .english, prompt: "speaker names"))
}

func testPerJobTranscriptionRejectsRemovedSession() {
    let fixture = makeFixtureWithConfiguredProvider()
    fixture.removeCanonicalSession()
    fixture.model.transcribe(
        sessionID: fixture.session.id,
        options: .init(language: .english, prompt: "secret prompt")
    )
    XCTAssertNil(fixture.coordinator.startedSessionID)
    XCTAssertEqual(fixture.model.statusMessage,
                   "The recording is no longer available.")
}
```

- [ ] **Step 2: Run the AppModel RED tests**

Run:

```bash
swift test --disable-sandbox --filter 'AppModelTranscriptionTests/testPerJobTranscription'
```

Expected: compile failure because `transcribe(sessionID:options:)` and the option capture seam do not exist.

- [ ] **Step 3: Implement AppModel canonical submission**

Replace the direct session method used by Recordings with:

```swift
func transcribe(
    sessionID: RecordingSession.ID,
    options: TranscriptionRequestOptions
) {
    guard let session = libraryFeature.snapshot.sessions.first(where: {
        $0.id == sessionID
    }) else {
        statusMessage = "The recording is no longer available."
        return
    }
    transcriptionFeature.start(
        session: session,
        providerIsConfigured: aiProviderSettingsModel.hasSavedProfile,
        options: options
    )
}
```

Keep any internal compatibility overload only if an existing non-UI caller requires it; make it construct explicit default options rather than reading stored prompt values.

- [ ] **Step 4: Write sheet and Settings render RED tests**

Add one real SwiftUI host flow in `RecorderWorkspaceRenderTests`:

```swift
func testTranscribeMenuOpensPerJobSheetAndCancelDoesNotStart() throws {
    let host = makeRecordingsHostWithConfiguredProvider()
    try host.invokeMenuItem(title: "Transcribe")
    XCTAssertTrue(host.contains(RecorderActionID.transcriptionSheet))
    XCTAssertEqual(host.selectedValue(RecorderActionID.transcriptionLanguage), "yue")
    XCTAssertEqual(host.textValue(RecorderActionID.transcriptionPrompt), "")
    try host.click(RecorderActionID.transcriptionCancel)
    XCTAssertFalse(host.contains(RecorderActionID.transcriptionSheet))
    XCTAssertNil(host.model.transcribingSessionID)
}

func testTranscriptionSheetSubmitsSelectedLanguageAndPrompt() throws {
    let host = makeRecordingsHostWithConfiguredProvider()
    try host.invokeMenuItem(title: "Transcribe")
    try host.select(RecorderActionID.transcriptionLanguage, value: "en")
    try host.replaceTextEditor(RecorderActionID.transcriptionPrompt,
                               with: "  speaker names  ")
    try host.click(RecorderActionID.transcriptionSubmit)
    XCTAssertEqual(host.startedOptions,
                   .init(language: .english, prompt: "speaker names"))
    XCTAssertFalse(host.contains(RecorderActionID.transcriptionSheet))
}
```

Update the provider render test to require both old ASR controls to be absent while the meeting-intelligence prompt remains:

```swift
XCTAssertFalse(host.contains(RecorderActionID.providerLanguage))
XCTAssertFalse(host.contains(RecorderActionID.providerPrompt))
XCTAssertTrue(host.contains(RecorderActionID.providerMeetingIntelligencePrompt))
```

- [ ] **Step 5: Run the render RED tests**

Run:

```bash
swift test --disable-sandbox --filter 'RecorderWorkspaceRenderTests/testTranscrib|AIProviderSettingsRenderTests/testProviderSettingsHideUniversalASROptions'
```

Expected: failures because the current menu dispatches immediately and Provider Settings still renders both controls.

- [ ] **Step 6: Implement the sheet and short-lived draft**

Create:

```swift
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
```

`TranscriptionRequestSheet` uses a segmented or menu picker over `MeetingLanguage.allCases`, a multiline `TextEditor`, and Cancel/Transcribe buttons with the exact action IDs. In `SessionListView`, replace direct menu dispatch with `transcriptionDraft = .init(...)`, attach `.sheet(item:)`, clear the binding before calling `transcribe(sessionID:options:)`, and clear it on Cancel.

Use this concrete sheet structure:

```swift
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
            .accessibilityIdentifier(RecorderActionID.transcriptionLanguage)
            TextEditor(text: $draft.prompt)
                .accessibilityLabel("Prompt")
                .accessibilityIdentifier(RecorderActionID.transcriptionPrompt)
                .frame(minHeight: 96)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier(RecorderActionID.transcriptionCancel)
                Button("Transcribe") { submit(draft.options) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(RecorderActionID.transcriptionSubmit)
            }
        }
        .padding(18)
        .frame(width: 460)
        .accessibilityIdentifier(RecorderActionID.transcriptionSheet)
    }
}
```

Add the five exact string constants to `RecorderActionID` and its all-ID contract. The parent sheet closure must set `transcriptionDraft = nil` before calling AppModel so the prompt is released even if admission fails.

- [ ] **Step 7: Remove universal ASR controls and force compatibility values on save**

Remove only the ASR Language picker, ASR Prompt copy, and ASR Prompt editor from `AIProviderSettingsView`; keep the Meeting Intelligence Prompt. Change `draftProfile()` to pass:

```swift
language: MeetingLanguage.cantonese.rawValue,
prompt: "",
```

for both provider kinds. Add a model test that loads an older stored profile containing `en` and `stored universal`, calls `save()`, and asserts the saved profile contains `yue` and `""` while its meeting-intelligence prompt is unchanged.

- [ ] **Step 8: Run focused GREEN tests and commit**

Run:

```bash
swift test --disable-sandbox --filter 'AppModelTranscriptionTests/testPerJobTranscription|RecorderWorkspaceRenderTests/testTranscrib|AIProviderSettingsModelTests/testSaveClearsUniversalASR|AIProviderSettingsRenderTests/testProviderSettingsHideUniversalASROptions'
```

Expected: selected tests pass with zero failures.

Commit only Task 2 files:

```bash
git add Sources/RecorderApp/Views/TranscriptionRequestSheet.swift Sources/RecorderApp/AppModel.swift Sources/RecorderApp/UI/RecordingsLibraryView.swift Sources/RecorderApp/Views/AIProviderSettingsView.swift Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift Sources/RecorderApp/UI/RecorderActionID.swift Tests/RecorderAppTests/AppModelTranscriptionTests.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift Tests/RecorderAppTests/AIProviderSettingsModelTests.swift Tests/RecorderAppTests/AIProviderSettingsRenderTests.swift
git commit -m "feat: prompt for transcription options"
```

---

### Task 3: Shared Floating-panel Collapse and Recording Controller

**Files:**
- Create: `Sources/RecorderApp/Views/FloatingPanelCollapse.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Create: `Tests/RecorderAppTests/FloatingPanelCollapseTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingControllerPanelTests.swift`

**Interfaces:**
- Produces: `FloatingPanelPresentationState`, `FloatingPanelLayout.collapsedSize`, `FloatingPanelLayout.frame(preservingTopRightOf:targetSize:)`, and state-specific accessibility strings.
- Consumes: the existing recording panel presenter episode and the existing `RecordingControllerPanelContent` actions.

- [ ] **Step 1: Write shared-state and frame RED tests**

```swift
func testCollapsedFrameIs132By40AndPreservesTopRightAnchor() {
    let current = NSRect(x: 500, y: 400, width: 390, height: 180)
    let collapsed = FloatingPanelLayout.frame(
        preservingTopRightOf: current,
        targetSize: FloatingPanelLayout.collapsedSize
    )
    XCTAssertEqual(collapsed.size, .init(width: 132, height: 40))
    XCTAssertEqual(collapsed.maxX, current.maxX)
    XCTAssertEqual(collapsed.maxY, current.maxY)
}

func testCollapseAccessibilityCopyIsStateSpecific() {
    XCTAssertEqual(FloatingPanelPresentationState.expanded.toggleLabel,
                   "Collapse floating window")
    XCTAssertEqual(FloatingPanelPresentationState.expanded.accessibilityValue,
                   "Expanded")
    XCTAssertEqual(FloatingPanelPresentationState.collapsed.toggleLabel,
                   "Expand floating window")
    XCTAssertEqual(FloatingPanelPresentationState.collapsed.accessibilityValue,
                   "Collapsed")
}
```

- [ ] **Step 2: Run shared-state RED tests**

Run:

```bash
swift test --disable-sandbox --filter FloatingPanelCollapseTests
```

Expected: compile failure because the shared types do not exist.

- [ ] **Step 3: Implement the shared presentation value**

```swift
enum FloatingPanelPresentationState: Equatable {
    case expanded
    case collapsed

    var toggleLabel: String {
        self == .expanded ? "Collapse floating window" : "Expand floating window"
    }

    var accessibilityValue: String {
        self == .expanded ? "Expanded" : "Collapsed"
    }
}

enum FloatingPanelLayout {
    static let collapsedSize = NSSize(width: 132, height: 40)

    static func frame(
        preservingTopRightOf current: NSRect,
        targetSize: NSSize
    ) -> NSRect {
        NSRect(
            x: current.maxX - targetSize.width,
            y: current.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }
}
```

- [ ] **Step 4: Write recording-controller render RED tests**

Add a small real SwiftUI host around `RecordingControllerPanelContent` and assert:

```swift
func testRecordingControllerCollapsedShowsOnlyRunningAndEye() throws {
    let host = makeRecordingControllerHost(state: .collapsed)
    XCTAssertTrue(host.contains(RecordingControllerAccessibility.runningID))
    XCTAssertTrue(host.contains(RecordingControllerAccessibility.panelToggleID))
    for hidden in [
        RecordingControllerAccessibility.recordingIndicatorID,
        RecordingControllerAccessibility.elapsedID,
        RecordingControllerAccessibility.systemWaveformID,
        RecordingControllerAccessibility.microphoneWaveformID,
        RecordingControllerAccessibility.microphoneMuteID,
        RecordingControllerAccessibility.screenToggleID,
        RecordingControllerAccessibility.stopID,
    ] { XCTAssertFalse(host.contains(hidden), hidden) }
}
```

Add a panel test that calls the presentation resize seam twice and checks `390 × 180 → 132 × 40 → 390 × 180`, stable maxX/maxY, and a new presenter episode beginning expanded.

- [ ] **Step 5: Run recording-controller RED tests**

Run:

```bash
swift test --disable-sandbox --filter 'RecordingControllerPanelTests/testRecordingControllerCollapsed|RecordingControllerPanelTests/testRecordingControllerCollapseRoundTrip'
```

Expected: failures because the current eye only removes the red indicator and never resizes.

- [ ] **Step 6: Implement complete recording-controller collapse**

Replace `showsRecordingIndicator` with `FloatingPanelPresentationState`. Use an explicit branch so hidden controls are absent from the SwiftUI tree:

```swift
@ViewBuilder
var body: some View {
    if panelState == .collapsed {
        HStack(spacing: 10) {
            Text("Running")
                .accessibilityIdentifier(
                    RecordingControllerAccessibility.runningID
                )
            floatingPanelToggleButton
        }
        .padding(.horizontal, 12)
        .frame(width: 132, height: 40)
        .recorderGlassSurface(.navigation)
    } else {
        expandedContent // existing controls; heading text becomes "Running"
            .frame(width: 390, height: 180)
    }
}
```

The eye button uses `panelState.toggleLabel` and `panelState.accessibilityValue`. The presenter passes a state-change closure that applies:

```swift
func setPresentation(_ state: FloatingPanelPresentationState) {
    let target = state == .expanded
        ? NSSize(width: 390, height: 180)
        : FloatingPanelLayout.collapsedSize
    setFrame(
        FloatingPanelLayout.frame(
            preservingTopRightOf: frame,
            targetSize: target
        ),
        display: true
    )
}
```

Create a fresh hosting view in every `present(model:)`, apply `.expanded` before positioning, and set `hostingView = nil` plus `panel.contentView = nil` in `dismiss()` so a later episode cannot inherit collapsed state.

- [ ] **Step 7: Run Task 3 GREEN tests and commit**

Run:

```bash
swift test --disable-sandbox --filter 'FloatingPanelCollapseTests|RecordingControllerPanelTests'
```

Expected: selected tests pass with zero failures.

Commit only Task 3 files:

```bash
git add Sources/RecorderApp/Views/FloatingPanelCollapse.swift Sources/RecorderApp/Views/RecordingControllerPanel.swift Tests/RecorderAppTests/FloatingPanelCollapseTests.swift Tests/RecorderAppTests/RecordingControllerPanelTests.swift
git commit -m "feat: collapse recording floating panel"
```

---

### Task 4: Teams Countdown Collapse and Final Verification

**Files:**
- Modify: `Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift`
- Modify: `Tests/RecorderAppTests/TeamsAutoMeetingCountdownRenderTests.swift`
- Modify: `Tests/RecorderAppTests/TeamsAutoMeetingPresentationTests.swift`

**Interfaces:**
- Consumes: Task 3 `FloatingPanelPresentationState` and `FloatingPanelLayout`.
- Produces: a countdown controller whose per-episode state starts expanded, survives countdown ticks, and toggles a complete collapsed view.

- [ ] **Step 1: Replace the old red-bubble test with complete-collapse RED tests**

```swift
func testCountdownEyeCollapsesAllInformationAndExpandsItAgain() throws {
    let host = CountdownRenderHost(rootView: CountdownCollapseHarness())
    XCTAssertTrue(host.contains(TeamsAutoMeetingCountdownAccessibility.secondsID))
    try host.click(TeamsAutoMeetingCountdownAccessibility.panelToggleID)
    XCTAssertTrue(host.contains(TeamsAutoMeetingCountdownAccessibility.runningID))
    XCTAssertTrue(host.contains(TeamsAutoMeetingCountdownAccessibility.panelToggleID))
    XCTAssertFalse(host.contains(TeamsAutoMeetingCountdownAccessibility.recordingIndicatorID))
    XCTAssertFalse(host.contains(TeamsAutoMeetingCountdownAccessibility.secondsID))
    XCTAssertFalse(host.contains(TeamsAutoMeetingCountdownAccessibility.cancelID))
    XCTAssertEqual(host.frame.size, .init(width: 132, height: 40))
    try host.click(TeamsAutoMeetingCountdownAccessibility.panelToggleID)
    XCTAssertTrue(host.contains(TeamsAutoMeetingCountdownAccessibility.secondsID))
    XCTAssertTrue(host.contains(TeamsAutoMeetingCountdownAccessibility.cancelID))
    XCTAssertEqual(host.frame.size, .init(width: 360, height: 94))
}
```

Add a controller test proving `present(seconds:)` ticks do not expand a collapsed episode, while `dismiss()` followed by the next `present` starts expanded.

- [ ] **Step 2: Run Teams RED tests**

Run:

```bash
swift test --disable-sandbox --filter 'TeamsAutoMeetingCountdownRenderTests/testCountdownEyeCollapses|TeamsAutoMeetingPresentationTests/testCountdownCollapsePersistsWithinEpisodeAndResetsForNext'
```

Expected: failures because the current view keeps countdown/cancel visible and has fixed `360 × 94` bounds.

- [ ] **Step 3: Implement countdown controller and view state**

Replace `showsRecordingIndicator` with a controller-owned `FloatingPanelPresentationState`. Reset it only when `episode.present(cancel:)` returns `true`; keep it across subsequent countdown ticks:

```swift
func present(seconds: Int, cancel: @escaping @MainActor () -> Void) {
    let isNewEpisode = episode.present(cancel: cancel)
    if isNewEpisode { panelState = .expanded }
    render(seconds: seconds)
    applyPanelState()
    if isNewEpisode {
        positionPanel()
        panel.orderFrontRegardless()
    }
}

private func togglePanelState(seconds: Int) {
    panelState = panelState == .expanded ? .collapsed : .expanded
    render(seconds: seconds)
    applyPanelState()
}
```

Render with an explicit branch:

```swift
if panelState == .collapsed {
    HStack(spacing: 10) {
        Text("Running")
            .accessibilityIdentifier(
                TeamsAutoMeetingCountdownAccessibility.runningID
            )
        floatingPanelToggleButton
    }
    .padding(.horizontal, 12)
    .frame(width: 132, height: 40)
} else {
    expandedCountdownContent
        .frame(width: 360, height: 94)
}
```

`applyPanelState()` selects `360 × 94` or the shared collapsed size and calls the same top-right-preserving frame calculator. `dismiss()` resets the episode and state after ordering the panel out.

- [ ] **Step 4: Run the bounded feature verification**

Run exactly these focused suites:

```bash
swift test --disable-sandbox --filter 'OpenAICompatibleProviderRepositoryTests|TranscriptionJobCoordinatorTests|AppModelTranscriptionTests|AIProviderSettingsModelTests|AIProviderSettingsRenderTests|RecorderWorkspaceRenderTests/testTranscrib|FloatingPanelCollapseTests|RecordingControllerPanelTests|TeamsAutoMeetingCountdownRenderTests|TeamsAutoMeetingPresentationTests'
```

Expected: selected tests pass with zero failures. Do not expand to the full suite.

Run one production compile:

```bash
swift build --disable-sandbox -c release
```

Expected: `Build complete!` and exit code 0. Pre-existing deprecation or Swift 6 warnings may be recorded but must not be described as new clean output.

- [ ] **Step 5: Review scope and commit**

Run:

```bash
git diff --check
git status --short
```

Confirm only Task 4 files plus preserved pre-existing user dirt remain. Commit only Task 4 files:

```bash
git add Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift Tests/RecorderAppTests/TeamsAutoMeetingCountdownRenderTests.swift Tests/RecorderAppTests/TeamsAutoMeetingPresentationTests.swift
git commit -m "feat: collapse Teams countdown panel"
```

After the commit, report the focused test totals, production build result, exact commits, and any pre-existing unrelated failures or warnings without claiming a full-suite pass.
