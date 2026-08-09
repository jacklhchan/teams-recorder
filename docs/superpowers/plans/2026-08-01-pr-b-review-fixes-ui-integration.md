# PR B Review Fixes and UI Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to implement this plan task by
> task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the approved Liquid Glass/motion UI into Draft PR #8,
close the four requested PR B review findings, and add the bounded sanitized
troubleshooting diagnostic explicitly requested by the user.

**Architecture:** `AppModel` remains PR B's temporary composition adapter for
Library, Transcription, Meeting Intelligence, and Playback. SwiftUI consumes
immutable feature snapshots without mirrored domain state. Settings, ASR, and
MI share one provider repository; all session mutations share one gate.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Combine, XCTest, macOS 26+, current
script/packaging/VirtualMic gates.

## Global Constraints

- Keep PR #8 Draft. Do not merge, mark Ready, start PR C, or modify Windows.
- Merge `codex/pr7-liquid-glass-motion-ui` through live tip
  `d3b5f2a9631acf77e335b78d8731a37e0a17e3f4` (`a309b8d` is its preceding
  runtime-evidence commit).
- Preserve `ContentView` presenter lifetime and `AVPlayerView` isolation.
- Capture one MI feature snapshot per SwiftUI body. Motion consumes its
  `revision` and `MeetingIntelligenceSessionPresentationIdentity`; neither UI
  nor `AppModel` creates a second identity/state owner.
- Provider saves affect future jobs only; active ASR/MI snapshots stay fixed.
- Imported physical folders remain UUID-owned/no-replace and rollback-safe.
- Troubleshooting persistence is not telemetry: write only typed allowlisted
  codes, never raw errors, URL/path, credential, prompt, transcript, or audio.
  Cancellation writes no failure diagnostic.
- Every production slice begins with an observed focused RED, ends GREEN,
  receives independent review, and is committed before the next slice.

## File Map

- UI merge/adapter: `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift`,
  `RecordingsLibraryView.swift`, `RecorderObservedTransition.swift`,
  `RecordDashboardView.swift`, `RecorderGlass.swift`, motion/status primitives,
  `Views/AIProviderSettingsView.swift`, `RecordingControllerPanel.swift`, and
  `TeamsAutoMeetingCountdownPanel.swift`; corresponding render/motion tests.
- Composition: `OpenAICompatibleProviderRepository.swift`,
  `AIProviderSettingsModel.swift`, both Job/Feature models,
  `PRBFeatureBoundaries.swift`, `AppModel.swift`, and
  `AppModelPRBFeatureBoundaryTests.swift`.
- Title ownership: `MeetingIntelligenceSuggestedTitleApplier.swift`,
  `MeetingIntelligenceJobCoordinator.swift`, `RecordingsLibraryView.swift`, and
  the applier/coordinator/sheet-render tests.
- Editors: `LibraryFeatureEvents.swift`, `RecorderActionID.swift`,
  `RecordingsLibraryView.swift`, new `LibraryEditorSaveStateTests.swift`, and
  `MeetingIntelligenceSheetRenderTests.swift`.
- Import: `RecordingSession.swift`, `ManualTranscriptionImporterTests.swift`,
  Library search tests, and MI presentation tests.
- Diagnostics: `TranscriptionArtifactPublisher.swift`,
  `TranscriptionJobCoordinator.swift`, and their focused tests.

### Task 1: Integrate the Approved UI Branch

**Produces:** presentation-only Liquid Glass/motion UI plus
`RecorderObservedSnapshot` built from the same immutable PR B snapshot used for
the selected session.

- [ ] Run the PR7 UI/render suites and record the pre-merge baseline.
- [ ] Run `git merge --no-ff --no-commit codex/pr7-liquid-glass-motion-ui`;
  expect only `MeetingIntelligenceSectionView.swift` to conflict.
- [ ] Add a RED render test proving a changed feature revision for the same
  typed session identity triggers ready feedback, while another identity does
  not.
- [ ] Resolve the conflict by retaining PR B presentation/command ownership and
  PR7 motion/action-state/Reduce Motion rendering. In `RecordingsLibraryView`,
  capture one `meetingIntelligenceFeature.snapshot` and pass its revision,
  typed identity, phase, title and effective protection to
  `RecorderObservedSnapshot`.
- [ ] Run snapshot and all UI suites, `git diff --check`, independent review,
  then commit `merge: integrate Liquid Glass motion UI into PR B`.

### Task 2: Complete Composition Compatibility

**Produces:** package-internal
`OpenAICompatibleProviderManaging.compositionIdentity: ObjectIdentifier`,
read-only repository identities on Settings/ASR/MI, and
`PRBFeatureBoundaries.isCompatible(with settingsRepositoryIdentity:)`.

- [ ] Add RED tests for shared composition, split Settings repository, split
  ASR/MI repository, split gate, and mismatched ASR/MI publication sources.
