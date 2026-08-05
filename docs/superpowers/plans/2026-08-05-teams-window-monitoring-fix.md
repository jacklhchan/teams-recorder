# Teams Window Monitoring Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect joined Teams meeting windows within about three seconds, ignore Calendar and pre-join windows, and re-arm automatic recording for later meetings.

**Architecture:** Keep the existing one-second ScreenCaptureKit loop and local detector. Add exact first-title-segment classification in `TeamsMeetingWindowResolver`, start the existing loop when persisted Auto Mode resolves Teams, and observe Teams launch/termination with `NSWorkspace` without adding Accessibility permission.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Combine, ScreenCaptureKit, XCTest.

## Global Constraints

- One scan per second and three consecutive positive observations.
- Preserve the existing 30-observation meeting-end confirmation while Teams runs.
- No Accessibility permission or Teams private API.
- No changes to countdown, ownership, mute, or screen-capture controls.
- Two focused automated groups only; no tenant, language, size, or pop-out matrix.

---

### Task 1: Reject Teams shell and pre-join windows

**Files:**
- Modify: `Sources/RecorderApp/Capture/TeamsMeetingWindow.swift:47-95`
- Test: `Tests/RecorderAppTests/TeamsMeetingWindowResolverTests.swift`

**Interfaces:**
- Consumes: `TeamsWindowSnapshot.title` and `rejectionReasons(for:)`.
- Produces: exact normalized first-title-segment rejection through existing `.utilityTitle`.

- [ ] **Step 1: Write the failing same-window lifecycle test**

Add:

```swift
func testLocalObservationTracksSameWindowFromCalendarThroughMeetingAndBack() {
    var resolver = TeamsMeetingWindowResolver()
    let identity = TeamsWindowIdentity(processID: 7, windowID: 42)

    XCTAssertEqual(
        resolver.observeLocal(
            [snapshot(identity: identity, title: "Calendar | pccw.com | Microsoft Teams")],
            now: beforeMeeting
        ),
        .waiting
    )
    XCTAssertEqual(
        resolver.observeLocal(
            [snapshot(identity: identity, title: "Meeting join | Weekly sync | Microsoft Teams")],
            now: meetingStarted
        ),
        .waiting
    )
    assertReady(
        resolver.observeLocal(
            [snapshot(identity: identity, title: "Weekly sync | pccw.com | Microsoft Teams")],
            now: meetingStarted.addingTimeInterval(1)
        ),
        identity: identity
    )
    XCTAssertEqual(
        resolver.observeLocal(
            [snapshot(identity: identity, title: "Calendar | pccw.com | Microsoft Teams")],
            now: meetingStarted.addingTimeInterval(2)
        ),
        .waiting
    )
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TeamsMeetingWindowResolverTests.testLocalObservationTracksSameWindowFromCalendarThroughMeetingAndBack
```

Expected: FAIL because Calendar currently resolves `.ready`.

- [ ] **Step 3: Implement minimal classification**

Use the first normalized segment before `|`:

```swift
static let nonMeetingTitleSegments: Set<String> = [
    "activity", "calendar", "calls", "chat", "copilot",
    "meeting join", "microsoft teams helper", "notification",
    "onedrive", "settings", "teams"
]

private static func firstTitleSegment(_ title: String) -> String {
    String(title.split(separator: "|", maxSplits: 1).first ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}
```

In `rejectionReasons(for:)`, add `.utilityTitle` when the set contains the
first segment. Keep size, layer, manual override, ambiguity, and ranking intact.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TeamsMeetingWindowResolverTests
```

Expected: the resolver suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderApp/Capture/TeamsMeetingWindow.swift Tests/RecorderAppTests/TeamsMeetingWindowResolverTests.swift
git commit -m "fix: distinguish Teams meetings from shell windows"
```

### Task 2: Keep Auto Mode monitoring alive

