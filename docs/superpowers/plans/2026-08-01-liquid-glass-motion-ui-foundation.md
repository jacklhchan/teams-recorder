# Pre-PR-B Liquid Glass and Motion UI Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the low-conflict macOS 26 Liquid Glass and restrained Apple-native motion foundation, then apply it to Record, Meeting Intelligence, provider Settings, and the existing floating recording/countdown panels without changing feature ownership while PR B is active.

**Architecture:** Add a small UI-only motion layer made of pure policies and immutable observed-transition comparisons, then compose it into native SwiftUI views and presentation-only floating-panel content that do not overlap PR B's active Library cutover. Recordings/transcript integration is deliberately excluded from this phase; after PR B is clean, a second implementation plan will name its final exact feature APIs and rebase allowlist before those files are edited.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Combine, XCTest, macOS 26.0, native `NavigationSplitView`, `glassEffect`, `GlassEffectContainer`, and `NSHostingView` interaction tests.

## Global Constraints

- Work only in `/Users/apple/Documents/recorder/.worktrees/pr7-liquid-glass-motion-ui` on `codex/pr7-liquid-glass-motion-ui`; never edit the active PR B worktree.
- The app target remains macOS 26.0. Use native `glassEffect`/glass button APIs; do not add a pre-macOS-26 availability branch.
- Use Liquid Glass only for navigation and selected primary control clusters. Forms, transcript text, status, summaries, and editable content remain stable opaque/system content surfaces.
- Preserve the native `NavigationSplitView`, the 860×680 minimum, wide-window behavior, keyboard activation, focus rings, VoiceOver labels, existing `RecorderActionID` strings, and session-specific row labels.
- Preserve external AppKit playback. Do not embed `AVPlayerView` or `RecordingPlaybackView` in the workspace hierarchy.
- Preserve PR #7's exact states and commands. Unconfirmed availability retains both `Check Again` and explicit `Generate`; working shows `Cancel`; ready/stale shows `Regenerate`; failed/cancelled/interrupted shows `Retry Generation`.
- Preserve this copy exactly: `The current title was edited manually. Apply the suggestion only if you want to replace it.` VoiceOver additionally exposes `Manual title protected`.
- Never add fake percentage, determinate AI progress, token count, stage count, action items, decisions, risks, calendar actions, chat, inferred speakers, or inferred timestamps.
- Motion is presentation-only: it never starts, delays, retries, cancels, or determines product work. Cancel, Stop, Save, Retry, and navigation remain immediately routable.
- Normal motion uses approximately 0.975 press scale over 80 ms, 180 ms release, 180 ms status cross-fade, and a 260 ms reveal with at most 6 points vertical travel.
- Reduce Motion removes scale, translation, pulse, shimmer, stroke drawing, and custom continuous progress travel. It permits a 160 ms opacity cross-fade or immediate replacement.
- Reduce Transparency replaces custom glass surfaces with system material plus a separator; it does not change hierarchy or controls.
- Preserve the recording controller's 390×112 size and the Teams automatic-start countdown's 360×94 size, panel flags, level, positioning, cross-Space behavior, presentation episodes, drag/close behavior, and focus semantics. Floating-panel styling must not call `orderFront`, dismiss, consume cancellation, or change recording/Teams ownership.
- The UI branch creates no `AppModel` state, coordinator, repository, provider draft, credential state, feature job identity, canonical session list, persistence path, or event bridge.
- Do not edit `ContentView.swift`, `RecorderSettingsView.swift`, `RecordingsLibraryView.swift`, `RecorderWorkspaceRenderTests.swift`, or `MeetingIntelligenceSheetRenderTests.swift` in this phase; they are the active PR B overlap set.
- Every production behavior change follows RED → observed expected failure → minimal GREEN → focused regression tests → path-limited commit.

## Exact File Allowlist

This pre-rebase phase may touch only:

- `Sources/RecorderApp/UI/RecorderMotionPolicy.swift`
- `Sources/RecorderApp/UI/RecorderObservedTransition.swift`
- `Sources/RecorderApp/UI/RecorderGlass.swift`
- `Sources/RecorderApp/UI/RecorderMotionButtonStyle.swift`
- `Sources/RecorderApp/UI/RecorderStatusTransition.swift`
- `Sources/RecorderApp/UI/RecorderIndeterminateProgress.swift`
- `Sources/RecorderApp/UI/RecorderVisualStyle.swift`
- `Sources/RecorderApp/UI/RecorderActionID.swift`
- `Sources/RecorderApp/UI/RecordDashboardView.swift`
- `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift`
- `Sources/RecorderApp/Views/AIProviderSettingsView.swift`
- `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- `Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift`
- `Tests/RecorderAppTests/RecorderMotionPolicyTests.swift`
- `Tests/RecorderAppTests/RecorderMotionRenderTests.swift`
- `Tests/RecorderAppTests/MeetingIntelligencePresentationTests.swift`
- `Tests/RecorderAppTests/MeetingIntelligenceSectionRenderTests.swift`
- `Tests/RecorderAppTests/AIProviderSettingsRenderTests.swift`
- `Tests/RecorderAppTests/RecordingControllerRenderTests.swift`
- `Tests/RecorderAppTests/TeamsAutoMeetingCountdownRenderTests.swift`
- `Tests/RecorderAppTests/RecorderActionIDTests.swift`

The design status and this implementation plan may be updated under `docs/superpowers/`; `.superpowers/sdd/` contains ignored execution bookkeeping only. `Sources/RecorderApp/AppModel.swift`, feature models, coordinators, transports, repositories, persistence, capture, Teams, media, audio, and playback sources are outside the allowlist.

After PR B finishes, a separate post-rebase plan must first record the actual, compiling `LibraryFeatureModel`, `TranscriptionFeatureModel`, `MeetingIntelligenceFeatureModel`, and `PlaybackFeatureModel` snapshot/revision/command signatures. That plan must then name its exact source/test allowlist and RED tests before any Recordings/transcript integration edit. This phase neither guesses nor creates those contracts.

---

### Task 1: Pure Motion Policy and Observed Feedback

**Files:**
- Create: `Sources/RecorderApp/UI/RecorderMotionPolicy.swift`
- Create: `Sources/RecorderApp/UI/RecorderObservedTransition.swift`
- Create: `Tests/RecorderAppTests/RecorderMotionPolicyTests.swift`

**Interfaces:**
- Consumes: immutable booleans and value snapshots only.
- Produces: `RecorderMotionPolicy.make(reduceMotion:)`, `RecorderObservedSnapshot`, and `RecorderObservedTransition.feedback(previous:current:)` for later views.

- [x] **Step 1: Write the failing pure tests**

```swift
import XCTest
@testable import RecorderApp

final class RecorderMotionPolicyTests: XCTestCase {
    func testNormalPolicyUsesApprovedRestrainedMotion() {
        let policy = RecorderMotionPolicy.make(reduceMotion: false)
        XCTAssertEqual(policy.pressedScale, 0.975)
        XCTAssertEqual(policy.pressDuration, 0.08)
        XCTAssertEqual(policy.releaseDuration, 0.18)
        XCTAssertEqual(policy.statusDuration, 0.18)
        XCTAssertEqual(policy.revealDuration, 0.26)
        XCTAssertEqual(policy.revealOffset, 6)
        XCTAssertTrue(policy.drawsCompletionStroke)
        XCTAssertTrue(policy.travelsIndeterminateSegment)
    }

    func testReduceMotionRemovesMovementPulseStrokeAndContinuousTravel() {
        let policy = RecorderMotionPolicy.make(reduceMotion: true)
        XCTAssertEqual(policy.pressedScale, 1)
        XCTAssertEqual(policy.pressDuration, 0)
        XCTAssertEqual(policy.releaseDuration, 0)
        XCTAssertEqual(policy.statusDuration, 0.16)
        XCTAssertEqual(policy.revealDuration, 0.16)
        XCTAssertEqual(policy.revealOffset, 0)
        XCTAssertFalse(policy.drawsCompletionStroke)
        XCTAssertFalse(policy.travelsIndeterminateSegment)
    }

    func testVisibleReadyEdgeEmitsOnceButInitialReadyAndRerenderDoNot() {
        let working = snapshot(revision: 1, phase: .working)
        let ready = snapshot(revision: 2, phase: .ready)
        XCTAssertEqual(.none, RecorderObservedTransition.feedback(previous: nil, current: ready))
        XCTAssertEqual(.init(completed: true, generatedTitleChanged: false), RecorderObservedTransition.feedback(previous: working, current: ready))
        XCTAssertEqual(.none, RecorderObservedTransition.feedback(previous: ready, current: ready))
    }

    func testSessionChangeAndManualTitleOwnershipSuppressFeedback() {
        let previous = snapshot(revision: 7, phase: .working, sessionID: "A", title: "Old")
        let otherSession = snapshot(revision: 8, phase: .ready, sessionID: "B", title: "Generated")
        let protected = snapshot(revision: 8, phase: .ready, sessionID: "A", title: "Manual", protected: true)
        XCTAssertEqual(.none, RecorderObservedTransition.feedback(previous: previous, current: otherSession))
        XCTAssertEqual(.init(completed: true, generatedTitleChanged: false), RecorderObservedTransition.feedback(previous: previous, current: protected))
    }

    func testGeneratedTitleFeedbackRequiresNewerReadySnapshotAndUnprotectedTitle() {
        let previous = snapshot(revision: 11, phase: .working, title: "Old")
        let current = snapshot(revision: 12, phase: .ready, title: "Generated")
        XCTAssertEqual(.init(completed: true, generatedTitleChanged: true), RecorderObservedTransition.feedback(previous: previous, current: current))
    }

