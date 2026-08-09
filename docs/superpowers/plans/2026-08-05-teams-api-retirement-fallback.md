# Teams API Retirement Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore local Teams auto recording and privacy mute after retirement of the Teams desktop third-party API, without adding a cloud backend or brittle Teams control automation.

**Architecture:** A deterministic `TeamsLocalMeetingDetector` consumes the existing Teams window resolver output and emits only confirmed meeting-enter/meeting-exit transitions to the existing recording-ownership coordinator. Recorder-local and native input mute remain the only microphone authorities and continue gating both recorded microphone audio and `Local Recorder Virtual Mic`; all legacy WebSocket, pairing, and mute-sync runtime paths are removed.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, ScreenCaptureKit window inventory, AVFAudio `AVAudioApplication`, XCTest, Swift Package Manager, macOS 26.

## Global Constraints

- Keep the app local-only; add no Graph app, webhook, bot, TeamsJS app, or network service.
- Never connect to, probe, or retry `127.0.0.1:8124`.
- Do not add Accessibility control reading, UI clicking, or keyboard shortcut injection.
- Require three one-second eligible-window observations before meeting entry and thirty consecutive missing observations before meeting exit.
- Treat inventory errors as unknown, not as meeting exit.
- Only an auto-owned recording may auto-stop; manual recordings must survive every detector transition.
- Keep the existing five-second cancellable start countdown and transfer-to-manual behavior.
- Effective privacy mute is `localMuted || nativeInputMuted` and must synchronously gate the recorded mic and virtual mic before UI publication.
- Preserve existing capture selection, screen-capture toggle, recordings, folders, and manual window selection.
- Keep automated coverage focused: one detector suite, existing ownership integration suite, one migration suite, and existing settings render suite; run the full suite only at the final gate.

---

### Task 1: Local meeting detector and resolver output

**Files:**
- Create: `Sources/RecorderApp/Teams/TeamsLocalMeetingDetector.swift`
- Create: `Tests/RecorderAppTests/TeamsLocalMeetingDetectorTests.swift`
- Modify: `Sources/RecorderApp/Capture/TeamsMeetingWindow.swift`
- Modify: `Sources/RecorderApp/RecordingEngine.swift:571-643`
- Modify: `Tests/RecorderAppTests/TeamsMeetingWindowResolverTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingEngineStateTests.swift`

**Interfaces:**
- Consumes: `TeamsWindowResolution`, `TeamsWindowIdentity`, and `TeamsWindowConfidence`.
- Produces: `TeamsLocalMeetingDetector.observe(_:) -> TeamsLocalMeetingUpdate` and `RecordingEngine.refreshTeamsWindows(...) async -> TeamsWindowRefreshOutcome`.

- [ ] **Step 1: Write detector and local-resolution RED tests**

```swift
func testSameReadyWindowRequiresThreeObservationsBeforeEntry() {
    var detector = TeamsLocalMeetingDetector(confirmObservations: 3, endObservations: 30)
    XCTAssertNil(detector.observe(.resolved(.ready(match(id: 7)))).meetingTransition)
    XCTAssertNil(detector.observe(.resolved(.ready(match(id: 7)))).meetingTransition)
    XCTAssertEqual(
        detector.observe(.resolved(.ready(match(id: 7)))).meetingTransition,
        true
    )
}

func testUnknownAndAmbiguousDoNotEndDetectedMeeting() {
    var detector = detectedDetector()
    XCTAssertNil(detector.observe(.unknown).meetingTransition)
    XCTAssertNil(detector.observe(.resolved(.ambiguous([]))).meetingTransition)
}

func testThirtyMissingObservationsEmitOneExit() {
    var detector = detectedDetector(endObservations: 30)
    for _ in 0..<29 {
        XCTAssertNil(detector.observe(.resolved(.waiting)).meetingTransition)
    }
    XCTAssertEqual(detector.observe(.resolved(.waiting)).meetingTransition, false)
    XCTAssertNil(detector.observe(.resolved(.waiting)).meetingTransition)
}

func testIdentityChangeRestartsConfirmation() {
    var detector = TeamsLocalMeetingDetector(confirmObservations: 3, endObservations: 30)
    _ = detector.observe(.resolved(.ready(match(id: 7))))
    _ = detector.observe(.resolved(.ready(match(id: 7))))
    XCTAssertNil(detector.observe(.resolved(.ready(match(id: 8)))).meetingTransition)
    XCTAssertEqual(detector.state, .confirming(secondsRemaining: 2))
}
```

