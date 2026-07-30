# PR A Recorder Workspace UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a presentation-only Record / Recordings / Settings workspace shell while preserving current runtime wiring, direct `AppModel` action parity, and presenter lifetime.

**Architecture:** `ContentView` becomes only the workspace shell: it observes the sole injected `AppModel`, retains exactly the current playback and Teams-countdown presenters, and composes destination views. Every destination receives that same model and calls existing methods directly. `RecorderGlass` is the sole macOS 26 Glass availability boundary; all content is a stable surface.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSHostingView`/ `NSWindow`, XCTest, AVKit, Combine, macOS 15+.

## Global Constraints

- Approved baseline: `8f110466093c9a3fabc5f5d1fad3c69afa849c53` (2026-07-30).
- PR A is presentation only. Do not add feature models, `AppCoordinator`, repositories, a second model, environment-wide mutable model, state migration, transcription/provider behavior, timestamped transcript, AI, media/capture/Teams/playback behavior, or Windows code.
- Keep `ContentView(model: appDelegate.runtime.model)`, one `AppRuntime`, one `AppModel`, main window ID, termination cleanup, floating recording-panel ownership, global hotkey, and every `AppModel` command signature unchanged.
- `ContentView` alone constructs/retains `TeamsAutoMeetingCountdownPresenting` and `PlaybackWindowPresenting`; `AppRuntime` remains floating-panel owner.
- `AppModel.outputFolder` is the sole workspace/output-folder source in PR A and PR B. Do not introduce, declare, observe, or use `workspaceRevision`; it is future PR C compatibility only.
- Existing transcript/metadata sheet semantics remain unchanged. `RecorderNavigationState` is a pure future dirty-gate contract and is not wired to these sheets.
- Every commit must compile and remain operable. The navigation commit first composes the existing private views through temporary destination adapters; each later extraction replaces exactly one adapter. Unextracted destinations continue to use the baseline implementation until their own commit.
- Preserve `Option+Shift+M`. Cmd+Shift+R currently sends `#selector(AppCommands.startStopRecording)` from `LocalMeetingRecorderApp`, but no responder implementation was found. Leave selector/menu/behavior untouched and do not claim it fixed.
- Preserve IDs: `capture-mode-picker`, `reconnect-selected-application`, `teams-screen-capture-toggle`, `teams-screen-capture-status`, `teams-screen-window-menu`, `teams-auto-recording-toggle`, `teams-auto-recording-status`, `teams-auto-recording-cancel`.
- Every slice is RED → prove failure → minimal GREEN → focused GREEN before staging source changes.

---

## Plan acceptance checkpoint

Before Task 1, commit only the approved design-status update and this reviewed
implementation plan:

```bash
git add docs/superpowers/specs/2026-07-30-ui-feature-boundaries-design.md docs/superpowers/plans/2026-07-30-pr-a-recorder-workspace-ui.md
git diff --cached --check
git commit -m "docs: approve and plan PR A workspace UI"
```

This documentation checkpoint precedes the five rollback-safe implementation
commits and does not count as one of them.

---

## Exact UI responsibility and command map

| Baseline responsibility | Destination | Exact direct state / command |
|---|---|---|
| navigation + presenter lifetime | `ContentView.swift` + `UI/RecorderNavigation.swift` | pure `RecorderNavigationState`; no model routing command |
| header, dot, status, timer, refresh | `UI/RecordDashboardView.swift` | `model.recorder.isRecording`, `startedAt`, `model.statusMessage`, `model.refreshAllCaptureState()` |
| blocking capture recovery | Record deep link to Settings capture section | pure navigation selection; state read from `systemAudioPermission`, `microphonePermission`, selected-app connection projection; no new `AppModel` command |
| meters | `UI/RecordDashboardView.swift` | `systemLevel`, `micLevel`, `model.systemAudioSubtitle`, `selectedMicDevice?.name`, `recorder.micMuted` |
| live and detailed health | `UI/RecordDashboardView.swift` | recorder levels/mute/monitoring/recording + `model.lastHealthReport` |
| Start/Stop | `UI/RecordDashboardView.swift` | `model.startOrStop()`; disable `!isRecording && model.isCaptureLifecycleWorking` |
| Test 10s | `UI/RecordDashboardView.swift` | `model.runTestRecording()`; disable `isRecording || isRunningTestRecording || isCaptureLifecycleWorking` |
| local/native/Teams mute presentation | `UI/RecordDashboardView.swift` | `model.toggleRecorderMicMute()`; `localMicMuted`, `nativeInputMicMuted`, `teamsMicMuted`; disable `(teamsMicMuted || nativeInputMicMuted) && !localMicMuted` |
| choose/open folder + footer | `UI/RecordDashboardView.swift` | `model.chooseOutputFolder()`, `openRecordingFolder()`, `model.outputFolder`, `recorder.outputFolder`, `lastRecordingSavedAsM4A` |
| permissions | `UI/RecorderSettingsView.swift` Capture | permission state + `requestSystemAudioPermission()`, `requestMicrophonePermission()`, `openScreenCaptureSettings()`, `openMicrophoneSettings()` |
| capture/app/mic controls | `UI/RecorderSettingsView.swift` Capture | `selectCaptureMode(_:)`, `selectCaptureApplication(bundleIdentifier:)`, `refreshCaptureApplications()`, `reconnectSelectedApplication()`, `selectMicrophone(_:)`; retain `sourceControlsEnabled`/reconnect gates |
| Teams screen capture | `UI/RecorderSettingsView.swift` Teams | existing `TeamsScreenCaptureControlsView(model: model)`, retaining `setTeamsScreenCaptureRequested(_:)`, `selectTeamsScreenCaptureWindow(_:)`, `refreshTeamsScreenCaptureNow()` |
| virtual mic | `UI/RecorderSettingsView.swift` Audio integration | existing recorder publisher state, `virtualMicInstallationState`, `inputMuteControlAvailable` |
| Auto Meeting | `UI/RecorderSettingsView.swift` Teams | `setTeamsAutoMeetingEnabled(_:)`, `cancelTeamsAutoMeetingCountdown()`, current state/connection projection |
| mute sync/pair/retry | `UI/RecorderSettingsView.swift` Teams | `setTeamsMuteSyncEnabled(_:)`, `retryTeamsMuteSync()`, `requestTeamsPairing()`, current status |
| provider editor | `UI/RecorderSettingsView.swift` Transcription | exactly `AIProviderSettingsView(model: model.aiProviderSettingsModel)` |
| library search/favorites/refresh | `UI/RecordingsLibraryView.swift` | local view state + `model.sessions`, `model.refreshSessions()` |
| play / external playback | row invokes `model.play(session:)`; shell owns presentation | `ContentView` observes `playingSessionID`, presents `playbackPresentation`, `playbackToggle()`, `stopPlayback()`, `seekPlayback(to:)` |
| import/transcribe/cancel | `UI/RecordingsLibraryView.swift` | `chooseAudioFileForTranscription()`, `transcribe(session:)`, `cancelTranscription()` and existing transcription projections |
| transcript | `UI/RecordingsLibraryView.swift` sheet | `transcriptText(for:)`, `saveTranscript(_:for:)`, `exportTranscript(for:)`, `copyTranscript(for:)`, `openTranscript(for:)`, `openTranscriptLog(for:)` |
| metadata/favorite/trash | `UI/RecordingsLibraryView.swift` sheet/dialog | `saveMetadata(title:tags:isFavorite:for:)`, `moveSessionToTrash(_:)` |

