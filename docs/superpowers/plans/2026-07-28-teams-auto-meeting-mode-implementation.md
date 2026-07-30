# Teams Auto Meeting Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Teams Auto Meeting Mode that shows a silent, cancellable five-second countdown, starts one normal recording, and stops only that automatically owned recording after ten continuous seconds of authoritative meeting-end state.

**Architecture:** A new deterministic `TeamsAutoMeetingCoordinator` owns countdown, debounce, suppression, and command emission without touching capture APIs. `AppModel` remains the sole integration boundary for the shared Teams client and `CaptureLifecycleGate`, tracks manual versus automatic recording ownership, and exposes state to a compact Teams settings row. A replaceable non-activating `NSPanel` presenter renders the countdown without taking focus from Teams.

**Tech Stack:** Swift 5.9, Swift Concurrency, Combine, SwiftUI, AppKit, XCTest, Microsoft Teams desktop Third-party App API, existing ScreenCaptureKit recording pipeline.

## Global Constraints

- Target macOS 26.0 and keep the existing Swift Package dependency set unchanged.
- Auto Meeting Mode is opt-in and persisted under `teamsAutoMeetingEnabled`; its default is `false`.
- A paired authoritative `isInMeeting == true` event starts one silent, cancellable five-second countdown.
- A recording owned by Teams automation stops only after ten continuous seconds of authoritative `isInMeeting == false`.
- Teams API connection loss, heartbeat failure, pairing state, missing meeting state, and reconnect status never mean that a meeting ended.
- Manual recordings are never auto-stopped.
- A manual stop or countdown cancellation suppresses automatic restart until the meeting ends.
- Automatic start uses the current capture source, microphone, output folder, storage policy, and existing `CaptureLifecycleGate`.
- Automatic start never opens a macOS permission prompt or System Settings.
- Screen capture remains off at every recording start and may be enabled manually later.
- Teams Mute Sync and Teams Auto Recording can keep the one Teams client alive independently.
- Disabling Auto Meeting Mode leaves an active automatic recording running under manual ownership.
- Preserve synchronous Teams mute fail-closed behavior and existing stale-callback generation protection.
- Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for every Swift build and test command.
- Follow strict RED -> GREEN TDD and commit each task independently.

---

## File Map

- Create `Sources/RecorderApp/Teams/TeamsAutoMeetingCoordinator.swift`
  - Owns auto-meeting state, timer generations, meeting epochs, suppression, and commands.
- Create `Tests/RecorderAppTests/TeamsAutoMeetingCoordinatorTests.swift`
  - Pure deterministic coverage for five-second start and ten-second stop timing.
- Modify `Sources/RecorderApp/AppModel.swift`
  - Shares the Teams client between mute sync and auto mode, tracks recording ownership, and executes coordinator commands through the existing lifecycle gate.
- Create `Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift`
  - Integration coverage for Teams client ownership, permission behavior, capture start/stop, and manual overrides.
- Create `Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift`
  - Defines the replaceable presenter, non-activating AppKit panel, and compact SwiftUI countdown content.
- Modify `Sources/RecorderApp/ContentView.swift`
  - Adds the persisted Auto Recording switch, status, cancel action, and countdown-panel binding.
- Create `Tests/RecorderAppTests/TeamsAutoMeetingPresentationTests.swift`
  - Tests deterministic status text, icon, detail, and cancel visibility.
- Modify `README.md`
  - Documents setup, exact timing, ownership, screen-off default, and disconnect behavior.

---

### Task 1: Deterministic Teams Auto Meeting Coordinator

**Files:**
- Create: `Sources/RecorderApp/Teams/TeamsAutoMeetingCoordinator.swift`
- Create: `Tests/RecorderAppTests/TeamsAutoMeetingCoordinatorTests.swift`

**Interfaces:**
- Consumes: authoritative `Bool` meeting state and an injected `@Sendable () async -> Void` one-second tick.
- Produces:

```swift
enum TeamsAutoMeetingState: Equatable, Sendable {
    case disabled
    case waitingForMeeting
    case startCountdown(secondsRemaining: Int)
    case starting
    case automaticRecording
    case stopCountdown(secondsRemaining: Int)
    case suppressedUntilMeetingEnd
    case startBlocked(String)
    case startFailed(String)
}

enum TeamsAutoMeetingCommand: Equatable, Sendable {
    case startRecording
    case cancelAutomaticStart
    case stopRecording
    case transferRecordingToManual
}

@MainActor
final class TeamsAutoMeetingCoordinator {
    private(set) var state: TeamsAutoMeetingState
    var onStateChange: ((TeamsAutoMeetingState) -> Void)?
    var onCommand: ((TeamsAutoMeetingCommand) -> Void)?

    init(
        startCountdownSeconds: Int = 5,
        stopDebounceSeconds: Int = 10,
        tick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    )

    func setEnabled(_ enabled: Bool)
    func handleMeetingState(isInMeeting: Bool)
    func cancelCountdown()
    func manualRecordingStarted()
    func suppressUntilMeetingEnd()
    func automaticStartSucceeded()
    func automaticStartBlocked(_ message: String)
    func automaticStartFailed(_ message: String)
    func automaticStopCompleted()
    func invalidate()
}
```

