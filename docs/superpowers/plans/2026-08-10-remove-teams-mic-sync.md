# Remove Teams Microphone Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Teams microphone status/control and make the floating microphone button a reliable Recorder-local mute toggle.

**Architecture:** Recorder microphone mute has only two authorities: the explicit Recorder-local setting and the native input-device setting. Remove the Teams Accessibility adapter, polling coordinator, UI projection, and mute-gate source; keep the protocol-v1 `teamsMicState` JSON field as the constant `notMonitored` while omitting it from human CLI output.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Package Manager, XCTest, Unix-socket CLI protocol v1.

## Global Constraints

- Keep Teams meeting-window detection, automatic recording, meeting confirmation/suppression, and Teams screen capture unchanged.
- Keep Recorder-local and native input/AirPods mute handling.
- Keep `RecorderControlStatus.teamsMicState` required in protocol v1 and emit exactly `notMonitored` from the app.
- Do not add a replacement feature flag, retry, dormant Teams mute service, or new abstraction.
- Do not touch Windows implementation, branches, or PRs.
- Preserve unrelated untracked files in the main workspace.
- Run only the focused tests named below; do not expand to an Accessibility matrix or GUI automation.

---

## File map

- `Sources/RecorderApp/Views/RecordingControllerPanel.swift`: route the floating microphone button to Recorder-local mute and remove Teams microphone UI.
- `Sources/RecorderApp/Views/RecordingControllerPresentation.swift`: remove the obsolete Teams/Recorder microphone comparison presentation.
- `Sources/RecorderApp/AppModel.swift`: remove Teams mute state, injection, polling, commands, and lifecycle wiring.
- `Sources/RecorderApp/Teams/MicrophoneMuteCoordinator.swift`: retain only local and native input mute authorities.
- `Sources/RecorderApp/Control/AppModelControlAdapter.swift`: emit the protocol compatibility value `notMonitored`.
- `Sources/RecorderControlCLI/RecorderCLIApplication.swift`: omit Teams microphone state from human output.
- `Package.swift`: stop linking `ApplicationServices`, which has no remaining consumer.
- `Sources/RecorderApp/Teams/TeamsMuteAccessibilityAdapter.swift`: delete.
- `Sources/RecorderApp/Teams/TeamsMuteSyncCoordinator.swift`: delete.
- `Tests/RecorderAppTests/TeamsMuteAccessibilityClassifierTests.swift`: delete with its production unit.
- `Tests/RecorderAppTests/TeamsMuteSyncCoordinatorTests.swift`: delete with its production unit.
- Focused existing tests listed per task: update only assertions and fakes made obsolete by the removal.

---

### Task 1: Make the floating microphone control Recorder-local

**Files:**
- Modify: `Tests/RecorderAppTests/RecordingControllerRenderTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingControllerPanelTests.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPresentation.swift`

**Interfaces:**
- Consumes: `AppModel.toggleRecorderMicMute(source:)`, `AppModel.localMicMuted`, and `RecordingEngine.micMuted`.
- Produces: the floating panel microphone action calls `model.toggleRecorderMicMute(source: "Floating panel")`; no Teams microphone status/action is rendered.

- [ ] **Step 1: Add the failing production-wiring regression**

Add an async render test that hosts the real `RecordingControllerView`, selects a Teams process, injects a controller that always returns unknown, clicks the production microphone button twice, and expects local mute to clear without any Teams calls:

```swift
func testProductionMicrophoneButtonMutesThenUnmutesRecorderLocally() async throws {
    let teamsController = RecordingControllerUnknownTeamsMuteController()
    let model = AppModel(
        inputDevices: { [] },
        defaultInputDeviceID: { nil },
        performStartupWork: false,
        teamsMuteController: teamsController
    )
    model.resolvedCaptureSelection = .application(.init(
        processID: 42,
        bundleIdentifier: "com.microsoft.teams2",
        name: "Microsoft Teams"
    ))
    let host = PanelRenderHost(
        rootView: RecordingControllerView(model: model),
        size: .init(width: 390, height: 180)
    )
    defer { host.close() }

    try host.click(RecordingControllerAccessibility.microphoneMuteID)
    await waitUntil { model.localMicMuted }
    try host.click(RecordingControllerAccessibility.microphoneMuteID)
    await waitUntil { !model.localMicMuted }

    XCTAssertFalse(model.localMicMuted)
    XCTAssertTrue(teamsController.setMutedCalls.isEmpty)
    XCTAssertFalse(host.contains("recording-controller-teams-microphone-status"))
    XCTAssertFalse(host.contains("recording-controller-enable-teams-accessibility"))
}
```