- [ ] **Step 2: Run RED tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TeamsLocalMeetingDetectorTests
```

Expected: compilation fails because `TeamsLocalMeetingDetector` and its observation/update types do not exist.

- [ ] **Step 3: Implement the minimal detector**

```swift
enum TeamsLocalMeetingDetectionState: Equatable, Sendable {
    case waiting
    case confirming(secondsRemaining: Int)
    case detected(TeamsWindowConfidence)
    case ending(secondsRemaining: Int)
    case ambiguous
}

enum TeamsLocalMeetingObservation: Equatable, Sendable {
    case resolved(TeamsWindowResolution)
    case unknown
}

struct TeamsLocalMeetingUpdate: Equatable, Sendable {
    let state: TeamsLocalMeetingDetectionState
    let meetingTransition: Bool?
}

struct TeamsLocalMeetingDetector {
    private let confirmObservations: Int
    private let endObservations: Int
    private var candidateIdentity: TeamsWindowIdentity?
    private var positiveCount = 0
    private var missingCount = 0
    private var meetingIsDetected = false
    private(set) var state: TeamsLocalMeetingDetectionState = .waiting

    init(confirmObservations: Int = 3, endObservations: Int = 30) {
        precondition(confirmObservations > 0 && endObservations > 0)
        self.confirmObservations = confirmObservations
        self.endObservations = endObservations
    }

    mutating func observe(_ observation: TeamsLocalMeetingObservation) -> TeamsLocalMeetingUpdate
    mutating func reset() -> TeamsLocalMeetingUpdate
}
```

Implement these exact rules: `.unknown` never changes counters; pre-entry `.ambiguous` clears the candidate and publishes `.ambiguous`; a new ready identity starts at positive count one; detected ready resets the missing count; detected ambiguous/unknown preserve detection; detected waiting increments the missing count and emits exactly one `false` at the threshold.

- [ ] **Step 4: Expose local window resolution without an API lifecycle gate**

Add to `TeamsMeetingWindowResolver`:

```swift
mutating func observeLocal(
    _ windows: [TeamsWindowSnapshot],
    now: Date
) -> TeamsWindowResolution
```

It must reuse manual override, rejection, area, and ambiguity logic while allowing eligible visible windows when no authoritative meeting flag exists. Do not duplicate window filtering in the detector.

Return the exact resolver outcome from `RecordingEngine`:

```swift
enum TeamsWindowRefreshOutcome: Equatable, Sendable {
    case resolved(TeamsWindowResolution)
    case unknown
}

@discardableResult
func refreshTeamsWindows(
    selectedTeamsProcessID: pid_t,
    mode: TeamsWindowObservationMode,
    manualOverride: TeamsWindowIdentity?
) async -> TeamsWindowRefreshOutcome
```

`mode` has only `.authoritativeMeeting(isActive: Bool)` and `.localDetection`. Catching a window inventory error returns `.unknown` while retaining the existing screen-capture failure presentation.

- [ ] **Step 5: Run focused GREEN tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'TeamsLocalMeetingDetectorTests|TeamsMeetingWindowResolverTests|RecordingEngineStateTests'
```