- [ ] **Step 1: Write the failing coordinator tests**

Create `TeamsAutoMeetingCoordinatorTests.swift` with a `ManualAutoMeetingTicker`
actor matching the existing test ticker pattern:

```swift
private actor ManualAutoMeetingTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
            return
        }
        await withCheckedContinuation { continuations.append($0) }
    }

    func fire() {
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }
    }
}
```

Add these concrete tests:

```swift
@MainActor
func testMeetingStartCountsDownFiveTicksAndEmitsOneStart() async {
    let ticker = ManualAutoMeetingTicker()
    let coordinator = TeamsAutoMeetingCoordinator(
        tick: { await ticker.waitForTick() }
    )
    var states: [TeamsAutoMeetingState] = []
    var commands: [TeamsAutoMeetingCommand] = []
    coordinator.onStateChange = { states.append($0) }
    coordinator.onCommand = { commands.append($0) }

    coordinator.setEnabled(true)
    coordinator.handleMeetingState(isInMeeting: true)
    XCTAssertEqual(coordinator.state, .startCountdown(secondsRemaining: 5))

    for expected in [4, 3, 2, 1] {
        await ticker.fire()
        await Task.yield()
        XCTAssertEqual(
            coordinator.state,
            .startCountdown(secondsRemaining: expected)
        )
    }
    await ticker.fire()
    await Task.yield()

    XCTAssertEqual(coordinator.state, .starting)
    XCTAssertEqual(commands, [.startRecording])
    XCTAssertTrue(states.contains(.startCountdown(secondsRemaining: 5)))
}

@MainActor
func testTrueDuringStopDebounceCancelsAutomaticStop() async {
    let ticker = ManualAutoMeetingTicker()
    let coordinator = TeamsAutoMeetingCoordinator(
        tick: { await ticker.waitForTick() }
    )
    var commands: [TeamsAutoMeetingCommand] = []
    coordinator.onCommand = { commands.append($0) }
    coordinator.setEnabled(true)
    coordinator.handleMeetingState(isInMeeting: true)
    for _ in 0..<5 {
        await ticker.fire()
        await Task.yield()
    }
    coordinator.automaticStartSucceeded()
    coordinator.handleMeetingState(isInMeeting: false)
    XCTAssertEqual(coordinator.state, .stopCountdown(secondsRemaining: 10))

    await ticker.fire()
    await Task.yield()
    coordinator.handleMeetingState(isInMeeting: true)

    XCTAssertEqual(coordinator.state, .automaticRecording)
    XCTAssertEqual(commands, [.startRecording])
}
```

Also assert:

- repeated true state does not restart the five-second timer;
- `cancelCountdown()` enters `.suppressedUntilMeetingEnd`;
- suppression survives more true events and clears on false;
- false during start countdown cancels without a start command;
- false during `.starting` emits `.cancelAutomaticStart`;
- automatic readiness blockage stays `.startBlocked` until false;
- automatic start failure stays `.startFailed` until false;
- ten false-state ticks emit exactly one `.stopRecording`;
- disabling during `.automaticRecording` emits
  `.transferRecordingToManual`;
- stale ticks after cancel or disable do not change state or emit commands.

- [ ] **Step 2: Run the coordinator tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsAutoMeetingCoordinatorTests
```

Expected: compilation fails because `TeamsAutoMeetingCoordinator`,
`TeamsAutoMeetingState`, and `TeamsAutoMeetingCommand` do not exist.

- [ ] **Step 3: Implement the minimal coordinator**

Create `TeamsAutoMeetingCoordinator.swift`. Use one timer task and a generation
counter:

```swift
@MainActor
final class TeamsAutoMeetingCoordinator {
    private enum TimerKind {
        case start
        case stop
    }

    private let startCountdownSeconds: Int
    private let stopDebounceSeconds: Int
    private let tick: @Sendable () async -> Void
    private var timerTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isEnabled = false
    private var isInMeeting = false