Use a private `@unchecked Sendable` test fake with a lock-protected `setMutedCalls`, `readState` and `setMuted` returning `.unknown(.controlNotFound)`, plus a no-op `requestPermission()`. Add the same bounded `waitUntil` helper pattern already used in `AppModelMuteTests`.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-remove-teams-mic-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-remove-teams-mic-swiftpm \
swift test --disable-sandbox --filter RecordingControllerRenderTests/testProductionMicrophoneButtonMutesThenUnmutesRecorderLocally
```

Expected: FAIL because the second click receives unknown Teams state, retains `localMicMuted == true`, and the Teams status controls remain rendered.

- [ ] **Step 3: Route the production button locally and remove Teams microphone UI**

In `RecordingControllerView`, replace the async Teams action and presentation arguments with the local action:

```swift
toggleMicrophoneMute: {
    model.toggleRecorderMicMute(source: "Floating panel")
},
```

Remove `teamsMicrophoneStatusID`, `teamsAccessibilityID`, `microphonePresentation`, and `requestTeamsAccessibilityPermission` from the panel types. The microphone row should use the existing compact status fallback:

```swift
Circle()
    .fill(statusColor)
    .frame(width: 6, height: 6)
Text(status.rawValue)
    .font(.caption2)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .frame(width: 72, alignment: .trailing)
```

Delete `RecordingControllerMicrophonePresentation` from `RecordingControllerPresentation.swift` and delete its two obsolete Teams comparison/permission tests from `RecordingControllerPanelTests.swift`.

- [ ] **Step 4: Run the focused UI tests and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-remove-teams-mic-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-remove-teams-mic-swiftpm \
swift test --disable-sandbox --filter 'RecordingController(Render|Panel)Tests'
```

Expected: all selected tests PASS; the production double-click test records zero Teams calls.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/RecorderApp/Views/RecordingControllerPanel.swift Sources/RecorderApp/Views/RecordingControllerPresentation.swift Tests/RecorderAppTests/RecordingControllerRenderTests.swift Tests/RecorderAppTests/RecordingControllerPanelTests.swift
git commit -m "fix: make floating mic control recorder local"
```

---

### Task 2: Remove Teams mute runtime and authority

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Modify: `Sources/RecorderApp/Teams/MicrophoneMuteCoordinator.swift`
- Modify: `Sources/RecorderApp/Control/AppModelControlAdapter.swift`
- Delete: `Sources/RecorderApp/Teams/TeamsMuteAccessibilityAdapter.swift`
- Delete: `Sources/RecorderApp/Teams/TeamsMuteSyncCoordinator.swift`
- Modify: `Tests/RecorderAppTests/MicrophoneMuteCoordinatorTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelMuteTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelControlAdapterTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingControllerRenderTests.swift`
- Delete: `Tests/RecorderAppTests/TeamsMuteAccessibilityClassifierTests.swift`
- Delete: `Tests/RecorderAppTests/TeamsMuteSyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MicrophoneMuteGate.setLocalMuted`, `setNativeInputMuted`, and `snapshot`.
- Produces: `MicrophoneMuteSnapshot(localMuted:nativeInputMuted:effectiveMuted:)`; `RecorderControlStatus.teamsMicState == "notMonitored"`.

- [ ] **Step 1: Change focused tests to the new two-authority contract**

Replace Teams-authority cases in `MicrophoneMuteCoordinatorTests` with the exact snapshot contract:

```swift
func testSnapshotContainsOnlyLocalNativeAndEffectiveMuteState() {
    XCTAssertEqual(
        MicrophoneMuteGate { _ in }.snapshot,
        MicrophoneMuteSnapshot(
            localMuted: false,
            nativeInputMuted: false,
            effectiveMuted: false
        )
    )
}
```

In `AppModelControlAdapterTests`, change the status expectation:

```swift
XCTAssertEqual(status.teamsMicState, "notMonitored")
```

Delete `testStatusProjectsKnownTeamsMicStates` because known Teams microphone states no longer exist. Keep the Task 1 double-click render test, but remove its Teams-controller injection and call-count assertion so it continues to test the real local UI path after the protocol is deleted.

- [ ] **Step 2: Run the contract tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-remove-teams-mic-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-remove-teams-mic-swiftpm \
swift test --disable-sandbox --filter 'LocalMicrophoneMuteCoordinatorTests|AppModelControlAdapterTests'
```