    private func snapshot(
        revision: UInt64,
        phase: RecorderObservedPhase,
        sessionID: String = "session",
        title: String = "Title",
        protected: Bool = false
    ) -> RecorderObservedSnapshot {
        .init(featureRevision: revision, sessionID: sessionID, phase: phase, displayedTitle: title, titleIsProtected: protected)
    }
}
```

- [x] **Step 2: Run RED and verify the missing-type failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecorderMotionPolicyTests
```

Expected: compile failure naming missing `RecorderMotionPolicy` or `RecorderObservedSnapshot`, not a fixture or XCTest error.

- [x] **Step 3: Add the minimal pure implementation**

```swift
import Foundation

struct RecorderMotionPolicy: Equatable, Sendable {
    let pressedScale: Double
    let pressDuration: TimeInterval
    let releaseDuration: TimeInterval
    let statusDuration: TimeInterval
    let revealDuration: TimeInterval
    let revealOffset: Double
    let drawsCompletionStroke: Bool
    let travelsIndeterminateSegment: Bool

    static func make(reduceMotion: Bool) -> Self {
        reduceMotion
            ? .init(pressedScale: 1, pressDuration: 0, releaseDuration: 0, statusDuration: 0.16, revealDuration: 0.16, revealOffset: 0, drawsCompletionStroke: false, travelsIndeterminateSegment: false)
            : .init(pressedScale: 0.975, pressDuration: 0.08, releaseDuration: 0.18, statusDuration: 0.18, revealDuration: 0.26, revealOffset: 6, drawsCompletionStroke: true, travelsIndeterminateSegment: true)
    }
}

enum RecorderObservedPhase: Equatable, Sendable { case idle, working, ready, failure }

struct RecorderObservedSnapshot: Equatable, Sendable {
    let featureRevision: UInt64
    let sessionID: String
    let phase: RecorderObservedPhase
    let displayedTitle: String
    let titleIsProtected: Bool
}

struct RecorderObservedFeedback: Equatable, Sendable {
    let completed: Bool
    let generatedTitleChanged: Bool
    static let none = Self(completed: false, generatedTitleChanged: false)
}

enum RecorderObservedTransition {
    static func feedback(previous: RecorderObservedSnapshot?, current: RecorderObservedSnapshot) -> RecorderObservedFeedback {
        guard let previous,
              previous.sessionID == current.sessionID,
              current.featureRevision > previous.featureRevision else { return .none }
        let completed = previous.phase != .ready && current.phase == .ready
        let titleChanged = current.phase == .ready
            && !current.titleIsProtected
            && previous.displayedTitle != current.displayedTitle
        return .init(completed: completed, generatedTitleChanged: titleChanged)
    }
}
```

`completed` alone is restricted to non-ready → ready. `generatedTitleChanged`
intentionally also permits a strictly newer ready → ready snapshot because
canonical Library metadata may publish the generated display title after the
MI ready snapshot; same-session, changed-title, and unprotected ownership
remain mandatory.

- [x] **Step 4: Run GREEN and commit**

Run the focused test, then `git diff --check`. Expected: all `RecorderMotionPolicyTests` pass. Commit only the three Task 1 paths with:

```bash
git commit -m "feat: add recorder motion policy"
```

---

### Task 2: Native Glass, Button Feedback, Status Replacement, and Waiting Signal

**Files:**
- Create: `Sources/RecorderApp/UI/RecorderGlass.swift`
- Create: `Sources/RecorderApp/UI/RecorderMotionButtonStyle.swift`
- Create: `Sources/RecorderApp/UI/RecorderStatusTransition.swift`
- Create: `Sources/RecorderApp/UI/RecorderIndeterminateProgress.swift`
- Modify: `Sources/RecorderApp/UI/RecorderVisualStyle.swift`
- Modify: `Sources/RecorderApp/UI/RecorderActionID.swift`
- Modify: `Sources/RecorderApp/UI/RecordDashboardView.swift`
- Create: `Tests/RecorderAppTests/RecorderMotionRenderTests.swift`
- Modify: `Tests/RecorderAppTests/RecorderActionIDTests.swift`

**Interfaces:**
- Consumes: Task 1 `RecorderMotionPolicy` plus SwiftUI environment values `accessibilityReduceMotion`, `accessibilityReduceTransparency`, and `isEnabled`.
- Produces: `recorderGlassSurface(_:)`, `RecorderMotionButtonStyle`, `RecorderStatusTransition`, and `RecorderIndeterminateProgress` without importing any feature/coordinator type.

- [x] **Step 1: Write RED render and accessibility-contract tests**

Create an AppKit `NSHostingView` harness that renders one enabled and one disabled motion button, `RecorderStatusTransition(value:)`, and `RecorderIndeterminateProgress`. Assert:

```swift
XCTAssertEqual(RecorderActionID.primaryActionCluster, "recorder.visual.primary-action-cluster")
XCTAssertEqual(RecorderActionID.indeterminateProgress, "recorder.visual.indeterminate-progress")
XCTAssertTrue(host.contains(RecorderActionID.primaryActionCluster))
XCTAssertTrue(host.contains(RecorderActionID.indeterminateProgress))
XCTAssertTrue(host.click(RecorderActionID.primaryActionCluster))
XCTAssertEqual(state.acceptedClicks, 1)
state.isEnabled = false
host.render()
XCTAssertFalse(host.isEnabled(RecorderActionID.primaryActionCluster))
XCTAssertFalse(host.click(RecorderActionID.primaryActionCluster))
XCTAssertEqual(state.acceptedClicks, 1)
```

- [x] **Step 2: Run RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderMotionRenderTests|RecorderActionIDTests'
```

Expected: compile failure for the new primitives/IDs.

- [x] **Step 3: Implement native macOS 26 primitives**

Use the SDK-verified signatures below; do not add an OS availability fallback:

```swift
enum RecorderGlassRole: Equatable {
    case navigation
    case primaryControls

    var cornerRadius: CGFloat { self == .navigation ? 16 : 18 }
    var isInteractive: Bool { self == .primaryControls }
}

private struct RecorderGlassSurface: ViewModifier {
    let role: RecorderGlassRole
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(.regularMaterial, in: shape).overlay(shape.stroke(.separator.opacity(0.45)))
        } else {
            content.glassEffect(.regular.interactive(role.isInteractive), in: shape)
        }
    }
}

extension View {
    func recorderGlassSurface(_ role: RecorderGlassRole) -> some View { modifier(RecorderGlassSurface(role: role)) }
}
```

`RecorderMotionButtonStyle` keeps the `Button` semantic and changes only scale/opacity from `configuration.isPressed` and `isEnabled`; its normal animation derives from the Task 1 durations and its Reduce Motion scale remains exactly `1`. `RecorderStatusTransition<Value>` holds the current value plus at most one outgoing value. On replacement it immediately installs the new current content, keeps only the old content for its opacity exit, and marks that outgoing layer `.allowsHitTesting(false).accessibilityHidden(true)`. The new current layer retains its real product enablement and is immediately hit-testable; no transition-wide interaction gate exists. `withAnimation(..., completionCriteria: .logicallyComplete)` clears only the matching outgoing value after the fade. `RecorderIndeterminateProgress` renders a native `ProgressView`, adds a decorative moving capsule only when `policy.travelsIndeterminateSegment`, marks the capsule accessibility-hidden, and stops its repeat animation on disappear.

Apply the new primary style and stable marker only to Start/Stop in `RecordDashboardControls`; leave toolbar icons, mute, destructive controls, meters, and capture behavior unchanged:

```swift
.buttonStyle(RecorderMotionButtonStyle(prominence: .prominent, tint: model.recorder.isRecording ? .red : .accentColor))
.accessibilityIdentifier(RecorderActionID.startStop)
.background(RecorderDestinationAccessibilityMarker(identifier: RecorderActionID.primaryActionCluster))
```

- [x] **Step 4: Run GREEN and focused dashboard regressions**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderMotionPolicyTests|RecorderMotionRenderTests|RecorderActionIDTests|RecordDashboardPresentationTests|RecorderToolbarPresentationTests|RecorderWorkspaceRenderTests.testMinimumWindowRendersRecordStatusAndPrimaryAction'
```

Expected: all selected tests pass; disabled Start/Stop remains disabled and produces no accepted click.

- [x] **Step 5: Commit**

Run `git diff --check`, stage only Task 2 paths, and commit:

```bash
git commit -m "feat: add native recorder motion primitives"
```

---

### Task 3: Meeting Intelligence State Card and Interruptible Transitions

**Files:**
- Modify: `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift`
- Modify: `Tests/RecorderAppTests/MeetingIntelligencePresentationTests.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligenceSectionRenderTests.swift`

**Interfaces:**
- Consumes: Task 1 policy/observed types, Task 2 transition/progress/button primitives, current immutable `MeetingIntelligencePresentation`, and existing `MeetingIntelligenceActions` closures.
- Produces: one exclusive `MeetingIntelligenceActionGroup`, status tone, opaque output sections, accessible working/failure/ready states, and optional observed-snapshot feedback input. It creates no job or feature state.

- [x] **Step 1: Write RED phase-matrix tests**

Add explicit expectations for `.notGenerated`, `.checkingAvailability`, `.generating`, `.ready`, `.stale`, `.failed`, `.cancelled`, and `.interrupted`. The expected projection is:

```swift
XCTAssertEqual(unconfirmed.actionGroup, .availability(checkAgain: true))
XCTAssertEqual(checking.actionGroup, .working)
XCTAssertEqual(generating.actionGroup, .working)
XCTAssertEqual(ready.actionGroup, .ready(checkAgain: false, applySuggestedTitle: false))
XCTAssertEqual(staleProtected.actionGroup, .ready(checkAgain: false, applySuggestedTitle: true))
XCTAssertEqual(failed.actionGroup, .recovery(checkAgain: false, applySuggestedTitle: false))
XCTAssertEqual(cancelled.actionGroup, .recovery(checkAgain: false, applySuggestedTitle: false))
XCTAssertEqual(interrupted.actionGroup, .recovery(checkAgain: false, applySuggestedTitle: false))
XCTAssertEqual(readyUnavailable.actionGroup, .ready(checkAgain: true, applySuggestedTitle: false))
```

Also assert the exact manual-title copy and `Manual title protected` accessibility label.

- [x] **Step 2: Write RED AppKit render/interaction tests**

In the new dedicated render file, host `MeetingIntelligenceSectionView` directly and assert every phase exposes only its current command IDs. For the real-duration replacement test:

```swift
let outgoingGenerateFrame = try host.frame(RecorderActionID.meetingIntelligenceGenerate)
state.presentation = generatingPresentation
host.renderWithoutWaitingForAnimationCompletion()
host.click(at: outgoingGenerateFrame)
XCTAssertFalse(state.invokedActions.contains("generate"))
try host.click(RecorderActionID.meetingIntelligenceCancel)
XCTAssertEqual(state.invokedActions.filter { $0 == "cancel" }.count, 1)
```

The host uses one persistent `NSHostingView` whose root observes an `ObservableObject` render state. Its real `NSEvent` mouse-down/up events must invoke the actual `Button` closures; click helpers must never append to `invokedActions` themselves. It proves that the outgoing Generate command is stale immediately while the incoming Cancel command is routable immediately; it does not wait for animation completion before invoking Cancel.

The render matrix must cover initial availability, both working phases, normal ready, ready with unavailable feedback, protected-title ready, and all recovery phases. Each fixture asserts the exact current action IDs and the absence of every stale action ID.

- [x] **Step 3: Run RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'MeetingIntelligencePresentationTests|MeetingIntelligenceSectionRenderTests'
```

Expected: compile/assertion failure for missing `actionGroup` and transition behavior.

- [x] **Step 4: Implement the exclusive state tree**

```swift
enum MeetingIntelligenceActionGroup: Equatable, Sendable {
    case availability(checkAgain: Bool)
    case working
    case ready(checkAgain: Bool, applySuggestedTitle: Bool)
    case recovery(checkAgain: Bool, applySuggestedTitle: Bool)
}

enum RecorderStatusTone: Equatable, Sendable { case neutral, working, success, warning }
```

Map phases once in `MeetingIntelligenceSectionPresentation.make`, then render actions through one structural switch inside `RecorderStatusTransition(value: section.actionGroup)`. Keep `Check Again` plus `Generate` in `.availability(true)`, `Cancel` in `.working`, `Regenerate` plus optional Check Again/Apply in `.ready`, and `Retry Generation` plus optional Check Again/Apply in `.recovery`. The `checkAgain` value on ready/recovery preserves the existing PR #7 contract where durable output may coexist with a later availability warning. `RecorderStatusTransition` alone disables and accessibility-hides its outgoing layer; never disable the incoming action group as part of animation.

Use `RecorderIndeterminateProgress` only for working states. Existing summaries may remain visible while regenerating if present. Render summary/title in stable content surfaces with opacity/≤6-point reveal; render failure status in orange without shake. Apply `.accessibilityLabel("Manual title protected")` to the exact visible manual-title explanation while preserving its existing identifier and copy.

Keep the optional `RecorderObservedSnapshot` as view-local presentation input: store the initial visible snapshot without feedback, compare each later visible snapshot with `RecorderObservedTransition.feedback`, and update the stored snapshot even when feedback is `.none`. A same-session non-ready→ready update may trigger only the transient completion check; a strictly newer same-session ready→ready displayed-title change may trigger only the transient title highlight when manual-title protection is false. Nil input, initial-ready input, cross-session replacement, stale revisions, and protected titles render without feedback. Under Reduce Motion, feedback may use opacity or a static accent only—no movement, scale, or travelling stroke. Add render assertions for initial-ready static, working→ready completion, newer ready→ready title highlight, and protected-title suppression.

- [x] **Step 5: Run GREEN, regress exact PR #7 behavior, and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderMotionPolicyTests|MeetingIntelligencePresentationTests|MeetingIntelligenceSectionRenderTests|MeetingIntelligenceSheetRenderTests'
git diff --check
```

Expected: phase matrix, real AppKit hit-testing, existing transcript-detail routing, manual-title protection, and draft-stability tests pass. Commit only Task 3 paths:

```bash
git commit -m "feat: refine meeting intelligence presentation"
```

---