    private(set) var state: TeamsAutoMeetingState = .disabled {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((TeamsAutoMeetingState) -> Void)?
    var onCommand: ((TeamsAutoMeetingCommand) -> Void)?

    init(
        startCountdownSeconds: Int = 5,
        stopDebounceSeconds: Int = 10,
        tick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    ) {
        precondition(startCountdownSeconds > 0)
        precondition(stopDebounceSeconds > 0)
        self.startCountdownSeconds = startCountdownSeconds
        self.stopDebounceSeconds = stopDebounceSeconds
        self.tick = tick
    }
}
```

Implement state transitions with these exact rules:

```swift
func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    invalidateTimer()
    if enabled {
        state = .waitingForMeeting
        if isInMeeting {
            beginTimer(.start, seconds: startCountdownSeconds)
        }
    } else {
        switch state {
        case .starting:
            onCommand?(.cancelAutomaticStart)
        case .automaticRecording, .stopCountdown:
            onCommand?(.transferRecordingToManual)
        default:
            break
        }
        state = .disabled
    }
}

func handleMeetingState(isInMeeting: Bool) {
    self.isInMeeting = isInMeeting
    guard isEnabled else { return }

    if isInMeeting {
        switch state {
        case .waitingForMeeting:
            beginTimer(.start, seconds: startCountdownSeconds)
        case .stopCountdown:
            invalidateTimer()
            state = .automaticRecording
        default:
            break
        }
        return
    }

    switch state {
    case .startCountdown:
        invalidateTimer()
        state = .waitingForMeeting
    case .starting:
        onCommand?(.cancelAutomaticStart)
        state = .waitingForMeeting
    case .automaticRecording:
        beginTimer(.stop, seconds: stopDebounceSeconds)
    case .suppressedUntilMeetingEnd, .startBlocked, .startFailed:
        state = .waitingForMeeting
    default:
        break
    }
}
```

`beginTimer` must publish the full initial value, decrement once per injected
tick, verify both `Task.isCancelled` and generation after every suspension, and
emit only one terminal command:

```swift
private func beginTimer(_ kind: TimerKind, seconds: Int) {
    invalidateTimer()
    state = kind == .start
        ? .startCountdown(secondsRemaining: seconds)
        : .stopCountdown(secondsRemaining: seconds)
    let expectedGeneration = generation
    let tick = self.tick
    timerTask = Task { @MainActor [weak self, tick] in
        for remaining in stride(from: seconds - 1, through: 0, by: -1) {
            await tick()
            guard !Task.isCancelled,
                  let self,
                  self.generation == expectedGeneration else { return }
            if remaining > 0 {
                self.state = kind == .start
                    ? .startCountdown(secondsRemaining: remaining)
                    : .stopCountdown(secondsRemaining: remaining)
            } else {
                self.timerTask = nil
                if kind == .start {
                    self.state = .starting
                    self.onCommand?(.startRecording)
                } else {
                    self.onCommand?(.stopRecording)
                }
            }
        }
    }
}
```

Implement the public override/result methods according to the tests, and make
`invalidate()` cancel the task, increment generation, clear closures, and set
state to `.disabled`.

- [ ] **Step 4: Run coordinator tests and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsAutoMeetingCoordinatorTests
```

Expected: all coordinator tests pass with zero failures.

- [ ] **Step 5: Commit Task 1**

```bash
git add \
  Sources/RecorderApp/Teams/TeamsAutoMeetingCoordinator.swift \
  Tests/RecorderAppTests/TeamsAutoMeetingCoordinatorTests.swift
git commit -m "Add Teams auto meeting state machine"
```

---

### Task 2: Share the Teams Client Between Mute Sync and Auto Mode

**Files:**
- Modify: `Sources/RecorderApp/AppModel.swift:41-220`
- Modify: `Sources/RecorderApp/AppModel.swift:1125-1217`
- Create: `Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift`
- Modify: `Tests/RecorderAppTests/TeamsMuteSyncTests.swift:304-690`

**Interfaces:**
- Consumes: `TeamsAutoMeetingCoordinator` from Task 1 and existing
  `TeamsMuteSyncing`, `TeamsMuteRelay`, and `UserDefaults`.
- Produces:

```swift
@Published private(set) var teamsAutoMeetingEnabled: Bool
@Published private(set) var teamsAutoMeetingState: TeamsAutoMeetingState
@Published private(set) var teamsConnectionStatus: TeamsMuteSyncStatus

func setTeamsAutoMeetingEnabled(_ enabled: Bool)
func cancelTeamsAutoMeetingCountdown()
func installTeamsIntegrationIfNeeded()
```

- Preserves `installTeamsMuteSync()` as a compatibility entry point for
  existing tests and callers.

- [ ] **Step 1: Write failing shared-client tests**