**Files:**
- Modify: `Sources/RecorderApp/AppModel.swift:130-190,500-525,644-655,930-975`
- Test: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`
- Test: `Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift`

**Interfaces:**
- Consumes: `restartTeamsScreenRefreshIfNeeded()`, `refreshCaptureApplications()`, persisted Auto Mode, and `NSWorkspace` lifecycle notifications.
- Produces: one idempotent polling loop for selected Teams plus refresh/re-arm when its process is replaced.

- [ ] **Step 1: Write the failing persisted-Auto polling test**

Extend `makeFixture` with `autoMeetingEnabled: Bool = false`, set the defaults
key before constructing `AppModel`, then add:

```swift
func testPersistedAutoModeStartsWindowPollingWhenTeamsSelectionResolves() async {
    let ticker = TeamsScreenTestTicker()
    let fixture = makeFixture(
        provider: .normal,
        teamsTicker: ticker,
        autoMeetingEnabled: true
    )
    fixture.source.applications = [teamsApplication]
    fixture.model.captureSelection = .init(
        mode: .selectedApplication,
        selectedBundleIdentifier: teamsApplication.bundleIdentifier
    )

    fixture.model.refreshCaptureApplications()
    await waitUntil { fixture.source.teamsRefreshCount >= 1 }
    let baseline = fixture.source.teamsRefreshCount
    await ticker.fire()
    await waitUntil { fixture.source.teamsRefreshCount == baseline + 1 }

    XCTAssertTrue(fixture.model.teamsAutoMeetingEnabled)
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppModelScreenCaptureTests.testPersistedAutoModeStartsWindowPollingWhenTeamsSelectionResolves
```

Expected: FAIL because only the immediate refresh runs.

- [ ] **Step 3: Start the existing loop from source changes**

In `handleTeamsScreenSourceChange()`:

```swift
guard selectedTeamsApplication != nil else { return }
restartTeamsScreenRefreshIfNeeded()
Task { @MainActor [weak self] in
    await self?.refreshTeamsScreenCaptureNow()
}
```

Do not add a second timer.

- [ ] **Step 4: Observe Teams process replacement**

Add `teamsApplicationLifecycleCancellables`. During production startup, merge
`NSWorkspace.didLaunchApplicationNotification` and
`NSWorkspace.didTerminateApplicationNotification`, filter
`NSRunningApplication.bundleIdentifier == "com.microsoft.teams2"`, and call
`refreshCaptureApplications()`. If the selected Teams PID terminates, first
call `teamsAutoMeetingCoordinator.handleConfirmedMeetingEnd()`. Clear this
cancellable set and invalidate the refresh task in `shutdown()`.

Use this exact sink body:

```swift
.sink { [weak self] application in
    guard let self else { return }
    if application.isTerminated,
       self.selectedTeamsApplication?.processID
            == application.processIdentifier {
        self.teamsAutoMeetingCoordinator.handleConfirmedMeetingEnd()
    }
    self.refreshCaptureApplications()
}
```

- [ ] **Step 5: Add the two-meeting re-arm regression**

Add one AppModel test using window ID 71:

```swift
fixture.source.teamsWindows = [localTeamsWindow(id: 71)]
fixture.model.setTeamsAutoMeetingEnabled(true)
await fixture.model.refreshTeamsScreenCaptureNow()
await fixture.model.refreshTeamsScreenCaptureNow()
fixture.model.cancelTeamsAutoMeetingCountdown()
XCTAssertEqual(fixture.model.teamsAutoMeetingState, .suppressedUntilMeetingEnd)

fixture.source.teamsWindows = [localTeamsWindow(
    id: 71,
    title: "Calendar | pccw.com | Microsoft Teams"
)]
for _ in 0..<30 { await fixture.model.refreshTeamsScreenCaptureNow() }
XCTAssertEqual(fixture.model.teamsAutoMeetingState, .waitingForMeeting)

fixture.source.teamsWindows = [localTeamsWindow(
    id: 71,
    title: "Second sync | pccw.com | Microsoft Teams"
)]
for _ in 0..<3 { await fixture.model.refreshTeamsScreenCaptureNow() }
XCTAssertEqual(
    fixture.model.teamsAutoMeetingState,
    .startCountdown(secondsRemaining: 5)
)
```

Extend the local test helper with an optional `title` parameter rather than
duplicating snapshot construction.

- [ ] **Step 6: Verify focused suites**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'AppModelScreenCaptureTests|AppModelTeamsAutoMeetingTests|TeamsAutoMeetingCoordinatorTests'
```

Expected: all selected tests pass without hangs.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderApp/AppModel.swift Tests/RecorderAppTests/AppModelScreenCaptureTests.swift Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift
git commit -m "fix: keep Teams auto meeting monitoring active"
```

### Task 3: Verify the accepted Meet now flow

**Files:**
- Verify only; no additional source changes planned.

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces: automated and installed-app evidence for two independent meetings.

- [ ] **Step 1: Run the complete suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: full suite passes with only documented skips.

- [ ] **Step 2: Build and install**

Use the repository release workflow to preserve version `0.2.0`, build `335`,
replace `/Applications/Local Meeting Recorder Staging.app`, and verify both
bundle values.

- [ ] **Step 3: Run the single acceptance flow**

Calendar idle for five seconds must remain waiting. Join the first Meet now and
expect detection within about three seconds, the five-second countdown, and an
automatic recording. Leave and wait for automatic stop/re-arm. Join a second
Meet now and expect a fresh countdown and second automatic recording. Leave the
test meeting after collecting evidence.

- [ ] **Step 4: Inspect final state**

```bash
git status --short
git log -5 --oneline
```

Expected: only the user's pre-existing unrelated untracked files remain, and the
implementation commits are on `main`.