Expected: selected tests pass with zero failures.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/RecorderApp/Teams/TeamsLocalMeetingDetector.swift Sources/RecorderApp/Capture/TeamsMeetingWindow.swift Sources/RecorderApp/RecordingEngine.swift Tests/RecorderAppTests/TeamsLocalMeetingDetectorTests.swift Tests/RecorderAppTests/TeamsMeetingWindowResolverTests.swift Tests/RecorderAppTests/RecordingEngineStateTests.swift
git commit -m "feat: detect Teams meetings from local windows"
```

---

### Task 2: Route confirmed local presence through existing ownership rules

**Files:**
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/Teams/TeamsAutoMeetingCoordinator.swift`
- Modify: `Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift`
- Modify: `Tests/RecorderAppTests/TeamsAutoMeetingCoordinatorTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`

**Interfaces:**
- Consumes: `TeamsLocalMeetingDetector`, `TeamsWindowRefreshOutcome`, and existing `TeamsAutoMeetingCoordinator` commands.
- Produces: `AppModel.teamsLocalMeetingDetectionState` and an immediate confirmed-end route that does not add the legacy ten-second debounce.

- [ ] **Step 1: Write AppModel and coordinator RED tests**

Retain existing ownership tests and replace legacy fake-client event setup with deterministic window refreshes. Add only these integration behaviors:

```swift
func testThreeEligibleWindowRefreshesBeginExistingFiveSecondCountdown() async {
    let fixture = makeLocalWindowFixture(autoEnabled: true)
    fixture.source.windows = [teamsWindow(id: 7)]
    await refresh(fixture, count: 3)
    XCTAssertEqual(fixture.model.teamsAutoMeetingState, .startCountdown(secondsRemaining: 5))
}

func testConfirmedWindowExitStopsOnlyAutomaticRecording() async {
    let fixture = await automaticallyRecordingLocalWindowFixture()
    fixture.source.windows = []
    await refresh(fixture, count: 30)
    XCTAssertFalse(fixture.engine.isRecording)
}

func testConfirmedWindowExitDoesNotStopManualRecording() async throws {
    let fixture = try await manuallyRecordingLocalWindowFixture()
    fixture.source.windows = []
    await refresh(fixture, count: 30)
    XCTAssertTrue(fixture.engine.isRecording)
    XCTAssertEqual(fixture.model.recordingOwnership, .manual)
}

func testWindowInventoryErrorDoesNotAdvanceAutomaticStop() async {
    let fixture = await automaticallyRecordingLocalWindowFixture()
    fixture.source.refreshError = TestError.unavailable
    await refresh(fixture, count: 30)
    XCTAssertTrue(fixture.engine.isRecording)
}
```

Add one coordinator unit test for the new confirmed-end seam:

```swift
func testConfirmedEndStopsAutomaticRecordingWithoutSecondDebounce() {
    let coordinator = automaticRecordingCoordinator()
    coordinator.handleConfirmedMeetingEnd()
    XCTAssertEqual(commands, [.stopRecording])
}
```

