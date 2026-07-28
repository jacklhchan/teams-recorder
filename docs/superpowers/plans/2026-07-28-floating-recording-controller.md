# Floating Recording Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a compact, non-activating floating controller that appears for every active recording, shows status and elapsed time, controls Teams screen capture, and safely stops through `AppModel`.

**Architecture:** The normal app path owns one app-lifetime `AppRuntime`, one `AppModel`, and one recording-controller coordinator. A pure presentation value maps app state to UI state. A reusable AppKit `NSPanel` hosts a SwiftUI view observing the shared model. The viability-probe path remains isolated and does not initialize the runtime.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Combine, XCTest, Swift Package Manager

## Global Constraints

- Work only in `/Users/apple/Documents/recorder/.worktrees/floating-recording-window`.
- Do not edit the user's dirty files in `/Users/apple/Documents/recorder`.
- Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for all Swift builds and tests.
- Follow RED, GREEN, REFACTOR for every behavior change.
- Do not create a second `AppModel` or `RecordingEngine`.
- Stop must call `AppModel.startOrStop()`, never `RecordingEngine.stop()`.
- Screen recording starts Off for every recording.
- A requested but unavailable screen capture must remain switchable Off.
- Keep the panel visible through finalization and dismiss it only after `recorder.isRecording` becomes false.
- Preserve the `--teams-screen-viability-probe` startup path.

---

## Task 1: Pure Presentation And Screen-Off Regression

**Files:**

- Create: `Sources/RecorderApp/Views/RecordingControllerPresentation.swift`
- Modify: `Sources/RecorderApp/Capture/CapturePermission.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Create: `Tests/RecorderAppTests/RecordingControllerPresentationTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`

### Step 1: Write failing presentation tests

- [ ] Add tests covering:
  - hidden while no recording is active;
  - `Recording` while active;
  - `Finalizing` while the stop lifecycle is active;
  - elapsed time at zero, across one hour, and clamped to zero when `now` precedes `startedAt`;
  - non-Teams source shows `Teams screen unavailable` and disables the toggle;
  - Teams screen Off, Ready, Capturing, Waiting, Awaiting Frames, Frames Unavailable, Reconnecting, and Unavailable tones;
  - requested-but-unavailable keeps the toggle enabled for Off;
  - Stop is disabled only while finalizing.

The production interface must be:

```swift
enum RecordingControllerTone: Equatable {
    case neutral
    case ready
    case recording
    case warning
}

struct RecordingControllerSnapshot: Equatable {
    let isRecording: Bool
    let isFinalizing: Bool
    let startedAt: Date?
    let showsTeamsScreenControl: Bool
    let screenRequested: Bool
    let screenStatusText: String
    let screenToggleDisabled: Bool
}

struct RecordingControllerPresentation: Equatable {
    let isVisible: Bool
    let title: String
    let elapsedText: String
    let screenStatusText: String
    let screenTone: RecordingControllerTone
    let screenRequested: Bool
    let screenToggleDisabled: Bool
    let stopDisabled: Bool

    static func make(
        snapshot: RecordingControllerSnapshot,
        now: Date
    ) -> RecordingControllerPresentation
}
```

- [ ] Run the focused test and confirm RED because the types do not exist:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingControllerPresentationTests
```

### Step 2: Implement the pure projection

- [ ] Add the exact value types above.
- [ ] Format elapsed time as `HH:MM:SS` using whole non-negative seconds.
- [ ] Use `Teams screen unavailable` when `showsTeamsScreenControl` is false.
- [ ] Map `TeamsScreenStatusText.ready` to `.ready`, `capturing` to `.recording`, transient/failure states to `.warning`, and Off to `.neutral`.
- [ ] Keep all projection logic free of AppKit and side effects.

### Step 3: Expose exact finalization state

- [ ] Add this read-only property to `CaptureLifecycleGate`:

```swift
var activeOperation: CaptureLifecycleOperation? {
    activeToken?.operation
}
```

- [ ] Add this computed property to `AppModel`:

```swift
var isFinalizingRecording: Bool {
    recorder.isRecording &&
        captureLifecycleGate.activeOperation == .stop
}
```

This avoids briefly labeling recording startup or reconnect work as finalization.

### Step 4: Write the failing AppModel regression

- [ ] Add a test that starts a Teams recording, requests screen capture, forces `.unavailable` or `.failed`, verifies the toggle can still be used, calls `setTeamsScreenCaptureRequested(false)`, and verifies:
  - `isTeamsScreenCaptureRequested == false`;
  - the capture source receives a nil video target;
  - status returns to `Screen off`.