Create `AppModelTeamsAutoMeetingTests.swift` with a fake client that counts
`start`, callback replacement, and `stop`:

```swift
private final class AutoMeetingFakeTeamsClient: TeamsMuteSyncing {
    private var callback: ((TeamsMuteSyncEvent) -> Void)?
    private var staleCallbacks: [(TeamsMuteSyncEvent) -> Void] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void) {
        if let callback {
            staleCallbacks.append(callback)
        }
        callback = onEvent
        startCount += 1
    }

    func stop() {
        callback = nil
        stopCount += 1
    }

    func reconnect() {}
    func requestPairing() {}
    func emit(_ event: TeamsMuteSyncEvent) { callback?(event) }
    func emitStale(_ event: TeamsMuteSyncEvent) {
        staleCallbacks.first?(event)
    }
}
```

Add these tests:

```swift
@MainActor
func testAutoModeKeepsTeamsClientRunningWhenMuteSyncIsDisabled() {
    let defaults = makeDefaults()
    defaults.set(false, forKey: "teamsMuteSyncEnabled")
    let client = AutoMeetingFakeTeamsClient()
    let model = makeModel(defaults: defaults, client: client)

    model.setTeamsAutoMeetingEnabled(true)

    XCTAssertTrue(model.teamsAutoMeetingEnabled)
    XCTAssertEqual(client.startCount, 1)
    XCTAssertEqual(client.stopCount, 0)
    XCTAssertEqual(model.teamsMuteSyncStatus, .disabled)
}

@MainActor
func testTeamsClientStopsOnlyWhenBothFeaturesAreDisabled() {
    let defaults = makeDefaults()
    let client = AutoMeetingFakeTeamsClient()
    let model = makeModel(defaults: defaults, client: client)
    model.installTeamsIntegrationIfNeeded()
    model.setTeamsAutoMeetingEnabled(true)

    model.setTeamsMuteSyncEnabled(false)
    XCTAssertEqual(client.stopCount, 0)

    model.setTeamsAutoMeetingEnabled(false)
    XCTAssertEqual(client.stopCount, 1)
}
```

Also assert:

- `teamsAutoMeetingEnabled` defaults false and persists true/false;
- an authoritative meeting event reaches the coordinator while mute sync is
  disabled;
- an unpaired meeting event followed by `.waitingForPairingApproval` does not
  start a countdown;
- a stale replaced callback cannot change coordinator or connection state;
- disabling auto mode does not clear active mute ownership while mute sync is
  enabled;
- existing fail-closed mute tests still synchronously gate audio.

- [ ] **Step 2: Run shared-client tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelTeamsAutoMeetingTests
```

Expected: compilation fails because the new AppModel properties and methods do
not exist.

- [ ] **Step 3: Refactor AppModel Teams transport ownership**

Add the persisted setting and shared connection fields:

```swift
@Published private(set) var teamsAutoMeetingEnabled: Bool
@Published private(set) var teamsAutoMeetingState: TeamsAutoMeetingState
@Published private(set) var teamsConnectionStatus: TeamsMuteSyncStatus = .disabled

private let teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator
private var teamsIntegrationInstalled = false
private var teamsIntegrationGeneration: UInt64 = 0
private var teamsMuteRelayGeneration: UInt64?
private var pendingTeamsMeetingState: TeamsMeetingState?
private var lastAuthorizedTeamsMeetingState: TeamsMeetingState?

private static let teamsAutoMeetingEnabledKey = "teamsAutoMeetingEnabled"
```

Extend `AppModel.init` with an injectable coordinator:

```swift
teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator? = nil
```

Initialize it and the persisted switch before startup work:

```swift
let autoCoordinator = teamsAutoMeetingCoordinator
    ?? TeamsAutoMeetingCoordinator()
self.teamsAutoMeetingCoordinator = autoCoordinator
teamsAutoMeetingEnabled = defaults.bool(
    forKey: Self.teamsAutoMeetingEnabledKey
)
teamsAutoMeetingState = autoCoordinator.state
autoCoordinator.onStateChange = { [weak self] state in
    self?.teamsAutoMeetingState = state
}
```

Replace client ownership with:

```swift
private var teamsIntegrationRequired: Bool {
    teamsMuteSyncEnabled || teamsAutoMeetingEnabled
}

func installTeamsIntegrationIfNeeded() {
    guard teamsIntegrationRequired else { return }
    if teamsMuteSyncEnabled, teamsMuteRelayGeneration == nil {
        teamsMuteRelayGeneration = teamsMuteRelay.enable()
    }
    if !teamsIntegrationInstalled {
        teamsIntegrationInstalled = true
        teamsIntegrationGeneration &+= 1
    }
    installCurrentTeamsCallback()
}