- [ ] **Step 2: Run RED tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'AppModelTeamsAutoMeetingTests|TeamsAutoMeetingCoordinatorTests'
```

Expected: new local-window tests fail because AppModel does not route refresh outcomes and `handleConfirmedMeetingEnd()` is missing.

- [ ] **Step 3: Wire the detector into the existing refresh owner**

Add to `AppModel`:

```swift
@Published private(set) var teamsLocalMeetingDetectionState: TeamsLocalMeetingDetectionState = .waiting
private var teamsLocalMeetingDetector = TeamsLocalMeetingDetector()
```

When `teamsAutoMeetingEnabled` is true, `refreshTeamsScreenCaptureNow()` requests `.localDetection`, maps `.resolved`/`.unknown` into the detector, publishes its state, and routes only non-nil transitions:

```swift
private func applyLocalMeetingUpdate(_ update: TeamsLocalMeetingUpdate) {
    teamsLocalMeetingDetectionState = update.state
    guard let transition = update.meetingTransition else { return }
    if transition {
        teamsAutoMeetingCoordinator.handleMeetingState(isInMeeting: true)
        suppressAutomationForActiveManualRecording()
    } else {
        teamsAutoMeetingCoordinator.handleConfirmedMeetingEnd()
    }
}
```

Expand the existing refresh-loop guard to run while a Teams application is selected and any of these are true: auto mode enabled, recorder recording, or screen capture requested. Disabling auto mode resets the detector and retains the existing transfer-to-manual behavior.

- [ ] **Step 4: Add the confirmed-end coordinator seam**

```swift
func handleConfirmedMeetingEnd() {
    isInMeeting = false
    guard isEnabled else { return }
    switch state {
    case .startCountdown:
        invalidateTimer()
        state = .waitingForMeeting
    case .starting:
        state = .waitingForMeeting
        onCommand?(.cancelAutomaticStart)
    case .automaticRecording:
        automaticStopPhase = .committed
        onCommand?(.stopRecording)
    case .suppressedUntilMeetingEnd, .startBlocked, .startFailed:
        state = .waitingForMeeting
    default:
        break
    }
}
```

Do not alter the existing API-era debounced method until Task 3 removes its callers and obsolete tests.

- [ ] **Step 5: Run focused GREEN tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'TeamsLocalMeetingDetectorTests|AppModelTeamsAutoMeetingTests|TeamsAutoMeetingCoordinatorTests|AppModelScreenCaptureTests'
```

Expected: selected tests pass with zero failures.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/RecorderApp/AppModel.swift Sources/RecorderApp/Teams/TeamsAutoMeetingCoordinator.swift Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift Tests/RecorderAppTests/TeamsAutoMeetingCoordinatorTests.swift Tests/RecorderAppTests/AppModelScreenCaptureTests.swift
git commit -m "feat: drive auto recording from Teams windows"
```

---

### Task 3: Remove the retired runtime and make privacy mute explicit

**Files:**
- Create: `Sources/RecorderApp/Teams/LegacyTeamsIntegrationCleaner.swift`
- Create: `Tests/RecorderAppTests/LegacyTeamsIntegrationCleanerTests.swift`
- Create: `Tests/RecorderAppTests/MicrophoneMuteCoordinatorTests.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/Teams/MicrophoneMuteCoordinator.swift`
- Modify: `Tests/RecorderAppTests/AppModelTeamsAutoMeetingTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`
- Delete: `Sources/RecorderApp/Teams/TeamsThirdPartyAPI.swift`
- Delete: `Sources/RecorderApp/Teams/TeamsMuteSyncClient.swift`
- Delete: `Sources/RecorderApp/Teams/TeamsMuteRelay.swift`
- Delete: `Sources/RecorderApp/Teams/KeychainTeamsPairingTokenStore.swift`
- Delete: `Tests/RecorderAppTests/TeamsMuteSyncClientTests.swift`
- Delete: `Tests/RecorderAppTests/TeamsMuteSyncTests.swift`
- Delete: `Tests/RecorderAppTests/TeamsPairingTokenStoreTests.swift`

**Interfaces:**
- Consumes: `SecureValueStoring`, `UserDefaults`, `MicrophoneMuteGate`, and native/local mute inputs.
- Produces: one-shot `LegacyTeamsIntegrationCleaner.clean()` and a two-authority `MicrophoneMuteSnapshot`.

- [ ] **Step 1: Write migration and two-authority mute RED tests**

```swift
func testCleanupDeletesLegacyCredentialAndPreferences() throws {
    let secure = InMemorySecureValueStore(stored: Data("secret".utf8))
    let defaults = makeDefaults()
    defaults.set(true, forKey: "teamsMuteSyncEnabled")
    defaults.set("legacy", forKey: "teamsThirdPartyAPIPairingToken")
    try LegacyTeamsIntegrationCleaner(secureStore: secure, defaults: defaults).clean()
    XCTAssertNil(defaults.object(forKey: "teamsMuteSyncEnabled"))
    XCTAssertNil(defaults.object(forKey: "teamsThirdPartyAPIPairingToken"))
    XCTAssertNil(secure.stored)
}