Expected: compile failure because `MicrophoneMuteSnapshot` still requires `teamsMuted`, and/or assertion failure because the adapter still emits `unknown`.

- [ ] **Step 3: Remove the Teams mute source from the microphone gate**

Make the coordinator and snapshot exactly two-source:

```swift
struct MicrophoneMuteCoordinator {
    private(set) var localMuted: Bool
    private(set) var nativeInputMuted = false

    var effectiveMuted: Bool {
        localMuted || nativeInputMuted
    }
}

struct MicrophoneMuteSnapshot: Equatable, Sendable {
    let localMuted: Bool
    let nativeInputMuted: Bool
    let effectiveMuted: Bool
}
```

Remove `setTeamsMuted` from both `MicrophoneMuteCoordinator` and `MicrophoneMuteGate`, and remove the `teamsMuted` argument from `makeSnapshot()`.

- [ ] **Step 4: Remove AppModel Teams mute wiring and lifecycle calls**

From `AppModel`, remove:

- `teamsMicMuteState`, `teamsMuteSyncCoordinator`, and `isFloatingRecordingPanelActive`.
- `teamsMuteController` and `teamsMuteTick` initializer parameters.
- coordinator construction and callbacks.
- `toggleTeamsAndRecorderMicMute`, `setTeamsAndRecorderMicMuted`, `requestTeamsAccessibilityPermission`, `setFloatingRecordingPanelActive`, and `refreshTeamsMutePolling`.
- every `resetTeamsSource()` and mute-poll refresh call from shutdown, meeting end, source change, process termination, and recording observation.

Do not alter neighboring `TeamsAutoMeetingCoordinator`, `TeamsLocalMeetingDetector`, Teams process selection, or Teams screen refresh/capture calls.

In `RecordingControllerCoordinator`, remove only the two calls that mark the floating panel active/inactive. Keep its present/dismiss episode behavior unchanged.

- [ ] **Step 5: Remove the AX implementation and dependency**

Delete the two production files and their dedicated tests:

```text
Sources/RecorderApp/Teams/TeamsMuteAccessibilityAdapter.swift
Sources/RecorderApp/Teams/TeamsMuteSyncCoordinator.swift
Tests/RecorderAppTests/TeamsMuteAccessibilityClassifierTests.swift
Tests/RecorderAppTests/TeamsMuteSyncCoordinatorTests.swift
```

Remove `.linkedFramework("ApplicationServices")` from `Package.swift`. Remove the obsolete Teams controller fakes and initializer arguments from `AppModelMuteTests`, `AppModelControlAdapterTests`, and `RecordingControllerRenderTests`.

- [ ] **Step 6: Emit the compatibility value without observing Teams**

In `AppModelControlAdapter.status()`, replace the helper call with the literal compatibility value:

```swift
teamsMicState: "notMonitored",
```

Delete the private `teamsMicState()` helper. Do not change `RecorderControlStatus` or its Codable shape.