## File map

- Create `Sources/RecorderApp/UI/RecorderNavigation.swift`: destination enum and pure pending-route state.
- Create `Sources/RecorderApp/UI/RecorderActionID.swift`: stable string constants only.
- Create `Sources/RecorderApp/UI/RecorderGlass.swift`: only `#available(macOS 26.0, *)` / `.glassEffect()` boundary.
- Create `Sources/RecorderApp/UI/RecorderVisualStyle.swift`: semantic colors and non-Glass surfaces.
- Create `Sources/RecorderApp/UI/RecorderSidebar.swift`: destination selection.
- Create `Sources/RecorderApp/UI/RecordDashboardPresentation.swift`: pure compact dashboard policy/timer.
- Create `Sources/RecorderApp/UI/RecordDashboardView.swift`: former `HeaderView`, meters, controls, health, footer.
- Create `Sources/RecorderApp/UI/RecordingsLibraryView.swift`: former `SessionListView`, transcript and metadata sheets.
- Create `Sources/RecorderApp/UI/RecorderSettingsView.swift`: former permission/capture/Teams/virtual-mic/provider sections.
- Create `Tests/RecorderAppTests/RecorderNavigationTests.swift`, `RecorderActionIDTests.swift`, `RecorderGlassTests.swift`, `RecordDashboardPresentationTests.swift`, `RecorderWorkspaceRenderTests.swift`, and `ContentViewSourceDecompositionTests.swift`.
- Modify only `ContentView.swift` and `AppModelPlaybackTests.swift` for destination roots, presenter spies, and the reusable host helper. Do not modify `AppModel.swift`, `AppRuntime.swift`, or `LocalMeetingRecorderApp.swift`.

## Task 1: Navigation foundation, IDs, and Glass

**Files:** create the five foundation UI files, `RecorderNavigationTests.swift`, `RecorderActionIDTests.swift`, `RecorderGlassTests.swift`, and the initial `RecorderWorkspaceRenderTests.swift`; modify `ContentView.swift`.

**Produces:** `RecorderDestination: String, CaseIterable, Identifiable`; `RecorderNavigationState(selection:)` with `select(_:hasUnsavedChanges:)`, `keepEditing()`, `discardAndNavigate()`; `RecorderActionID`; `RecorderGlassStyle.resolve(majorVersion:)`.

- [ ] **Step 1: Write the failing tests.**

```swift
final class RecorderNavigationTests: XCTestCase {
    func testCleanNavigationSelectsDestinationAndClearsPending() {
        var state = RecorderNavigationState(selection: .record)
        state.select(.recordings, hasUnsavedChanges: false)
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertNil(state.pendingDestination)
    }
    func testDirtyNavigationRequestsConfirmationWithoutChangingSelection() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.settings, hasUnsavedChanges: true)
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertEqual(state.pendingDestination, .settings)
    }
    func testKeepEditingClearsPendingAndRetainsCurrentDestination() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.settings, hasUnsavedChanges: true)
        state.keepEditing()
        XCTAssertEqual(state.selection, .recordings)
        XCTAssertNil(state.pendingDestination)
    }
    func testDiscardSelectsPendingDestinationExactlyOnce() {
        var state = RecorderNavigationState(selection: .recordings)
        state.select(.settings, hasUnsavedChanges: true)
        state.discardAndNavigate()
        XCTAssertEqual(state.selection, .settings)
        XCTAssertNil(state.pendingDestination)
        state.discardAndNavigate()
        XCTAssertEqual(state.selection, .settings)
    }
    func testOneHundredCleanCyclesDoNotLeakPendingRoute() {
        var state = RecorderNavigationState(selection: .record)
        for _ in 0..<100 { state.select(.recordings, hasUnsavedChanges: false); state.select(.settings, hasUnsavedChanges: false); state.select(.record, hasUnsavedChanges: false); XCTAssertNil(state.pendingDestination) }
    }
}
final class RecorderActionIDTests: XCTestCase {
    func testExactAndUniqueIDs() {
        XCTAssertEqual(RecorderActionID.startStop, "recorder.action.start-stop")
        XCTAssertEqual(RecorderActionID.muteMic, "recorder.action.mute-mic")
        XCTAssertEqual(RecorderActionID.testAudio, "recorder.action.test-audio")
        XCTAssertEqual(RecorderActionID.uploadAudio, "recorder.action.upload-audio")
        XCTAssertEqual(RecorderActionID.refreshRecordings, "recorder.action.refresh-recordings")
        XCTAssertEqual(RecorderActionID.openTranscript, "recorder.action.open-transcript")
        XCTAssertEqual(RecorderActionID.saveTranscript, "recorder.action.save-transcript")
        XCTAssertEqual(RecorderActionID.captureRecovery, "recorder.action.capture-recovery")
        XCTAssertEqual(Set(RecorderActionID.all).count, RecorderActionID.all.count)
    }
}
final class RecorderGlassTests: XCTestCase {
    func testVersionBoundary() { XCTAssertEqual(RecorderGlassStyle.resolve(majorVersion: 25), .material); XCTAssertEqual(RecorderGlassStyle.resolve(majorVersion: 26), .glass) }
}
@MainActor final class RecorderWorkspaceRenderTests: XCTestCase {
    func testNavigationShellStartsOnRecordAndCanRenderBaselineDestinations() throws {
        let f = makeStartupDisabledFixture()
        let h = try makeWorkspaceHost(model: f.model, size: .init(width: 860, height: 680))
        defer { h.close() }
        XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.destination.record"))
        h.select(.recordings)
        XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.destination.recordings"))
        h.select(.settings)
        XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.destination.settings"))
    }
}
```