func testCleanupFailureRemovesPlainDefaultsAndCanRetryKeychainDelete() {
    let secure = InMemorySecureValueStore(deleteError: TestError.failed)
    let defaults = makeDefaults()
    XCTAssertThrowsError(try LegacyTeamsIntegrationCleaner(secureStore: secure, defaults: defaults).clean())
    XCTAssertNil(defaults.object(forKey: "teamsMuteSyncEnabled"))
}

func testEffectiveMuteUsesOnlyLocalAndNativeAuthorities() {
    var coordinator = MicrophoneMuteCoordinator()
    XCTAssertEqual(coordinator.setLocalMuted(true), true)
    XCTAssertEqual(coordinator.setNativeInputMuted(true), nil)
    XCTAssertEqual(coordinator.setLocalMuted(false), nil)
    XCTAssertEqual(coordinator.setNativeInputMuted(false), false)
}

func testSnapshotContainsOnlyLocalNativeAndEffectiveMute() {
    XCTAssertEqual(
        MicrophoneMuteSnapshot(
            localMuted: true,
            nativeInputMuted: false,
            effectiveMuted: true
        ),
        MicrophoneMuteSnapshot(
            localMuted: true,
            nativeInputMuted: false,
            effectiveMuted: true
        )
    )
}
```

- [ ] **Step 2: Run RED tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'LegacyTeamsIntegrationCleanerTests|MicrophoneMuteCoordinatorTests'
```

Expected: cleaner type is missing and the new three-field snapshot initializer does not compile while Teams remains an authority.

- [ ] **Step 3: Implement a deletion-only legacy cleaner**

```swift
struct LegacyTeamsIntegrationCleaner {
    static let service = "local.meeting.recorder.teams-third-party-api"
    static let account = "pairing-token.v1"
    static let defaultsKeys = [
        "teamsMuteSyncEnabled",
        "teamsThirdPartyAPIPairingToken"
    ]

    let secureStore: any SecureValueStoring
    let defaults: UserDefaults

    func clean() throws {
        for key in Self.defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        try secureStore.delete(service: Self.service, account: Self.account)
    }
}
```

Run once during AppModel startup. A delete failure sets a redacted status and retries next launch; it must not block capture or mute handling.

- [ ] **Step 4: Remove Teams from the mute state model and production composition**

Reduce the coordinator to:

```swift
struct MicrophoneMuteCoordinator {
    private(set) var localMuted: Bool
    private(set) var nativeInputMuted = false
    var effectiveMuted: Bool { localMuted || nativeInputMuted }
    mutating func setLocalMuted(_ muted: Bool) -> Bool?
    mutating func setNativeInputMuted(_ muted: Bool) -> Bool?
}
```

Remove `teamsMuteSyncStatus`, `teamsMuteSyncEnabled`, `teamsConnectionStatus`, `teamsMicMuted`, `TeamsIntegrationIngress`, client/relay properties, constructor seams, install/retry/pair methods, and event routing from AppModel. Delete the four retired source files and obsolete protocol/client tests. Move only the existing local/native mute coordinator assertions into the new focused test file; do not preserve protocol/pairing/reconnect tests.

- [ ] **Step 5: Prove no production or test source retains the retired protocol**

Run:

```bash
rg -n '127\.0\.0\.1|8124|TeamsThirdPartyAPI|TeamsMuteSyncClient|requestTeamsPairing|retryTeamsMuteSync|teamsMuteSyncEnabled' Sources Tests
```

Expected: no matches except the deletion-only legacy defaults key in `LegacyTeamsIntegrationCleaner` and its focused test. The host/port and retired type names must have zero matches.