- [ ] Confirm RED against the current unconditional unavailable-state guard:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelScreenCaptureTests
```

### Step 5: Permit Off before applying On guards

- [ ] Change `isTeamsScreenCaptureToggleDisabled` to:

```swift
guard recorder.isRecording, !isCaptureLifecycleWorking else {
    return true
}
if isTeamsScreenCaptureRequested {
    return false
}
guard isScreenCaptureAllowedByStorage else {
    return true
}
switch recorder.meetingScreenCaptureState {
case .unavailable, .failed:
    return true
default:
    return false
}
```

- [ ] In `setTeamsScreenCaptureRequested(_:)`, handle `requested == false` after only the recording/lifecycle guard. Apply the storage and selected-Teams guards only to an On request.
- [ ] Continue routing both actions through `recorder.setScreenCaptureRequested(_:)` and restart the existing refresh loop.

### Step 6: Verify and commit Task 1

- [ ] Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingControllerPresentationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelScreenCaptureTests
```

- [ ] Commit only Task 1 files:

```bash
git add \
  Sources/RecorderApp/Views/RecordingControllerPresentation.swift \
  Sources/RecorderApp/Capture/CapturePermission.swift \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/RecordingControllerPresentationTests.swift \
  Tests/RecorderAppTests/AppModelScreenCaptureTests.swift
git commit -m "Add recording controller presentation"
```

---

## Task 2: Reusable Floating Panel And Episode Lifecycle

**Files:**

- Create: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Create: `Tests/RecorderAppTests/RecordingControllerPanelTests.swift`

### Step 1: Write failing episode tests

- [ ] Test this pure lifecycle:
  - false from idle returns `.none`;
  - first true returns `.present`;
  - repeated true returns `.none`;
  - first false after presentation returns `.dismiss`;
  - repeated false returns `.none`;
  - a later true starts a new presentation episode.

Use:

```swift
enum RecordingControllerPanelCommand: Equatable {
    case none
    case present
    case dismiss
}

struct RecordingControllerPanelEpisode {
    private(set) var isPresented = false

    mutating func handle(
        isRecording: Bool
    ) -> RecordingControllerPanelCommand
}
```

- [ ] Confirm RED:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingControllerPanelTests
```

### Step 2: Add presenter contracts and coordinator

- [ ] Add:

```swift
@MainActor
protocol RecordingControllerPresenting: AnyObject {
    func present(model: AppModel)
    func dismiss()
}

@MainActor
protocol RecordingControllerPresenterFactory {
    func makePresenter() -> any RecordingControllerPresenting
}
```

- [ ] Add `RecordingControllerCoordinator` that:
  - holds a presenter and one `RecordingControllerPanelEpisode`;
  - subscribes to `model.recorder.$isRecording.removeDuplicates()`;
  - calls `present(model:)` once on the false-to-true transition;
  - calls `dismiss()` once after finalization flips true-to-false;
  - dismisses and cancels observation on teardown.

- [ ] Test the coordinator with a spy presenter and the existing injectable recorder fixture. Prove one presentation per recording and reappearance on the next recording.

### Step 3: Build the non-activating panel

- [ ] Implement one reusable `NSPanel` with:
  - size `390 x 112`;
  - `.titled` and `.nonactivatingPanel`, with no `.closable`;
  - `level = .floating`;
  - `isReleasedWhenClosed = false`;
  - `hidesOnDeactivate = false`;
  - `becomesKeyOnlyIfNeeded = true`;
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`;
  - `isMovableByWindowBackground = true`;
  - `canBecomeKey` and `canBecomeMain` returning false.
- [ ] Position it 16 points from the top-right of the screen containing the pointer.
- [ ] Install one `NSHostingView` only when presenting a new recording episode; do not reorder or recreate it every timer tick.

### Step 4: Build the SwiftUI controller

- [ ] `RecordingControllerView` observes the shared `AppModel`.
- [ ] Use `TimelineView(.periodic(from: .now, by: 1))` to refresh the presentation projection.
- [ ] First row:
  - red recording indicator;
  - `Recording` or `Finalizing`;
  - monospaced timer;
  - red icon-only Stop button using `stop.fill`.
- [ ] Second row:
  - screen icon;
  - projected screen status and tone;
  - native `Toggle` bound through an async call to `setTeamsScreenCaptureRequested(_:)`.
- [ ] Disable Stop and Screen controls during finalization.
- [ ] Stop calls `model.startOrStop()`.
- [ ] Add tooltips and these identifiers:
  - `recording-controller-status`;
  - `recording-controller-elapsed`;
  - `recording-controller-screen-status`;
  - `recording-controller-screen-toggle`;
  - `recording-controller-stop`.

### Step 5: Verify and commit Task 2

- [ ] Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingControllerPanelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingControllerPresentationTests
```

- [ ] Commit:

```bash
git add \
  Sources/RecorderApp/Views/RecordingControllerPanel.swift \
  Tests/RecorderAppTests/RecordingControllerPanelTests.swift
git commit -m "Build floating recording controller panel"
```

---

## Task 3: Shared Runtime And Stable Main Window

**Files:**

- Create: `Sources/RecorderApp/AppRuntime.swift`
- Modify: `Sources/RecorderApp/LocalMeetingRecorderApp.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Create: `Tests/RecorderAppTests/AppRuntimeTests.swift`