- [ ] **Step 2: Prove RED.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderNavigationTests|RecorderActionIDTests|RecorderGlassTests|RecorderWorkspaceRenderTests'
```

Expected: compile failure for absent symbols.

- [ ] **Step 3: Implement minimum GREEN.**

```swift
enum RecorderDestination: String, CaseIterable, Identifiable, Hashable {
    case record, recordings, settings
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String { switch self { case .record: "record.circle"; case .recordings: "list.bullet.rectangle"; case .settings: "gearshape" } }
}
struct RecorderNavigationState: Equatable {
    var selection: RecorderDestination; private(set) var pendingDestination: RecorderDestination?
    mutating func select(_ destination: RecorderDestination, hasUnsavedChanges: Bool) { if hasUnsavedChanges && destination != selection { pendingDestination = destination } else { selection = destination; pendingDestination = nil } }
    mutating func keepEditing() { pendingDestination = nil }
    mutating func discardAndNavigate() { if let pendingDestination { selection = pendingDestination }; pendingDestination = nil }
}
enum RecorderActionID {
    static let startStop = "recorder.action.start-stop", muteMic = "recorder.action.mute-mic", testAudio = "recorder.action.test-audio", uploadAudio = "recorder.action.upload-audio", refreshRecordings = "recorder.action.refresh-recordings", openTranscript = "recorder.action.open-transcript", saveTranscript = "recorder.action.save-transcript", captureRecovery = "recorder.action.capture-recovery"
    static let all = [startStop, muteMic, testAudio, uploadAudio, refreshRecordings, openTranscript, saveTranscript, captureRecovery]
}
enum RecorderGlassStyle: Equatable { case material, glass; static func resolve(majorVersion: Int) -> Self { majorVersion >= 26 ? .glass : .material } }
struct RecorderGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.glassEffect() }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45))) }
    }
}
extension View { func recorderGlass() -> some View { modifier(RecorderGlass()) } }
```

Implement sidebar as `List(RecorderDestination.allCases, selection: $selection) { Label($0.title, systemImage: $0.systemImage).tag($0) }.accessibilityIdentifier("recorder.workspace.sidebar")`. Put only cyan/green/red semantic constants and stable card surfaces in `RecorderVisualStyle`.

In the same commit, change `ContentView` to own a single
`@State RecorderNavigationState` and compose an internal
`RecorderWorkspaceContent(model:navigation:)`. The internal workspace boundary
accepts a `Binding<RecorderNavigationState>` so the AppKit test host can drive
the real route deterministically; production still has one navigation source
owned by `ContentView`. It is not a feature model or a second workspace-folder
truth.

For this first, buildable transition only, `RecorderWorkspaceContent` uses
three explicitly named temporary adapters around the existing private views:

- `baselineRecordDestination`: existing header, meters, controls, health, and
  footer;
- `baselineRecordingsDestination`: existing `SessionListView`;
- `baselineSettingsDestination`: existing permission row,
  `CaptureControlsView`, and
  `AIProviderSettingsView`.

Give those temporary roots the three destination identifiers, and give the
permission/capture wrapper inside `baselineSettingsDestination` the stable
`recorder.settings.capture-section` identifier needed by the Record recovery
deep link. Do not move or
rename the underlying views in this commit. Later extraction commits replace
the route use but intentionally leave these now-unused adapter declarations
until Task 5, creating a bounded source-cleanup slice. Keep both presenter
`@State` instances and all `onChange`, termination, and `onDisappear` handlers
in `ContentView`.

The host helper owns a main-actor observable navigation driver. `h.select(_:)`
mutates the injected binding, drains the main run loop, and forces
`NSHostingView`/`NSWindow` layout before probing the destination root. It does
not create another production navigation state.

- [ ] **Step 4: Prove GREEN and availability isolation.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderNavigationTests|RecorderActionIDTests|RecorderGlassTests|RecorderWorkspaceRenderTests'
rg -n 'glassEffect|#available\(macOS 26' Sources/RecorderApp
```