- [ ] **Step 6: Run focused GREEN tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'LegacyTeamsIntegrationCleanerTests|MicrophoneMuteCoordinatorTests|InputMuteControllerTests|AppModelMuteTests|AppModelTeamsAutoMeetingTests|AppModelScreenCaptureTests'
```

Expected: selected tests pass with zero failures.

- [ ] **Step 7: Commit Task 3**

```bash
git add Sources/RecorderApp/AppModel.swift Sources/RecorderApp/Teams Tests/RecorderAppTests
git commit -m "refactor: retire Teams control API runtime"
```

---

### Task 4: Update truthful UI, add lean UAT, and run one final gate

**Files:**
- Modify: `Sources/RecorderApp/UI/RecorderSettingsView.swift`
- Modify: `Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- Modify: `Tests/RecorderAppTests/TeamsAutoMeetingPresentationTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingControllerRenderTests.swift`
- Create: `docs/testing/2026-08-05-teams-api-retirement-fallback-uat.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `teamsAutoMeetingEnabled`, `teamsAutoMeetingState`, and `teamsLocalMeetingDetectionState`.
- Produces: truthful `Teams Window Auto Mode (Beta)` and `Virtual Mic Privacy Mute` UI with no pairing controls.

- [ ] **Step 1: Write focused UI RED tests**

```swift
func testRecordingSettingsExposeWindowAutoModeAndNoRetiredPairingControls() throws {
    let host = RecorderWorkspaceRenderHost(model: makeModel())
    host.openSettingsSection(.recording)
    XCTAssertTrue(host.containsText("Teams Window Auto Mode"))
    XCTAssertTrue(host.containsText("Beta"))
    XCTAssertFalse(host.containsText("Teams Mute Sync"))
    XCTAssertFalse(host.containsText("Waiting for Allow"))
    XCTAssertFalse(host.containsAccessibilityLabel("Retry Teams mute sync"))
}

func testAudioSettingsExplainVirtualMicPrivacyBoundary() throws {
    let host = RecorderWorkspaceRenderHost(model: makeModel())
    host.openSettingsSection(.audio)
    XCTAssertTrue(host.containsText("Virtual Mic Privacy Mute"))
    XCTAssertTrue(host.containsText("Teams mute icon may differ"))
}

func testFloatingMicrophoneIconInvokesLocalPrivacyMute() throws {
    var muteRequests = 0
    let host = makeRecordingPanelHost(
        isMicrophoneMuted: false,
        toggleMicrophoneMute: { muteRequests += 1 }
    )
    try host.click(RecordingControllerAccessibility.microphoneMuteID)
    XCTAssertEqual(muteRequests, 1)
    XCTAssertEqual(
        host.accessibilityLabel(RecordingControllerAccessibility.microphoneMuteID),
        "Mute microphone"
    )
}
```

Update the existing presentation test to construct from auto/detector state only and assert `Waiting for Teams meeting window`, `Confirming Teams meeting`, `Teams meeting detected`, `Waiting for meeting window to return`, and `Choose a Teams meeting window`.

- [ ] **Step 2: Run UI RED tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderWorkspaceRenderTests|TeamsAutoMeetingPresentationTests|RecordingControllerRenderTests'
```

Expected: new labels are absent and presentation still requires `TeamsMuteSyncStatus`.

- [ ] **Step 3: Replace retired UI with truthful local-mode copy**

Use these exact labels and identifiers:

```swift
Label("Teams Window Auto Mode", systemImage: "record.circle")
Text("Beta").accessibilityLabel("Beta")
Toggle("Teams Window Auto Mode", isOn: $isEnabled)
    .accessibilityIdentifier("teams-window-auto-mode-toggle")

Label("Virtual Mic Privacy Mute", systemImage: "mic.slash")
Text("Recorder and native input mute silence the mic track and Local Recorder Virtual Mic. The Teams mute icon may differ.")
    .accessibilityIdentifier("virtual-mic-privacy-mute-detail")
```