private func installCurrentTeamsCallback() {
    let integrationGeneration = teamsIntegrationGeneration
    let relayGeneration = teamsMuteRelayGeneration
    let relay = teamsMuteRelay
    teamsMuteSyncClient.start { [weak self, relay] event in
        let relayResult = relayGeneration.flatMap {
            relay.apply(event, generation: $0)
        }
        Task { @MainActor [weak self] in
            self?.handleTeamsIntegration(
                event,
                relayResult: relayResult,
                generation: integrationGeneration
            )
        }
    }
}
```

`setTeamsMuteSyncEnabled` must enable or disable only the relay, refresh the
captured callback generation, and stop the client only when
`teamsIntegrationRequired` becomes false. `setTeamsAutoMeetingEnabled` must:

```swift
func setTeamsAutoMeetingEnabled(_ enabled: Bool) {
    guard teamsAutoMeetingEnabled != enabled else { return }
    teamsAutoMeetingEnabled = enabled
    defaults.set(enabled, forKey: Self.teamsAutoMeetingEnabledKey)
    teamsAutoMeetingCoordinator.setEnabled(enabled)
    if enabled {
        installTeamsIntegrationIfNeeded()
    } else {
        stopTeamsIntegrationIfUnused()
    }
}
```

Keep mute relay application synchronous in the Teams callback and keep
screen-window refresh on MainActor. A `.meetingState` event updates
`pendingTeamsMeetingState` but does not start automation by itself. The
immediately following status authorizes or rejects that state:

```swift
private func routeAuthorizedAutoMeetingState(
    for status: TeamsMuteSyncStatus
) {
    defer { pendingTeamsMeetingState = nil }
    guard teamsAutoMeetingEnabled,
          let state = pendingTeamsMeetingState else { return }
    switch status {
    case .inMeeting:
        guard state.isInMeeting else { return }
    case .ready:
        guard !state.isInMeeting else { return }
    default:
        return
    }
    lastAuthorizedTeamsMeetingState = state
    teamsAutoMeetingCoordinator.handleMeetingState(
        isInMeeting: state.isInMeeting
    )
}
```

Clear the pending state on every non-authorizing status. When Auto Mode is
enabled during an already authorized meeting, replay
`lastAuthorizedTeamsMeetingState` only when `teamsConnectionStatus` is
`.inMeeting`; app launch still waits for the client's fresh `query-state`
response.

- [ ] **Step 4: Run focused shared-client and mute regression tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelTeamsAutoMeetingTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelTeamsMuteSyncTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsMuteSyncClientTests
```

Expected: all three focused suites pass with zero failures.

- [ ] **Step 5: Commit Task 2**

```bash
git add \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift \
  Tests/RecorderAppTests/TeamsMuteSyncTests.swift
git commit -m "Share Teams connection with auto recording"
```

---

### Task 3: Automatic Recording Ownership and Lifecycle

**Files:**
- Modify: `Sources/RecorderApp/AppModel.swift:487-590`
- Modify: `Sources/RecorderApp/AppModel.swift:1289-1310`
- Modify: `Sources/RecorderApp/AppModel.swift:1535-1613`
- Modify: `Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift`

**Interfaces:**
- Consumes: `.startRecording`, `.cancelAutomaticStart`, `.stopRecording`, and
  `.transferRecordingToManual` commands from Task 1.
- Produces:

```swift
enum RecordingOwnership: Equatable {
    case manual
    case teamsAutomatic
}

@Published private(set) var recordingOwnership: RecordingOwnership?
```

- [ ] **Step 1: Add failing lifecycle integration tests**

Build a fixture with the existing fake `CaptureSourceProtocol`, a recording
writer, granted permissions, normal storage, one microphone, a fake Teams
client, and an injected `ManualAutoMeetingTicker`.

Add these exact behavioral tests:

```swift
@MainActor
func testCountdownStartsAutomaticRecordingWithoutRequestingPermission() async {
    let fixture = makeRecordingFixture()
    fixture.model.setTeamsAutoMeetingEnabled(true)
    fixture.teams.emit(.meetingState(meeting(true)))

    for _ in 0..<5 {
        await fixture.ticker.fire()
        await Task.yield()
    }
    await waitUntil { fixture.engine.isRecording }

    XCTAssertEqual(fixture.permissionRequestCount.value, 0)
    XCTAssertEqual(fixture.model.recordingOwnership, .teamsAutomatic)
    XCTAssertFalse(fixture.model.isTeamsScreenCaptureRequested)
    XCTAssertEqual(fixture.source.startCount, 1)
}

@MainActor
func testManualRecordingIsNotStoppedByMeetingEnd() async throws {
    let fixture = makeRecordingFixture()
    fixture.model.startOrStop()
    await waitUntil { fixture.engine.isRecording }
    fixture.model.setTeamsAutoMeetingEnabled(true)
    fixture.teams.emit(.meetingState(meeting(false)))

    for _ in 0..<10 {
        await fixture.ticker.fire()
        await Task.yield()
    }

    XCTAssertTrue(fixture.engine.isRecording)
    XCTAssertEqual(fixture.model.recordingOwnership, .manual)
    fixture.model.startOrStop()
    await waitUntil { !fixture.engine.isRecording }
}
```