Expected: tests pass; availability/Glass hits are only `RecorderGlass.swift`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RecorderApp/ContentView.swift Sources/RecorderApp/UI/RecorderNavigation.swift Sources/RecorderApp/UI/RecorderActionID.swift Sources/RecorderApp/UI/RecorderGlass.swift Sources/RecorderApp/UI/RecorderVisualStyle.swift Sources/RecorderApp/UI/RecorderSidebar.swift Tests/RecorderAppTests/RecorderNavigationTests.swift Tests/RecorderAppTests/RecorderActionIDTests.swift Tests/RecorderAppTests/RecorderGlassTests.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git commit -m "feat: add recorder workspace navigation foundation"
```

Rollback: revert this commit only.

## Task 2: Record dashboard extraction

**Files:** create `RecordDashboardPresentation.swift`, `RecordDashboardView.swift`, `RecordDashboardPresentationTests.swift`; modify `ContentView.swift` and `RecorderWorkspaceRenderTests.swift`.

**Consumes:** only the direct Record commands in the table plus the pure
Settings-route closure. **Produces:**
`RecordDashboardView(model: AppModel, openCaptureSettings: @escaping () -> Void)`.

- [ ] **Step 1: Write RED policy tests.**

```swift
@MainActor final class RecordDashboardPresentationTests: XCTestCase {
    func testCompact860PolicyExposesAllOperationalProbes() {
        let p = RecordDashboardPresentation.make(isRecording: false, startedAt: nil, now: .now, isCaptureLifecycleWorking: false, isRunningTestRecording: false, localMicMuted: false, nativeInputMicMuted: false, teamsMicMuted: false)
        XCTAssertEqual(p.elapsedText, "00:00:00")
        XCTAssertEqual(p.operationalProbeIDs, ["record-state", "elapsed-time", RecorderActionID.startStop, RecorderActionID.muteMic, "system-meter", "microphone-meter", "capture-health"])
    }
    func testCurrentDisabledPoliciesRemainExact() {
        XCTAssertTrue(RecordDashboardPresentation.make(isRecording: false, startedAt: nil, now: .now, isCaptureLifecycleWorking: true, isRunningTestRecording: false, localMicMuted: false, nativeInputMicMuted: false, teamsMicMuted: false).startStopDisabled)
        XCTAssertTrue(RecordDashboardPresentation.make(isRecording: false, startedAt: nil, now: .now, isCaptureLifecycleWorking: false, isRunningTestRecording: false, localMicMuted: false, nativeInputMicMuted: false, teamsMicMuted: true).muteDisabled)
    }
}
@MainActor extension RecorderWorkspaceRenderTests {
    func testMinimumRecordViewportContainsAllOperationalAnchorsWithoutScrolling() throws {
        let f = makeStartupDisabledFixture()
        let h = try makeWorkspaceHost(model: f.model, size: .init(width: 860, height: 680))
        defer { h.close() }
        for id in ["record-state", "elapsed-time", RecorderActionID.startStop, RecorderActionID.muteMic, "system-meter", "microphone-meter", "capture-health"] {
            let frame = try XCTUnwrap(h.frame(forAccessibilityIdentifier: id))
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(h.visibleContentRect.contains(frame), "\(id) must be fully visible without scrolling")
        }
    }
    func testWideRecordViewportContainsAllOperationalAnchorsWithoutScrolling() throws {
        let f = makeStartupDisabledFixture()
        let h = try makeWorkspaceHost(model: f.model, size: .init(width: 1280, height: 800))
        defer { h.close() }
        for id in ["record-state", "elapsed-time", RecorderActionID.startStop, RecorderActionID.muteMic, "system-meter", "microphone-meter", "capture-health"] {
            XCTAssertTrue(h.visibleContentRect.contains(try XCTUnwrap(h.frame(forAccessibilityIdentifier: id))))
        }
    }
    func testBlockingCaptureStateShowsVisibleSettingsRecoveryDeepLink() throws {
        let f = makeStartupDisabledFixture(systemPermission: .denied)
        let h = try makeWorkspaceHost(model: f.model, size: .init(width: 860, height: 680))
        defer { h.close() }
        XCTAssertTrue(h.visibleContentRect.contains(try XCTUnwrap(h.frame(forAccessibilityIdentifier: RecorderActionID.captureRecovery))))
        h.activate(RecorderActionID.captureRecovery)
        XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.settings.capture-section"))
    }
}
```

- [ ] **Step 2: Prove RED.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecordDashboardPresentationTests|RecorderWorkspaceRenderTests'
```

Expected: absent `RecordDashboardPresentation`/new operational identifiers and
the baseline Record destination does not satisfy the no-scroll frame contract.

- [ ] **Step 3: Implement and move exact baseline views.**

```swift
struct RecordDashboardPresentation: Equatable {
    let elapsedText: String; let startStopDisabled: Bool; let testDisabled: Bool; let muteDisabled: Bool
    let operationalProbeIDs = ["record-state", "elapsed-time", RecorderActionID.startStop, RecorderActionID.muteMic, "system-meter", "microphone-meter", "capture-health"]
    static func make(isRecording: Bool, startedAt: Date?, now: Date, isCaptureLifecycleWorking: Bool, isRunningTestRecording: Bool, localMicMuted: Bool, nativeInputMicMuted: Bool, teamsMicMuted: Bool) -> Self {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
        return .init(elapsedText: String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60), startStopDisabled: !isRecording && isCaptureLifecycleWorking, testDisabled: isRecording || isRunningTestRecording || isCaptureLifecycleWorking, muteDisabled: (teamsMicMuted || nativeInputMicMuted) && !localMicMuted)
    }
}
struct RecordDashboardView: View {
    @ObservedObject var model: AppModel
    let openCaptureSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordDashboardHeader(model: model).accessibilityIdentifier("record-state")
            RecordDashboardMeters(model: model)
            RecordDashboardControls(model: model)
            RecordDashboardHealth(model: model).accessibilityIdentifier("capture-health")
            RecordDashboardFooter(model: model)
        }.padding(16).accessibilityIdentifier("recorder.destination.record")
    }
}
```