- [ ] **Step 7: Run focused runtime tests and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-remove-teams-mic-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-remove-teams-mic-swiftpm \
swift test --disable-sandbox --filter 'LocalMicrophoneMuteCoordinatorTests|AppModelMuteTests|AppModelControlAdapterTests|RecordingController(Render|Panel)Tests'
```

Expected: all selected tests PASS with no Teams mute types, fakes, polling, or AX imports remaining.

- [ ] **Step 8: Verify the removed implementation has no source/test references**

Run:

```bash
rg -n 'TeamsMute|TeamsMicMuteState|teamsMicMuteState|setTeamsMuted|toggleTeamsAndRecorderMicMute|requestTeamsAccessibilityPermission|recording-controller-teams-microphone-status|recording-controller-enable-teams-accessibility|ApplicationServices' Package.swift Sources Tests
```

Expected: no output. `teamsMicState` remains only as the protocol-v1 wire property, adapter literal, and CLI/control tests; the narrower camel-case query is intentionally not part of this removal scan.

- [ ] **Step 9: Commit Task 2**

```bash
git add Package.swift Sources/RecorderApp/AppModel.swift Sources/RecorderApp/Views/RecordingControllerPanel.swift Sources/RecorderApp/Teams/MicrophoneMuteCoordinator.swift Sources/RecorderApp/Control/AppModelControlAdapter.swift Sources/RecorderApp/Teams/TeamsMuteAccessibilityAdapter.swift Sources/RecorderApp/Teams/TeamsMuteSyncCoordinator.swift Tests/RecorderAppTests/MicrophoneMuteCoordinatorTests.swift Tests/RecorderAppTests/AppModelMuteTests.swift Tests/RecorderAppTests/AppModelControlAdapterTests.swift Tests/RecorderAppTests/RecordingControllerRenderTests.swift Tests/RecorderAppTests/TeamsMuteAccessibilityClassifierTests.swift Tests/RecorderAppTests/TeamsMuteSyncCoordinatorTests.swift
git commit -m "refactor: remove Teams microphone sync"
```

---

### Task 3: Preserve CLI v1 JSON and simplify human status

**Files:**
- Modify: `Tests/RecorderControlCLITests/RecorderCLIApplicationTests.swift`
- Modify: `Tests/RecorderControlTests/RecorderControlMessagesTests.swift`
- Modify: `Sources/RecorderControlCLI/RecorderCLIApplication.swift`

**Interfaces:**
- Consumes: required protocol-v1 `RecorderControlStatus.teamsMicState: String`.
- Produces: JSON still includes `"teamsMicState":"notMonitored"`; human output has no `Teams mic state:` line.

- [ ] **Step 1: Add failing CLI compatibility assertions**

Change the CLI fixture default to:

```swift
teamsMicState: "notMonitored",
```

Extend `testStatusRendersStableHumanLabels`:

```swift
XCTAssertFalse(
    output.lines.contains { $0.hasPrefix("Teams mic state:") }
)
```

In `RecorderControlMessagesTests`, set the round-trip fixture to `notMonitored` and continue asserting the decoded status equals the encoded status. Keep the legacy protocol-v1 fixture's `teamsMicState` key required.

- [ ] **Step 2: Run the human CLI test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-remove-teams-mic-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-remove-teams-mic-swiftpm \
swift test --disable-sandbox --filter RecorderCLIApplicationTests/testStatusRendersStableHumanLabels
```

Expected: FAIL because human status still contains `Teams mic state: notMonitored`.

- [ ] **Step 3: Remove only the human-readable line**

Delete this array element from `RecorderCLIApplication.humanLines(for:)`:

```swift
"Teams mic state: \(status.teamsMicState)",
```

Do not change JSON encoding or `RecorderControlStatus`.

- [ ] **Step 4: Run CLI and wire tests and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-remove-teams-mic-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-remove-teams-mic-swiftpm \
swift test --disable-sandbox --filter 'RecorderCLIApplicationTests|RecorderControlMessagesTests'
```

Expected: all selected tests PASS; human output omits the Teams line and JSON round-trips `notMonitored`.

- [ ] **Step 5: Verify retained Teams auto-recording and screen capture**

Run once:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-remove-teams-mic-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-remove-teams-mic-swiftpm \
swift test --disable-sandbox --filter 'AppModelTeamsAutoMeetingTests|TeamsAutoMeetingCoordinatorTests|TeamsLocalMeetingDetectorTests|TeamsMeetingWindowResolverTests|AppModelScreenCaptureTests'
```

Expected: all selected tests PASS, proving the retained Teams meeting and screen paths still compile and behave as before.

- [ ] **Step 6: Review the final diff and commit Task 3**

Run:

```bash
git diff --check
git status --short
```

Confirm the diff contains only this plan's macOS app/CLI/tests and does not include unrelated untracked files or Windows paths. Then commit:

```bash
git add Sources/RecorderControlCLI/RecorderCLIApplication.swift Tests/RecorderControlCLITests/RecorderCLIApplicationTests.swift Tests/RecorderControlTests/RecorderControlMessagesTests.swift
git commit -m "fix: report Teams mic as not monitored"
```

---

## Final verification

Run the three focused groups exactly once more only if a post-commit diff review required a code change. Otherwise use the fresh GREEN outputs from Tasks 1–3. Confirm:

```bash
git diff --check HEAD~3..HEAD
git status --short --branch
git log -4 --oneline
```

Expected: three implementation commits after the design/plan commits, no tracked changes, and only the user's pre-existing untracked files.