### Task 4: Provider Settings Layout and Real Save/Test Feedback

**Files:**
- Modify: `Sources/RecorderApp/Views/AIProviderSettingsView.swift`
- Create: `Tests/RecorderAppTests/AIProviderSettingsRenderTests.swift`

**Interfaces:**
- Consumes: the one injected existing `AIProviderSettingsModel`, its real `isTesting`, `status`, `statusIsError`, provider draft fields, Save/Test/Remove Key methods, and Task 2 primitives.
- Produces: the approved HKT/OpenAI-compatible layouts and status motion without a second provider model, repository, draft, credential, or outcome.

- [x] **Step 1: Write RED provider render tests**

Use the existing test-target `RecordingProviderRepository` and direct `NSHostingView<AIProviderSettingsView>`. At 860×680 and 1,280×800 assert the existing IDs render and remain reachable through the scroll/form surface. Verify HKT shows Group ID/resolved URL and hides Base URL; generic shows Base URL and hides HKT-only fields. Use a real AppKit click on Save and assert `repository.saveCount == 1`; use a blocking `ProviderConnectionTesting` fixture to assert Test becomes disabled and native waiting/status output remains visible until the real task settles.

```swift
XCTAssertTrue(host.contains(RecorderActionID.providerKind))
XCTAssertTrue(host.contains(RecorderActionID.providerHKTGroupID))
XCTAssertTrue(host.contains(RecorderActionID.providerHKTResolvedURL))
XCTAssertFalse(host.contains(RecorderActionID.providerBaseURL))
try host.click(RecorderActionID.providerSave)
XCTAssertEqual(repository.saveCount, 1)
```

- [x] **Step 2: Run RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AIProviderSettingsRenderTests
```

Expected: layout/marker or frame assertions fail against the current flat provider card.

- [x] **Step 3: Implement the provider composition**

Keep all bindings and actions unchanged. Compose three stable surfaces—Connection, Models, and Transcription—inside the existing Settings section. Use the exact provider names `HKT GenAI Platform` and `OpenAI-compatible API`; HKT renders Group ID plus resolved fixed endpoint, while generic renders editable API Base URL. Preserve independent ASR/LLM fields and discovered-model menus.

Wrap Save and Test in one `GlassEffectContainer(spacing: 8)` primary command cluster. Save invokes `model.save()` synchronously; Test remains `Task { await model.testConnection() }`; Remove Key remains visually subordinate/destructive. Drive progress and status solely from `model.isTesting`, `model.status`, and `model.statusIsError`. Do not infer or cache a separate success outcome.

- [x] **Step 4: Run GREEN and model regressions**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'AIProviderSettingsRenderTests|AIProviderSettingsModelTests|RecorderActionIDTests'
git diff --check
```

Expected: provider render tests pass and all existing draft switching, model discovery, cancellation generation, stale result, save, key, and validation tests remain green.

- [x] **Step 5: Commit**

Stage only the two Task 4 paths and commit:

```bash
git commit -m "feat: refine AI provider settings UI"
```

---

### Task 5: Floating Recording and Teams Countdown Panels

**Files:**
- Modify: `Sources/RecorderApp/UI/RecorderMotionPolicy.swift`
- Modify: `Sources/RecorderApp/UI/RecorderGlass.swift`
- Modify: `Sources/RecorderApp/UI/RecorderMotionButtonStyle.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Modify: `Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift`
- Modify: `Tests/RecorderAppTests/RecorderMotionRenderTests.swift`
- Create: `Tests/RecorderAppTests/RecordingControllerRenderTests.swift`
- Create: `Tests/RecorderAppTests/TeamsAutoMeetingCountdownRenderTests.swift`

**Interfaces:**
- Consumes: the existing immutable `RecordingControllerPresentation`, the current Stop/screen-request closures, countdown seconds/cancel closure, and Task 2 glass/motion primitives.
- Produces: directly hostable presentation-only panel content and approved compact styling. It creates no panel episode, recorder/Teams state, timer, command owner, or AppKit window lifetime.

- [x] **Step 1: Write RED direct-render and real-event tests**

Extract only a direct-host seam, not a second model. At 390×112 assert the active controller exposes the exact existing status, elapsed, screen-status, switch, and Stop identifiers inside bounds. Send real AppKit events to enabled Stop and assert its injected closure runs exactly once. Render finalizing with the same host seam; capture the disabled Stop and switch frames, dispatch raw `NSEvent` mouse-down/up at those frames without consulting or pre-rejecting on accessibility-enabled state, and prove neither command closure runs.

At 360×94 assert the countdown panel, seconds, and Cancel identifiers stay inside bounds for both 8-second and 7-second fixtures. Real-click Cancel and assert exactly one invocation. Keep the existing episode test as the source of truth that a tick refresh does not call `orderFront` again; the direct render harness must not claim that production retains one `NSHostingView`, because the current controller intentionally replaces hosted content on each tick.

Because the SDK exposes `accessibilityReduceMotion` and `accessibilityReduceTransparency` as read-only environment key paths, add deterministic internal override seams that default to nil and are consumed inside the actual shared button/glass modifiers. Render each panel under normal, Reduce Motion, and Reduce Transparency overrides. Assert production-attached branch markers prove normal versus no-scale motion selection and native glass versus material+separator fallback, while all panel IDs, controls, enabled states, and frames remain unchanged. Markers must be emitted by the modifiers whose branch they observe—not by a parallel test-only fixture boolean.

- [x] **Step 2: Run RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecordingControllerRenderTests|TeamsAutoMeetingCountdownRenderTests'
```