Move former `HeaderView`, `MeterSectionView`, `ControlsView`, `HealthSummaryView`, `LiveAudioHealthView`, `FooterView`, and `AudioDevice.channelText` into this file. In controls use exactly:

```swift
Button(action: model.startOrStop) { Label(model.recorder.isRecording ? "Stop Recording" : "Start Recording", systemImage: model.recorder.isRecording ? "stop.fill" : "record.circle") }.accessibilityIdentifier(RecorderActionID.startStop).disabled(!model.recorder.isRecording && model.isCaptureLifecycleWorking)
Button(action: model.runTestRecording) { Label(model.isRunningTestRecording ? "Testing..." : "Test 10s", systemImage: "waveform.badge.magnifyingglass") }.accessibilityIdentifier(RecorderActionID.testAudio).disabled(model.recorder.isRecording || model.isRunningTestRecording || model.isCaptureLifecycleWorking)
Button { model.toggleRecorderMicMute() } label: { Label(micMuteTitle, systemImage: model.localMicMuted ? "mic.fill" : "mic.slash.fill") }.accessibilityIdentifier(RecorderActionID.muteMic).accessibilityValue(model.localMicMuted ? "local-muted" : (model.teamsMicMuted ? "teams-muted" : (model.nativeInputMicMuted ? "input-muted" : "active"))).disabled((model.teamsMicMuted || model.nativeInputMicMuted) && !model.localMicMuted)
```

Mark elapsed time, meter roots, and health as `elapsed-time`, `system-meter`,
`microphone-meter`, and `capture-health`. Keep the operational region outside
an enclosing vertical `ScrollView`; compact spacing/layout priority must make
the full probe frames visible inside the actual 860×680 content rect. Preserve
meter colors/inputs and every remaining baseline body/disabled expression.

Add `RecorderActionID.captureRecovery`. When existing state reports a denied
or not-determined permission or a disconnected selected application, show a
compact blocking-state message with a button that calls
`openCaptureSettings`. That closure only changes the existing
`RecorderNavigationState.selection` to `.settings`; it does not request
permission, reconnect, or add state. The Settings capture section owns
`recorder.settings.capture-section` so the test proves the deep link landed at
the exact recovery destination.

For rollback-safe composition, replace only the temporary Record adapter with
`RecordDashboardView`. Recordings and Settings continue to use their Task 1
baseline adapters. Keep Upload Audio temporarily in the Record controls until
Task 3 moves the same `chooseAudioFileForTranscription()` command into
Recordings atomically.

- [ ] **Step 4: Prove GREEN.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecordDashboardPresentationTests|RecorderWorkspaceRenderTests|RecordingControllerPresentationTests|AppModelMuteTests'
```

- [ ] **Step 5: Commit.**

```bash
git add Sources/RecorderApp/ContentView.swift Sources/RecorderApp/UI/RecordDashboardPresentation.swift Sources/RecorderApp/UI/RecordDashboardView.swift Tests/RecorderAppTests/RecordDashboardPresentationTests.swift
git commit -m "refactor: extract record dashboard presentation"
```

Rollback: revert this commit; no runtime/data ownership changed.

## Task 3: Recordings extraction and rendered AVPlayer isolation

**Files:** create `RecordingsLibraryView.swift`; modify `ContentView.swift`,
`RecordDashboardView.swift`, `RecorderWorkspaceRenderTests.swift`, and
`AppModelPlaybackTests.swift`.

**Consumes:** direct library/transcription actions above; existing `RecordingLibraryQuery`, transcript/metadata stores. **Produces:** `RecordingsLibraryView(model: AppModel)` and deterministic AppKit host helper.

- [ ] **Step 1: Write RED library, repeated-render, and presenter-lifetime tests.**

```swift
@MainActor extension RecorderWorkspaceRenderTests {
    func testRecordingsOwnsUploadRefreshAndSessionSpecificActions() throws {
        let f = makeFixtureWithOneSession()
        let h = try makeWorkspaceHost(model: f.model, size: .init(width: 1280, height: 800))
        defer { h.close() }
        h.select(.recordings)
        XCTAssertTrue(h.containsAccessibilityIdentifier(RecorderActionID.uploadAudio))
        XCTAssertTrue(h.containsAccessibilityIdentifier(RecorderActionID.refreshRecordings))
        XCTAssertTrue(h.containsAccessibilityLabel("Play \(f.session.displayName)"))
        XCTAssertTrue(h.containsAccessibilityLabel("Edit details for \(f.session.displayName)"))
    }
    func testTwentyFiveRecordRecordingsCyclesRenderWithoutPendingLeak() throws {
        let f = makeStartupDisabledFixture()
        let h = try makeWorkspaceHost(model: f.model, size: .init(width: 1280, height: 800))
        defer { h.close() }
        for _ in 0..<25 {
            h.select(.recordings)
            XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.destination.recordings"))
            h.select(.record)
            XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.destination.record"))
            XCTAssertNil(h.navigationState.pendingDestination)
        }
    }
}
@MainActor extension AppModelPlaybackTests {
    func testContentViewOwnsOnePlaybackAndCountdownPresenterAcrossNavigationCycles() throws {
        // Inject factory spies, host ContentView, drive 25 Record/Recordings
        // cycles, and assert each factory made exactly one presenter.
    }
    func testExercisedVideoPlaybackRemainsOutsideWorkspaceAfterNavigationCycles() async throws {
        // Call model.play(session:), prove the playback presenter received one
        // presentation, cycle destinations, then recursively assert that the
        // hosting view contains no AVPlayerView.
    }
}
```

- [ ] **Step 2: Prove RED.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderWorkspaceRenderTests|AppModelPlaybackTests'
```