Also assert:

- automatic recording stops and finalizes once after ten false ticks;
- true before the tenth false tick cancels automatic stop;
- manual Stop on an automatic recording suppresses repeated true events;
- disabling auto mode transfers `.teamsAutomatic` to `.manual` without stop;
- automatic readiness failure never invokes permission handling and does not
  retry on repeated true events;
- false during in-flight automatic start cancels or finalizes any late start
  without leaving an active recording;
- storage-forced stop suppresses restart for the current meeting.

- [ ] **Step 2: Run lifecycle tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelTeamsAutoMeetingTests
```

Expected: new tests fail because coordinator commands are not connected to the
capture lifecycle and recording ownership is absent.

- [ ] **Step 3: Refactor start into an ownership-aware shared path**

Add:

```swift
private var pendingRecordingOwnership: RecordingOwnership?

private func beginRecording(
    ownership: RecordingOwnership,
    requestPermissions: Bool
) {
    beginCaptureLifecycle(.start) { [self] token in
        pendingRecordingOwnership = ownership
        defer {
            if pendingRecordingOwnership == ownership {
                pendingRecordingOwnership = nil
            }
        }
        if requestPermissions {
            await requestPermissionsFromExplicitAction()
            guard captureLifecycleGate.accepts(token) else { return }
        }
        switch captureReadiness {
        case .ready:
            break
        case .blocked(let message):
            statusMessage = message
            if ownership == .teamsAutomatic {
                teamsAutoMeetingCoordinator.automaticStartBlocked(message)
            }
            return
        case .reconnectRequired:
            statusMessage = readinessMessage
            if ownership == .teamsAutomatic {
                teamsAutoMeetingCoordinator.automaticStartFailed(
                    readinessMessage
                )
            }
            return
        }
        let recordingFolder = outputFolder
        guard await prepareStorageForNewRecording(in: recordingFolder),
              captureLifecycleGate.accepts(token),
              outputFolder == recordingFolder else {
            if ownership == .teamsAutomatic {
                teamsAutoMeetingCoordinator.automaticStartFailed(statusMessage)
            }
            return
        }
        do {
            try await recorder.start(
                selection: resolvedCaptureSelection,
                microphoneUID: selectedMicDevice?.uid,
                baseFolder: recordingFolder
            )
            guard captureLifecycleGate.accepts(token) else { return }
            recordingOwnership = ownership
            pendingRecordingOwnership = nil
            isTeamsScreenCaptureRequested = false
            await refreshTeamsScreenCaptureNow()
            restartTeamsScreenRefreshIfNeeded()
            statusMessage = "Recording"
            lastHealthReport = nil
            startStorageMonitoring(folder: recordingFolder)
            if ownership == .teamsAutomatic {
                teamsAutoMeetingCoordinator.automaticStartSucceeded()
            }
        } catch {
            guard captureLifecycleGate.accepts(token) else { return }
            statusMessage = error.localizedDescription
            if ownership == .teamsAutomatic {
                teamsAutoMeetingCoordinator.automaticStartFailed(
                    error.localizedDescription
                )
            }
        }
    }
}
```

Make manual `startOrStop()` call `beginRecording(ownership: .manual,
requestPermissions: true)`. Before a manual stop of an automatic recording,
call `suppressUntilMeetingEnd()`.

Connect coordinator commands once during AppModel initialization:

```swift
autoCoordinator.onCommand = { [weak self] command in
    guard let self else { return }
    switch command {
    case .startRecording:
        self.beginRecording(
            ownership: .teamsAutomatic,
            requestPermissions: false
        )
    case .cancelAutomaticStart:
        if self.pendingRecordingOwnership == .teamsAutomatic {
            self.stopCaptureLifecycle(
                playAfterStop: false,
                automaticMeetingEnd: false
            )
        }
    case .stopRecording:
        guard self.recordingOwnership == .teamsAutomatic else { return }
        self.stopCaptureLifecycle(
            playAfterStop: false,
            automaticMeetingEnd: true
        )
    case .transferRecordingToManual:
        if self.recordingOwnership == .teamsAutomatic {
            self.recordingOwnership = .manual
        }
    }
}
```

Extend `stopCaptureLifecycle` with `automaticMeetingEnd: Bool = false`. A
non-meeting-end stop of an automatically owned recording must call
`suppressUntilMeetingEnd()`. `finishRecording` captures the ending ownership,
clears ownership after `recorder.stop()`, and calls `automaticStopCompleted()`
when the ending owner was `.teamsAutomatic`.

- [ ] **Step 4: Run lifecycle and capture regressions**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelTeamsAutoMeetingTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CaptureStatusTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppModelScreenCaptureTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingEngineStateTests
```