### Step 1: Write failing runtime ownership tests

- [ ] Add a spy presenter factory and verify:
  - the runtime exposes the exact injected `AppModel` instance;
  - one runtime creates one presenter/coordinator;
  - recording transitions use that same model;
  - runtime shutdown dismisses the presenter.
- [ ] Confirm RED:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppRuntimeTests
```

### Step 2: Add app-lifetime runtime

- [ ] Implement:

```swift
@MainActor
final class AppRuntime {
    let model: AppModel
    private let recordingController: RecordingControllerCoordinator

    init(
        model: AppModel = AppModel(),
        recordingControllerFactory:
            any RecordingControllerPresenterFactory =
                RecordingControllerPanelFactory()
    )

    func shutdown()
}
```

- [ ] The runtime creates the presenter once and starts one model observation.
- [ ] `shutdown()` is idempotent.

### Step 3: Inject the shared model into ContentView

- [ ] Replace `@StateObject private var model = AppModel()` with:

```swift
@ObservedObject private var model: AppModel
```

- [ ] Extend `ContentView.init` with a required `model: AppModel` parameter while preserving the injectable Teams auto-countdown presenter factory.
- [ ] Keep countdown-panel ownership in `ContentView`; only recording-controller ownership moves to `AppRuntime`.

### Step 4: Keep probe startup isolated

- [ ] In `LocalMeetingRecorderApp`, evaluate the viability-probe argument before touching `appDelegate.runtime`.
- [ ] Normal path renders `ContentView(model: appDelegate.runtime.model)`.
- [ ] Probe path renders only `TeamsCaptureViabilityProbeView()`.

### Step 5: Give the main window a stable identity

- [ ] Add:

```swift
extension NSUserInterfaceItemIdentifier {
    static let localMeetingRecorderMain =
        NSUserInterfaceItemIdentifier("local-meeting-recorder-main")
}
```

- [ ] Add a zero-size `NSViewRepresentable` whose backing `NSView` assigns that identifier in `viewDidMoveToWindow`.
- [ ] Replace `NSApp.windows.first` with an identifier lookup in launch/reopen handling.
- [ ] Never treat the recording panel as the main window.
- [ ] Call `runtime.shutdown()` during app termination.

### Step 6: Verify and commit Task 3

- [ ] Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppRuntimeTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingControllerPanelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelTeamsAutoMeetingTests
```

- [ ] Commit:

```bash
git add \
  Sources/RecorderApp/AppRuntime.swift \
  Sources/RecorderApp/LocalMeetingRecorderApp.swift \
  Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/AppRuntimeTests.swift
git commit -m "Wire recording controller into app runtime"
```

---

## Task 4: Review, Full Verification, Packaging, And Live Acceptance

**Files:**

- Modify only files required by review findings.

### Step 1: Independent review

- [ ] Ask a fresh reviewer to compare the whole branch against:
  - `docs/superpowers/specs/2026-07-28-floating-recording-controller-design.md`;
  - this implementation plan;
  - base commit `6aaf58d3b493132e878a1732342ef01ecfeb8e3d`.
- [ ] Resolve all correctness, lifecycle, accessibility, focus, and missing-test findings.
- [ ] Rerun each affected focused suite after fixes.

### Step 2: Full automated verification

- [ ] Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 \
  .build/app/Local\ Meeting\ Recorder.app
```

- [ ] Confirm the main checkout remains untouched:

```bash
git -C /Users/apple/Documents/recorder status --short
```

### Step 3: Install the verified candidate

- [ ] Quit only the idle installed Recorder app after confirming no recording is active.
- [ ] Install from this worktree with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/install-app.sh
```

- [ ] Launch `/Applications/Local Meeting Recorder.app`.
- [ ] If Screen Recording permission is stale because the ad-hoc CDHash changed, pause for explicit approval before changing macOS privacy settings.

### Step 4: Live macOS acceptance

- [ ] Verify a manual recording:
  - starts with Screen Off;
  - panel appears only after recording is active;
  - panel is above another app and does not take focus;
  - elapsed time advances once per second;
  - Screen On/Off stays synchronized with the main window;
  - unavailable/reconnecting status remains readable;
  - Stop enters Finalizing, disables controls, saves the file, then dismisses the panel.
- [ ] Verify a Teams automatic recording uses the same panel and Stop suppresses auto-restart for the current meeting.
- [ ] Verify the next recording presents exactly one panel again.

### Step 5: Final commit and push

- [ ] Confirm clean feature worktree and review commit history:

```bash
git status --short
git log --oneline --decorate -8
```

- [ ] Push:

```bash
git push origin codex/floating-recording-window
git ls-remote origin refs/heads/codex/floating-recording-window
```

- [ ] Report exact commit, focused/full test counts, codesign result, live acceptance result, installed app path, and intentionally untouched main-checkout changes.