Remove the entire pairing/retry/mute-sync view tree. Change the floating panel title to `Teams Window Auto Recording`. Map detector state into presentation without adding another observable model.

Turn only the existing recording-panel microphone icon into a compact button.
Its action calls `model.toggleRecorderMicMute(source: "Floating panel")`; use
`mic.fill` / `mic.slash.fill` and `Mute microphone` / `Unmute microphone` from
the current Recorder mute state. Do not add a second toggle, a countdown-panel
mute control, or Teams-icon synchronization.

- [ ] **Step 4: Add the independently drafted lean acceptance document**

Copy the seven cases from `docs/testing/2026-08-05-teams-api-retirement-fallback-uat.md`: real-window countdown, cancel/re-arm, short window loss, confirmed leave, manual ownership, actual virtual-mic audio, and zero port-8124 traffic. Keep one evidence package and explicitly exclude observation matrices, Graph/TeamsJS/AX, pixel diffs, and duplicate audio paths.

- [ ] **Step 5: Run focused UI GREEN tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'TeamsAutoMeetingPresentationTests|RecorderWorkspaceRenderTests|RecordingControllerRenderTests'
```

Expected: selected tests pass with zero failures.

- [ ] **Step 6: Run the single final automated gate**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --arch arm64
./scripts/build-app.sh --configuration release --version 0.2.0 --build-number 335 --bundle-id local.meeting.recorder.staging --bundle-name "Local Meeting Recorder Staging" --output "$PWD/build/Local Meeting Recorder Staging.app" --sign ad-hoc
./scripts/verify-app-bundle.sh "$PWD/build/Local Meeting Recorder Staging.app" local.meeting.recorder.staging 0.2.0 335 ad-hoc
git diff --check
```

Expected: full test suite, release build, bundle verification, and diff check all exit zero. Do not claim real Teams acceptance from these commands; the seven-case installed-app UAT remains separate.

- [ ] **Step 7: Commit Task 4**

```bash
git add Sources/RecorderApp/UI/RecorderSettingsView.swift Sources/RecorderApp/Views/TeamsAutoMeetingCountdownPanel.swift Sources/RecorderApp/Views/RecordingControllerPanel.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift Tests/RecorderAppTests/TeamsAutoMeetingPresentationTests.swift Tests/RecorderAppTests/RecordingControllerRenderTests.swift docs/testing/2026-08-05-teams-api-retirement-fallback-uat.md README.md
git commit -m "feat: present local Teams fallback controls"
```

---

### Task 5: Merge, install the requested staging build, and remove the duplicate

**Files:**
- Replace: `/Applications/Local Meeting Recorder Staging.app`
- Remove after successful copy: `build/Local Meeting Recorder Staging.app`

- [ ] **Step 1: Merge the completed feature branch into `main`**

From the primary checkout, verify both worktrees are clean, switch to `main`,
and merge `codex/teams-api-retirement-fallback`. Do not include the unrelated
untracked tutorial/assets files.

- [ ] **Step 2: Build and verify version 0.2.0 (335) from merged `main`**

Repeat only the app packaging and bundle verification commands from Task 4 in
the primary checkout. Read `CFBundleShortVersionString` and `CFBundleVersion`
from the resulting bundle and require `0.2.0` and `335`.

- [ ] **Step 3: Atomically replace the staging installation**

Quit the staging app if it is running, copy the verified bundle to a temporary
sibling under `/Applications`, replace exactly
`/Applications/Local Meeting Recorder Staging.app`, and verify its bundle ID,
version/build, executable, and ad-hoc signature in place.

- [ ] **Step 4: Remove only the duplicate build-folder staging bundle**

After the installed bundle passes verification, remove exactly
`build/Local Meeting Recorder Staging.app`. Preserve every other build artifact
and report that the installed copy remains at `/Applications`.