Expected: missing recordings root/IDs and presenter factory/lifetime assertions
fail against the temporary adapter. The playback test must first assert that
the presenter spy was invoked so absence of an embedded `AVPlayerView` cannot
produce a false green.

- [ ] **Step 3: Move exact library UI and retain shell presenter ownership.**

```swift
struct RecordingsLibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SessionListView(
            sessions: model.sessions, transcribingSessionID: model.transcribingSessionID, transcriptionStatus: model.transcriptionStatus,
            lastTranscriptionSessionID: model.lastTranscriptionSessionID, lastTranscriptionStatus: model.lastTranscriptionStatus,
            lastTranscriptionDidFail: model.lastTranscriptionDidFail, hasSavedProviderProfile: model.aiProviderSettingsModel.hasSavedProfile,
            transcriptionStatesBySessionID: model.transcriptionStatesBySessionID, refresh: model.refreshSessions, play: model.play,
            open: model.open, transcribe: model.transcribe, cancelTranscription: model.cancelTranscription,
            openTranscript: model.openTranscript, openTranscriptLog: model.openTranscriptLog, transcriptText: model.transcriptText,
            saveTranscript: model.saveTranscript, exportTranscript: model.exportTranscript, copyTranscript: model.copyTranscript,
            saveMetadata: model.saveMetadata, moveToTrash: model.moveSessionToTrash
        ).accessibilityIdentifier("recorder.destination.recordings")
    }
}
```

Move complete baseline `SessionListView`, `TranscriptEditorView`,
`RecordingMetadataEditorView` into this file, retaining local
state/sheets/dialog, search/snippets/favorites, and file checks. Add a library
toolbar whose Upload Audio and Refresh buttons call exactly
`model.chooseAudioFileForTranscription()` and `model.refreshSessions()`. In the
same commit remove Upload Audio from `RecordDashboardView`, so the command is
never duplicated in the final presentation. Add IDs `refreshRecordings`,
`uploadAudio`, `openTranscript`, `saveTranscript`, plus exact row labels:
`Play \(session.displayName)`, `Open \(session.displayName)`,
`Edit details for \(session.displayName)`,
`Transcribe \(session.displayName)`,
`Open Transcript for \(session.displayName)`,
`Open ASR log for \(session.displayName)`,
`Move \(session.displayName) to Trash`.

Retain verbatim in `ContentView`: playback `onChange` calls existing presenter with `model.playbackPresentation`, `model.playbackToggle`, `model.stopPlayback()`, `model.seekPlayback`; countdown `onChange` calls only `autoMeetingPanel.present/dismiss`. The row only calls `model.play(session:)`; never embed `AVPlayerView`.

Replace only the temporary Recordings adapter; Settings remains the baseline
adapter. The host helper uses a startup-disabled `AppModel`, temporary folder,
and deterministic permission/providers; it hosts actual `ContentView` in
`NSHostingView`/`NSWindow`, disables animation, forces layout, recursively
scans accessibility/layout and AppKit views, and clears `window.contentView`
in `close()`. It must not launch real capture/Teams/provider services.

Add playback and countdown presenter factory spies at the `ContentView`
boundary. Assert construction exactly once, no reconstruction across route
changes, existing state-driven present/dismiss behavior, and dismissal on
disappearance/termination. Do not move the presenter instances into the
workspace content or runtime.

- [ ] **Step 4: Prove GREEN.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderWorkspaceRenderTests|AppModelPlaybackTests|RecordingLibraryTests|AppModelTranscriptionTests'
```

- [ ] **Step 5: Commit.**

```bash
git add Sources/RecorderApp/ContentView.swift Sources/RecorderApp/UI/RecordDashboardView.swift Sources/RecorderApp/UI/RecordingsLibraryView.swift Tests/RecorderAppTests/AppModelPlaybackTests.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git commit -m "refactor: extract recordings library presentation"
```

Rollback: revert this commit; playback runtime remains untouched.

## Task 4: Settings extraction

**Files:** create `RecorderSettingsView.swift`; modify `ContentView.swift`, render tests; modify existing UI-facing tests only if an assertion follows a moved identifier.

- [ ] **Step 1: Write RED settings render test.**

```swift
@MainActor extension RecorderWorkspaceRenderTests {
func testSettingsRendersExistingCaptureTeamsVirtualMicAndProviderSections() throws {
    let f = makeStartupDisabledFixture(); let h = try makeWorkspaceHost(model: f.model, size: .init(width: 1280, height: 800)); defer { h.close() }
    h.select(.settings)
    XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.destination.settings"))
    XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.settings.capture-section"))
    XCTAssertTrue(h.containsAccessibilityIdentifier("capture-mode-picker"))
    XCTAssertTrue(h.containsAccessibilityIdentifier("teams-auto-recording-toggle"))
    XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.settings.audio-integration-section"))
    XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.settings.transcription-section"))
}
func testSourceControlGatesRemainDisabledDuringLifecycleWork() throws {
    let f = makeLifecycleWorkingFixture()
    let h = try makeWorkspaceHost(model: f.model, size: .init(width: 1280, height: 800))
    defer { h.close() }
    h.select(.settings)
    XCTAssertFalse(try h.isEnabled("capture-mode-picker"))
    XCTAssertFalse(try h.isEnabled("recorder.settings.capture-application-picker"))
    XCTAssertFalse(try h.isEnabled("recorder.settings.capture-refresh"))
    XCTAssertFalse(try h.isEnabled("recorder.settings.microphone-picker"))
}
}
```

- [ ] **Step 2: Prove RED.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderWorkspaceRenderTests|AppModelScreenCaptureTests|TeamsAutoMeetingPresentationTests'
```

- [ ] **Step 3: Implement direct-model settings sections.**