Expected: compile failure for the missing directly hostable controller seam and/or render assertions that fail against the current unstyled content.

- [x] **Step 3: Implement presentation-only compact panel content**

Add shared internal optional Reduce Motion/Transparency override environment values for deterministic rendering; default nil must continue to read the real system environments. `RecorderMotionButtonStyle` and `RecorderGlassSurface` consume the effective values and attach non-interactive diagnostic markers for their actual normal/reduced and native/fallback branches. This is presentation/test observability only and creates no product setting.

Keep `RecordingControllerCoordinator`, `RecordingControllerPanelEpisode`, `RecordingControllerPanelPresenter`, both `NSPanel` configurations, and all AppModel calls semantically unchanged. Let the existing `TimelineView` wrapper project `RecordingControllerPresentation` and delegate rendering to an internal content view with injected Stop and screen-request closures. Use stable high-contrast row surfaces, the exact 390×112 frame, monospaced timer, existing screen tones/labels/values, and a text+symbol Stop control with the shared restrained red motion style. `Recording → Finalizing` may cross-fade the local title/control state only; it must immediately preserve the existing disabled gates.

Make the existing countdown content directly hostable without changing its controller, content-refresh behavior, or episode. Preserve the exact 360×94 hierarchy/copy and use native compact glass for the subordinate Cancel control. Apply Liquid Glass only to panel chrome/primary controls; Reduce Transparency falls back through the shared material/separator path. Countdown/timer ticks do not reorder, reposition, pulse, move, resize, or create product progress.