Expected: all focused suites pass with zero failures.

- [ ] **Step 5: Commit Task 3**

```bash
git add \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift
git commit -m "Automate Teams meeting recording lifecycle"
```

---

### Task 4: Non-Activating Countdown Panel and Main UI

**Files:**
- Create: `Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift:4-117`
- Modify: `Sources/RecorderApp/ContentView.swift:168-420`
- Create: `Tests/RecorderAppTests/TeamsAutoMeetingPresentationTests.swift`

**Interfaces:**
- Consumes: `teamsAutoMeetingEnabled`, `teamsAutoMeetingState`,
  `teamsConnectionStatus`, `setTeamsAutoMeetingEnabled`, and
  `cancelTeamsAutoMeetingCountdown` from AppModel.
- Produces:

```swift
struct TeamsAutoMeetingPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let showsCancel: Bool

    static func make(
        state: TeamsAutoMeetingState,
        connectionStatus: TeamsMuteSyncStatus
    ) -> TeamsAutoMeetingPresentation
}

@MainActor
protocol TeamsAutoMeetingCountdownPresenting: AnyObject {
    func present(
        seconds: Int,
        cancel: @escaping @MainActor () -> Void
    )
    func dismiss()
}
```

- [ ] **Step 1: Write failing presentation tests**

Create tests with exact mappings:

```swift
func testCountdownPresentationShowsRemainingSecondsAndCancel() {
    let presentation = TeamsAutoMeetingPresentation.make(
        state: .startCountdown(secondsRemaining: 3),
        connectionStatus: .inMeeting(muted: false)
    )

    XCTAssertEqual(presentation.title, "Recording starts in 3s")
    XCTAssertEqual(presentation.detail, "Teams meeting detected")
    XCTAssertEqual(presentation.systemImage, "record.circle")
    XCTAssertTrue(presentation.showsCancel)
}

func testDisconnectedWaitingPresentationDoesNotClaimMeetingEnded() {
    let presentation = TeamsAutoMeetingPresentation.make(
        state: .waitingForMeeting,
        connectionStatus: .waitingForTeamsAPI
    )

    XCTAssertEqual(presentation.title, "Teams API unavailable")
    XCTAssertEqual(
        presentation.detail,
        "Automatic recording remains armed"
    )
    XCTAssertEqual(
        presentation.systemImage,
        "exclamationmark.triangle.fill"
    )
    XCTAssertFalse(presentation.showsCancel)
}
```

Also verify exact titles:

- `.disabled` -> `Off`;
- `.waitingForMeeting` with ready connection -> `Waiting for meeting`;
- `.automaticRecording` -> `Recording automatically`;
- `.stopCountdown(7)` -> `Stopping in 7s`;
- `.suppressedUntilMeetingEnd` -> `Cancelled for this meeting`;
- `.startBlocked("Microphone permission is required.")` ->
  `Needs permission` with the supplied detail;
- `.startFailed("Microphone unavailable")` -> `Start failed` with the supplied
  detail.

- [ ] **Step 2: Run presentation tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsAutoMeetingPresentationTests
```

Expected: compilation fails because `TeamsAutoMeetingPresentation` is absent.

- [ ] **Step 3: Implement presentation, panel, and controls**

Create a non-activating panel:

```swift
@MainActor
final class TeamsAutoMeetingCountdownPanelController:
    NSObject,
    TeamsAutoMeetingCountdownPresenting
{
    private let panel: NSPanel
    private var cancelAction: (@MainActor () -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 86),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Teams Auto Recording"
        panel.delegate = self
    }

    func present(
        seconds: Int,
        cancel: @escaping @MainActor () -> Void
    ) {
        cancelAction = cancel
        panel.contentView = NSHostingView(
            rootView: TeamsAutoMeetingCountdownView(
                seconds: seconds,
                cancel: cancel
            )
        )
        positionPanel()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        cancelAction = nil
        panel.orderOut(nil)
    }
}
```

Implement `NSWindowDelegate.windowWillClose` to capture and invoke
`cancelAction` once. The SwiftUI panel content uses a `record.circle` icon,
two compact text lines, and an `xmark` icon button with tooltip and
accessibility label `Cancel automatic recording`.

Add a `Teams Auto Recording` GridRow directly before `Teams Mute Sync`. Use a
native switch and a compact status label. Show an `xmark` button only when
`presentation.showsCancel` is true.

Bind the panel in `ContentView`:

```swift
@State private var autoMeetingPanel =
    TeamsAutoMeetingCountdownPanelController()