- [ ] Add a positive integration RED: start blocked ASR and MI jobs, save a new
  provider profile, assert active jobs retain old models, release them, then
  assert the next ASR and MI snapshots use the saved models.
- [ ] Add `compositionIdentity` with `ObjectIdentifier(self)`, retain/expose it
  through both coordinators/features and `AIProviderSettingsModel`, and extend
  the aggregate predicate to require source + gate + ASR/MI/Settings identity.
- [ ] In `AppModel.init`, validate aggregate injection against the active
  repository. For individual seams, construct all four retained boundaries,
  aggregate them, and run the identical predicate after construction.
- [ ] Run boundary/feature/AppModel suites, independent review, then commit
  `refactor: enforce shared provider composition`.

### Task 3: Fix Suggested-Title Ownership Projection

**Produces:** effective `titleIsProtected` derived from the current canonical
Library session, plus exact already-applied MI title as a zero-write/no-event
operation.

- [ ] Add RED tests: applier already-applied title returns `false` with zero
  saves; coordinator successful apply publishes once and repeated no-op adds no
  publication; rendered same-open sheet removes protection and Apply after the
  canonical session becomes MI-owned, and a stale captured action is a no-op.
- [ ] Before any read/write, normalize and reject exact MI-owned title in the
  applier. After a durable apply, emit the Library reload callback exactly once.
  In the sheet, copy immutable presentation but derive protection from
  `displayedSession.metadata.titleOrigin == .manual`.
- [ ] Run applier/coordinator/sheet suites, independent review, then commit
  `fix: refresh suggested title ownership projection`.

### Task 4: Complete Async Editor Save UX

**Produces:** `LibraryEditorSaveState` with `idle`, `saving`, and
`failed(LibrarySaveFailure)`; one accepted submit at a time; exact
session/artifact completion admission; at-most-once dismiss.

- [ ] Add focused RED tests proving first submit enters saving, duplicate
  submit is ignored, failure preserves the draft and exact
  `LibrarySaveFailure.userMessage`, stale session/artifact completion is
  ignored, and repeated matching success dismisses once.
- [ ] Add rendered RED tests for transcript and metadata: deferred Save exposes
  an in-flight ID and disabled duplicate Save, failure keeps the sheet/draft and
  exposes the exact accessible error, and only expected success dismisses.
- [ ] Add shared editor state and stable IDs for metadata Save, both errors and
  both in-flight indicators. Snapshot the draft/session on accepted Save;
  disable Save and Cancel while active; guard completion/dismiss with the state.
- [ ] Run Library/editor/action-ID/render suites, independent review, then
  commit `fix: harden async library editor saves`.

### Task 5: Preserve Imported Recording Visible Name

**Produces:** metadata `title` from the source filename without extension and
explicit `titleOrigin: .unset`; the physical UUID folder is unchanged.

- [ ] Add importer/search/MI RED tests proving folders are unique, loaded
  display/search/status/accessibility copy has no UUID, and imported sessions
  remain unprotected and eligible for an MI title.
- [ ] During import save
  `RecordingSessionMetadata(title: sourceURL.deletingPathExtension().lastPathComponent,
  titleOrigin: .unset, source: .imported)` without changing no-replace or
  rollback logic.
- [ ] Run importer/search/MI suites, independent review, then commit
  `fix: preserve imported recording display name`.

### Task 6: Save Bounded Sanitized Troubleshooting Diagnostics

**Produces:** atomic failure-only diagnostic containing allowlisted `event`,
typed `stage`, fixed `errorCode`, and optional numeric HTTP status.

- [ ] Add publisher RED tests with an injected bearer token, API key, URL,
  absolute path and transcript phrase; assert none is persisted, file size is
  at most 64 KiB, symlink targets are refused, and no outside write occurs.
- [ ] Add coordinator RED tests proving one non-cancelled failure entry and no
  cancellation entry.
- [ ] Implement the atomic bounded writer under the shared mutation gate. Map
  failures to fixed codes/stages without using `localizedDescription`; reuse
  regular-file and symlink protections.
- [ ] Run publisher/coordinator tests, independent security/code review, then
  commit `feat: persist sanitized transcription diagnostics`.

### Task 7: Final Gate and Draft PR Update

- [ ] Run focused boundary, bridge, Library, MI, importer, editor/render, UI,
  and AppModel integration suites on the final SHA.
- [ ] Run complete Swift, Python/script, policy, packaging, strict codesign,
  bundle-content, VirtualMicDriver contract, and `git diff --check` gates.
- [ ] Verify the final diff contains no Windows, PR C, secret, generated cache,
  installed staging-app, or unrelated user-file changes.
- [ ] Obtain final independent review and record Critical/Important/Minor
  counts.
- [ ] Run unlocked-Mac 860x680 and wide UI smoke if available; otherwise report
  it as the remaining manual gate without claiming acceptance.
- [ ] Push the same branch, keep PR #8 Draft, update its body, and report exact
  head SHA, diff, CI URL/status, review findings, UI source SHA, and manual gate.