- [x] **Step 4: Run GREEN and exact lifecycle regressions**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecordingControllerRenderTests|RecordingControllerPresentationTests|RecordingControllerPanelTests|TeamsAutoMeetingCountdownRenderTests|TeamsAutoMeetingPresentationTests|TeamsAutoMeetingCoordinatorTests|RecorderMotionPolicyTests|RecorderMotionRenderTests'
git diff --check
```

Expected: real panel-content events, fixed-size accessibility bounds, finalizing gates, one-shot countdown cancellation, episode ordering, coordinator shutdown, and Reduce Motion/Transparency contracts all pass. Existing panel lifecycle tests are run unchanged.

- [x] **Step 5: Commit**

Stage only the eight Task 5 paths and commit:

```bash
git commit -m "feat: refine floating recorder panels"
```

---

### Task 6: Foundation Verification, Visual Preview, and Review

**Files:**
- Modify only when verification reveals an in-scope defect: files in this plan's Exact File Allowlist.
- Update: `docs/superpowers/plans/2026-08-01-liquid-glass-motion-ui-foundation.md` checkboxes after each verified task.

**Interfaces:**
- Consumes: the five pre-rebase UI tasks.
- Produces: reproducible automated evidence, a locally runnable foundation preview, and an independently reviewed set of commits ready to rebase later. It does not edit PR B overlap files, merge, or push.

- [x] **Step 1: Run source and scope audits**

```bash
git diff --check
git diff --name-only 1df4187...HEAD
rg -n 'AVPlayerView|RecordingPlaybackView' Sources/RecorderApp/ContentView.swift Sources/RecorderApp/UI
rg -n 'fake percentage|token count|action items|calendar|chat' Sources/RecorderApp/UI Sources/RecorderApp/Views/AIProviderSettingsView.swift Sources/RecorderApp/Views/RecordingControllerPanel.swift Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift
```

Expected: production/test changes are inside this plan's allowlist; `docs/superpowers/` contains only the approved status and plan update; playback view names have no new workspace declaration; prohibited product additions have no matches.

- [x] **Step 2: Run the complete pre-rebase automated suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: zero failures. Existing SDK deprecation warnings are recorded separately and are not rewritten by this UI phase.

Final pre-rebase run on 2026-08-01: 1061 tests executed, 5 skipped,
0 failures in 25.501 seconds.

A later fresh verification rerun while the Mac was locked executed the same
1061 tests with 5 skipped but reported 9 timeout assertions across 4 existing
`AppModelMuteTests`. An isolated repeat reproduced the timeouts before their
injected session loaders were reached. Those tests first run the default
`IncompleteSessionRecovery` scan of `~/Downloads`; a bounded direct directory
enumeration also did not return while locked and was terminated. This is
recorded as a non-green environment/TCC-consistent rerun, not as a replacement
for the earlier green run and not as evidence of a UI regression. No AppModel
or overlapping PR B test file was changed in response.

- [x] **Step 3: Build the app and inspect the implemented foundation**

Use the repository's existing build script without overwriting a non-staging installed app. Inspect Start/Stop press behavior, MI unavailable/working/ready/failure/manual-title states, HKT and generic provider settings, active/finalizing recording controller, Teams automatic-start countdown, light/dark, Reduce Motion, Reduce Transparency, and increased contrast. Confirm floating Stop/Cancel, main Stop, Cancel, Save, Retry, provider Test, and navigation remain immediate and the panels do not steal focus. Treat this as pre-rebase visual evidence, not full Recordings/transcript acceptance.

2026-08-01 evidence: `scripts/build-app.sh` and
`scripts/verify-app-bundle.sh` passed for the worktree-local
`build/Local Meeting Recorder Staging.app` (`local.meeting.recorder.staging`);
the `/Applications` installer and its running app were deliberately left
untouched. Actual dark-mode runtime click-through used a uniquely identified,
worktree-local UI Preview bundle whose compiled artifact disabled startup work;
the preview-only source seam was immediately restored. Record, Recordings,
Settings, and both generic and HKT provider destinations were inspected, with
navigation and visible primary controls remaining reachable. No recording,
permission grant, credential entry, or user session was created.

ScreenCaptureKit production-view evidence covered active recording,
finalizing, Teams countdown, and the MI unavailable, generating, ready,
manual-title-protected, and failure states. A separate production
`RecorderWorkspaceContent` render covered light appearance plus
`accessibilityHighContrastAqua` without changing global macOS settings (1 test,
0 failures in 1.426 seconds). Focused render tests cover the Reduce Motion and
Reduce Transparency policy branches and the immediate Stop/Cancel/Save/Retry/
Test action contracts. All temporary visual-export tests were removed and the
product source was restored before recording this gate. This remains
pre-rebase visual evidence, not full recording/transcript acceptance.

- [x] **Step 4: Request independent whole-phase review**

Generate a review package from `1df4187` to HEAD. The reviewer checks this phase's spec subset, ownership, accessibility, outgoing-only hit-test suppression, animation lifetime, provider state fidelity, no embedded playback, and the exact allowlist. Fix all Critical/Important findings in one reviewed fix wave and rerun covering tests.

The independent review reported Critical 0 / Important 1 / Minor 0. Commit
`b86899f` separated first-ready completion feedback from later ready-to-ready
generated-title highlighting. Focused tests proved RED (14 tests, 2 failures)
then GREEN (14 tests, 0 failures); independent re-review closed the finding
with no new findings.

- [ ] **Step 5: Record the later integration gate**

Report exact branch, worktree, commits, focused/full test results, visual evidence, working-tree status, and intentionally deferred PR B overlap files. Wait for the PR B worktree to become clean; then write the separate post-rebase plan from the actual committed feature APIs before rebasing or editing Recordings/transcript code.

2026-08-01 gate snapshot: PR B task
`019fae39-ebd1-7611-8a23-de5aee74293d` remains active in its separate
worktree. Task 4's stable read-only UI contract was verified at commit
`4056a8ad8649422ba4c163e3fb5918b82d518248`:
`MeetingIntelligenceFeatureModel.snapshot`,
`MeetingIntelligenceFeatureSnapshot.revision`, snapshot
`presentation(for:)`, and the typed
`MeetingIntelligenceSessionPresentation.identity` containing both `sessionID`
and `normalizedSessionFolder`. It adds no AppModel mirror or duplicate
identity state.

The post-rebase integration must observe `model.meetingIntelligenceFeature`
directly in `RecordingsLibraryView`, capture exactly one immutable snapshot per
body evaluation, and use the same entry for both the visible presentation and
motion feedback. `RecorderObservedSnapshot` must replace its temporary
`String` session ID with the contract's typed presentation identity; its
`featureRevision` comes directly from the captured snapshot revision. The
transcript detail then passes that observed snapshot into
`MeetingIntelligenceSectionView`, so non-ready-to-ready completion and
ready-to-ready generated-title feedback are driven in production rather than
only in render fixtures. UI code must not repeat URL normalization or mirror
feature state into AppModel.

Current read-only merge analysis from base `6fafacf` identifies
`MeetingIntelligenceSectionView.swift` as the textual conflict requiring manual
resolution, with semantic integration also required in
`RecordingsLibraryView.swift`, `RecorderObservedTransition.swift`, and the
production render tests. PR B Task 5 remains in review fixes, so no rebase,
cherry-pick, merge, push, or overlap-file edit has been attempted. Re-run this
analysis against the final PR B tip before integration.