```

Add:

```swift
.onChange(of: model.teamsAutoMeetingState, initial: true) { _, state in
    if case let .startCountdown(secondsRemaining) = state {
        autoMeetingPanel.present(
            seconds: secondsRemaining,
            cancel: model.cancelTeamsAutoMeetingCountdown
        )
    } else {
        autoMeetingPanel.dismiss()
    }
}
.onDisappear {
    autoMeetingPanel.dismiss()
}
```

The panel must not call `NSApp.activate`, play a sound, alter Teams state, or
enable screen capture.

- [ ] **Step 4: Run UI tests, full tests, and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TeamsAutoMeetingPresentationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build
```

Expected: presentation tests and full suite pass with zero failures; build
exits zero.

- [ ] **Step 5: Commit Task 4**

```bash
git add \
  Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift \
  Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/TeamsAutoMeetingPresentationTests.swift
git commit -m "Add Teams auto recording countdown UI"
```

---

### Task 5: Documentation, Independent Review, Installation, and Acceptance

**Files:**
- Modify: `README.md:108-140`
- Verify: all files changed since merge base `061c41c`

**Interfaces:**
- Consumes: complete Tasks 1-4 behavior.
- Produces: documented user workflow, clean full-suite evidence, installed app
  candidate, and live acceptance checklist.

- [ ] **Step 1: Update README with exact workflow**

Add a `Teams Auto Recording` subsection that states:

```text
1. Enable Teams Third-party app API and complete pairing.
2. Grant Screen & System Audio Recording and microphone access before enabling
   automatic recording.
3. Enable Teams Auto Recording.
4. Joining a meeting shows a silent five-second countdown; Cancel suppresses
   automatic recording until that meeting ends.
5. Leaving a meeting stops only an automatically started recording after ten
   continuous seconds.
6. Teams API disconnect never stops a recording.
7. Screen capture starts off and remains a manual mid-recording control.
```

Document that Teams Mute Sync may be disabled independently.

- [ ] **Step 2: Run fresh complete verification**

Run:

```bash
git diff --check 061c41c..HEAD
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: diff check exits zero, the complete test suite has zero failures, and
the app build exits zero.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md
git commit -m "Document Teams auto recording"
```

- [ ] **Step 4: Run independent whole-branch review**

Generate a review package from merge base `061c41c` through `HEAD`. The reviewer
must check every acceptance criterion in the approved design, concurrency and
stale-event behavior, manual ownership safety, permission behavior, timer
cancellation, AppKit focus behavior, test quality, and unrelated regressions.

Resolve every Critical or Important finding with focused tests, re-run those
tests, and request re-review. Record Minor findings for final reporting.

- [ ] **Step 5: Install the candidate**

Run:

```bash
./scripts/install-app.sh
```

Expected: `/Applications/Local Meeting Recorder.app` is replaced by the
candidate and the script prints `Installed: /Applications/Local Meeting
Recorder.app`.

- [ ] **Step 6: Perform installed-app smoke acceptance**

Before a live call:

- confirm the Auto Recording switch persists across relaunch;
- confirm permissions are already granted;
- confirm Teams API status reaches Connected;
- confirm screen capture is off.

During a Teams test call:

- confirm the silent panel shows `5`, `4`, `3`, `2`, `1`;
- cancel once and confirm no recording starts during that call;
- leave and rejoin, let countdown complete, and confirm one recording starts;
- briefly interrupt Teams API connectivity and confirm recording continues;
- leave, rejoin within ten seconds, and confirm recording continues;
- leave for more than ten seconds and confirm one finalized session appears;
- manually start a new recording, enter and leave Teams, and confirm it remains
  recording;
- manually stop an auto-started recording and confirm it does not restart in
  the same call;
- confirm screen capture remains off until manually enabled.

- [ ] **Step 7: Run final evidence commands and push**

Run:

```bash
git status --short --branch
git log --oneline 061c41c..HEAD
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git push -u origin codex/teams-auto-meeting-mode
```

Expected: worktree is clean, commits are scoped to this feature, full tests
have zero failures, and the branch is published to origin.