```swift
struct RecorderSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Capture") {
                PermissionStatusView(
                    systemPermission: model.systemAudioPermission,
                    microphonePermission: model.microphonePermission,
                    requestSystem: model.requestSystemAudioPermission,
                    requestMicrophone: model.requestMicrophonePermission,
                    openSystemSettings: model.openScreenCaptureSettings,
                    openMicrophoneSettings: model.openMicrophoneSettings
                )
                CaptureSourceControlsView(model: model)
            }.accessibilityIdentifier("recorder.settings.capture-section")
            SettingsSection("Teams") {
                if model.showsTeamsScreenCaptureControls { TeamsScreenCaptureControlsView(model: model) }
                TeamsAutoMeetingDetailView(presentation: autoMeetingPresentation, isEnabled: autoMeetingBinding)
                TeamsAutoMeetingStateView(presentation: autoMeetingPresentation, cancel: model.cancelTeamsAutoMeetingCountdown)
                TeamsMuteSyncDetailView(status: model.teamsMuteSyncStatus, isEnabled: muteSyncBinding)
                TeamsMuteSyncStateView(status: model.teamsMuteSyncStatus, retry: model.retryTeamsMuteSync, requestPairing: model.requestTeamsPairing)
            }
            SettingsSection("Audio Integration") {
                VirtualMicIdentityView(recorder: model.recorder, installationState: model.virtualMicInstallationState, inputMuteControlAvailable: model.inputMuteControlAvailable)
                VirtualMicStateView(recorder: model.recorder, installationState: model.virtualMicInstallationState, inputMuteControlAvailable: model.inputMuteControlAvailable)
            }.accessibilityIdentifier("recorder.settings.audio-integration-section")
            SettingsSection("Transcription") { AIProviderSettingsView(model: model.aiProviderSettingsModel) }
                .accessibilityIdentifier("recorder.settings.transcription-section")
        }.padding(20) }.accessibilityIdentifier("recorder.destination.settings")
    }
}
```

Move the baseline types with this exact source/destination map:

| Current type/content | New Settings location |
|---|---|
| `PermissionStatusView` | Capture section, same six state/closure inputs shown above |
| capture mode/application/microphone rows from `CaptureControlsView` | `CaptureSourceControlsView`, with local `@State applicationSearch` |
| `TeamsScreenCaptureControlsView` composition | Teams section, unchanged type and actions |
| `TeamsAutoMeetingDetailView` + `TeamsAutoMeetingStateView` | Teams section, exact bindings/actions |
| `TeamsMuteSyncDetailView` + `TeamsMuteSyncStateView` | Teams section, exact bindings/actions |
| `VirtualMicIdentityView` + `VirtualMicStateView` | Audio Integration section |
| `AIProviderSettingsView(model: model.aiProviderSettingsModel)` | Transcription section |
| `AudioDevice.channelText` | `RecorderSettingsView.swift` private extension |

Preserve the exact source gates:

- capture-mode picker, application menu, application refresh, and microphone
  picker: `.disabled(!model.sourceControlsEnabled)`;
- selected-application reconnect:
  `.disabled(!model.canReconnect)`;
- existing `TeamsScreenCaptureControlsView` gates: unchanged in its own source;
- start/test/mute policies: remain in Record and are not redefined here.

Add stable IDs to the existing application menu, refresh action, and
microphone picker solely so the disabled-state regression can probe them.
Keep all old identifiers, permissions/recovery commands, selected
application/window actions, pairing/retry/cancel commands, and the exact
provider-model injection.

Replace only the temporary Settings adapter with
`RecorderSettingsView(model:)`; Record and Recordings already use their
extracted views.

- [ ] **Step 4: Prove GREEN.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderWorkspaceRenderTests|AppModelScreenCaptureTests|TeamsAutoMeetingPresentationTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'AppModelMuteTests|AppModelTeamsAutoMeetingTests|TeamsMuteSyncTests|TeamsCaptureWindowPickerModelTests|AIProviderSettingsModelTests'
rg -n 'workspaceRevision' Sources/RecorderApp/UI
```

Expected: tests pass and ripgrep emits no workspace-revision result.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RecorderApp/ContentView.swift Sources/RecorderApp/UI/RecorderSettingsView.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git commit -m "refactor: extract recorder settings presentation"
```

Rollback: revert this commit; capture/Teams/provider ownership remains in `AppModel`.

## Task 5: Source cleanup, final three-route regression, full gate, manual evidence, Draft PR

**Files:** modify `ContentView.swift` and extracted views only for compilation
cleanup; create `ContentViewSourceDecompositionTests.swift`; modify
render/playback tests only if final assertions require it.

- [ ] **Step 1: Add RED final three-destination repeated-render test.**

```swift
@MainActor extension RecorderWorkspaceRenderTests {
func testTwentyFiveNavigationCyclesRenderEveryDestinationWithoutPendingLeak() throws {
    let f = makeStartupDisabledFixture(); let h = try makeWorkspaceHost(model: f.model, size: .init(width: 860, height: 680)); defer { h.close() }
    for _ in 0..<25 {
        for destination in RecorderDestination.allCases {
            h.select(destination)
            XCTAssertTrue(h.containsAccessibilityIdentifier("recorder.destination.\(destination.rawValue)"))
            XCTAssertNil(h.navigationState.pendingDestination)
        }
    }
    XCTAssertFalse(containsAVPlayerView(in: h.hostingView))
}
}
final class ContentViewSourceDecompositionTests: XCTestCase {
func testContentViewContainsNoMovedViewDeclarations() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot
            .appendingPathComponent("Sources/RecorderApp/ContentView.swift"),
        encoding: .utf8
    )
    for temporaryAdapter in [
        "baselineRecordDestination",
        "baselineRecordingsDestination",
        "baselineSettingsDestination"
    ] {
        XCTAssertFalse(source.contains(temporaryAdapter))
    }
    for movedType in [
        "PermissionStatusView", "CaptureControlsView", "HeaderView",
        "MeterSectionView", "ControlsView", "HealthSummaryView",
        "LiveAudioHealthView", "SessionListView", "TranscriptEditorView",
        "RecordingMetadataEditorView", "FooterView"
    ] {
        XCTAssertFalse(source.contains("struct \(movedType)"))
    }
}
}
```

- [ ] **Step 2: Prove RED then make minimal source cleanup GREEN.**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecorderWorkspaceRenderTests|ContentViewSourceDecompositionTests'
```

The source-decomposition assertion is the intentional RED for this slice;
the three-route test simultaneously protects behavior while cleanup occurs.
Then delete the now-unused temporary adapters and every moved private
declaration from `ContentView.swift`.

Retain only the injected model, one navigation state, two presenter `@State`
values, internal destination composition, current `onChange` handlers,
terminate observer, and `onDisappear` in `ContentView`:

```swift
private var workspace: some View {
    NavigationSplitView {
        RecorderSidebar(selection: Binding(get: { navigation.selection }, set: { navigation.select($0, hasUnsavedChanges: false) }))
    } detail: {
        switch navigation.selection {
        case .record:
            RecordDashboardView(
                model: model,
                openCaptureSettings: {
                    navigation.select(.settings, hasUnsavedChanges: false)
                }
            )
        case .recordings: RecordingsLibraryView(model: model)
        case .settings: RecorderSettingsView(model: model)
        }
    }
}
```

`RecorderWorkspaceContent` and its injected navigation binding were introduced
in Task 1 and remain the single shell route boundary; this task does not
introduce a second shell or navigation owner. Do not touch
`LocalMeetingRecorderApp.swift`: unresolved Cmd+Shift+R remains untouched.

Run the same command again. Expected: GREEN.

- [ ] **Step 3: Commit the rollback-safe source cleanup.**

```bash
git add Sources/RecorderApp/ContentView.swift Sources/RecorderApp/UI Tests/RecorderAppTests/ContentViewSourceDecompositionTests.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift Tests/RecorderAppTests/AppModelPlaybackTests.swift
git commit -m "refactor: compose recorder workspace shell"
```

Rollback: revert this commit; the four prior commits still contain a
buildable shell and destination implementations.

- [ ] **Step 4: Rebase and complete the automated gate on the final SHA.**

Fetch and rebase onto the latest `origin/main`, resolving only PR A files.
Never bring Windows migration work into this branch. After rebase, rerun every
command below; pre-rebase results are not final evidence.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
/usr/bin/python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py' -v
/usr/bin/python3 -m unittest Tests.ScriptTests.test_packaging_contract Tests.ScriptTests.test_workflow_contract -v
Tests/PackagingTests/run-tests.sh
Tests/VirtualMicDriverTests/run-tests.sh
Tests/VirtualMicDriverTests/run-bundle-tests.sh
Tests/VirtualMicDriverTests/run-script-tests.sh
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lmr-pr-a.XXXXXX")"
Scripts/build-app.sh --configuration release --version 0.1.0 --build-number 1 --bundle-id local.meeting.recorder.staging --bundle-name "Local Meeting Recorder Staging" --output "$STAGING_ROOT/Local Meeting Recorder Staging.app" --sign ad-hoc
Scripts/verify-app-bundle.sh "$STAGING_ROOT/Local Meeting Recorder Staging.app" local.meeting.recorder.staging 0.1.0 1 ad-hoc
codesign --verify --deep --strict --verbose=2 "$STAGING_ROOT/Local Meeting Recorder Staging.app"
find "$STAGING_ROOT/Local Meeting Recorder Staging.app/Contents/Resources" \( -iname '*.py' -o -iname '*ffmpeg*' -o -iname '*ffprobe*' \) -print
git diff --check origin/main...HEAD
git status --short
```

Expected: two full Swift passes; Python, policy, packaging, virtual-mic
unit/bundle/script gates pass; the release-configuration staging bundle passes
strict ad-hoc codesign and bundle-contract verification; the bundle-content
`find` prints nothing; diff check prints nothing; only intended PR A files
are present in the committed diff; `git status --short` prints nothing after
the rebase. If the AppKit host cannot run, record the exact limitation as
`not run`; pure tests never convert manual acceptance to passed.
Developer ID, Hardened Runtime, notarization, stapling, and `spctl` remain
explicitly `not run` without production release authorization.

- [ ] **Step 5: Perform manual 860×680 acceptance and preserve evidence.**

At exact 860×680, capture a screenshot of Record showing without scrolling: state/timer, Start/Stop, Mute, both meters, health. Capture wide Record/Recordings/Settings. Check Start/Stop/Mute routing, independent playback/countdown presenters, light/dark/material fallback, keyboard traversal/current shortcuts, VoiceOver labels where permitted. Report each as `passed` or `not run` with tester, date, macOS version, and screenshot path; explicitly list unrun Teams/provider/TCC/AirPods/macOS-26 Glass checks.

- [ ] **Step 6: Push and create/update the Draft PR only.**

Draft PR must list baseline SHA, five reversible commits (navigation, Record, Recordings, Settings, shell cleanup), full command output, manual evidence, preserved presenter/runtime wiring, `AppModel.outputFolder` sole source, absence of `workspaceRevision`/feature models/coordinator, and unresolved Cmd+Shift+R left untouched. Do not mark ready for review.

## Completion review

- [ ] Every original `ContentView` responsibility is mapped above and exists once.
- [ ] Every action calls exactly the existing `AppModel` command named above.
- [ ] `ContentView` alone retains playback/countdown presenters; no `AVPlayerView` exists in main hierarchy.
- [ ] 860×680, wide, 25 rendered cycles, and 100 pure cycles are covered.
- [ ] No state/ownership migration, `workspaceRevision`, or second folder source exists.
- [ ] Design header is Approved architecture baseline with exact SHA and date.
