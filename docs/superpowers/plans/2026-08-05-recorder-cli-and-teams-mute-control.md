# Recorder CLI and Teams Mute Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local `recorderctl` command, background-control app launch, microphone-device Refresh, and fail-safe best-effort Teams mute status/control without depending on the retired Teams API.

**Architecture:** A shared Swift target defines the versioned JSON contract and Unix-socket transport. The app hosts a same-user socket server and maps explicit idempotent commands onto `AppModel`; the bundled CLI is only a client and background launcher. Teams mute support is isolated behind an Accessibility adapter, feeds a third source into the existing microphone gate, and degrades to `unknown` without affecting recording or Auto Mode.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit/SwiftUI, Foundation, Darwin Unix sockets, ApplicationServices Accessibility, XCTest, existing Python and shell packaging tests.

## Global Constraints

- Keep macOS 26.0 as the minimum deployment target.
- Do not add a daemon, remote listener, third-party package, or Teams private/web API.
- The socket directory must be user-owned mode `0700`; the socket must be mode `0600`; accepted peer UID must match the app UID.
- Staging and production endpoints must not collide.
- CLI commands must be explicit and idempotent; never implement start/stop or mute as a remote toggle.
- App absence must cause a background launch that neither activates the app nor shows the main window.
- Accessibility remains optional and is never used for meeting detection.
- Recorder local mute remains authoritative; mute is local-first and unmute is Teams-confirmed-first.
- Teams `unknown` must never be rendered as muted or live and must never automatically unmute Recorder output.
- Microphone Refresh may update the displayed list during recording but must not switch the active recording input.
- Tests must remain focused: use pure classifiers and fakes for Accessibility; do not reproduce the complete Teams UI tree.

---

## File Structure

- `Sources/RecorderControl/RecorderControlMessages.swift`: versioned request, response, error, and status value types shared by app and CLI.
- `Sources/RecorderControl/RecorderControlEndpoint.swift`: short per-user staging/production socket paths and ownership validation.
- `Sources/RecorderControl/UnixSocketTransport.swift`: bounded one-request/one-response Unix socket server and client.
- `Sources/RecorderControlCLI/RecorderCLICommand.swift`: dependency-free command parsing.
- `Sources/RecorderControlCLI/RecorderCLIApplication.swift`: launch/connect/retry/watch orchestration and output.
- `Sources/RecorderControlCLI/RecorderAppLauncher.swift`: resolve containing app and invoke `/usr/bin/open` in background mode.
- `Sources/RecorderControlCLI/main.swift`: process entry point only.
- `Sources/RecorderApp/Control/AppModelControlAdapter.swift`: main-actor command routing and status projection.
- `Sources/RecorderApp/Teams/TeamsMuteAccessibilityAdapter.swift`: Accessibility permission, bounded element discovery, state read, and AXPress.
- `Sources/RecorderApp/Teams/TeamsMuteSyncCoordinator.swift`: one-second observation and fail-safe mute/unmute ordering.
- Existing `AppModel`, `AppRuntime`, app delegate, settings, floating panel, build, install, and verification files receive narrow integration changes.

---

### Task 1: Shared Control Contract and Endpoint Identity

**Files:**
- Modify: `Package.swift`
- Create: `Sources/RecorderControl/RecorderControlMessages.swift`
- Create: `Sources/RecorderControl/RecorderControlEndpoint.swift`
- Create: `Tests/RecorderControlTests/RecorderControlMessagesTests.swift`
- Create: `Tests/RecorderControlTests/RecorderControlEndpointTests.swift`

**Interfaces:**
- Produces: `RecorderControlRequest`, `RecorderControlResponse`, `RecorderControlErrorPayload`, `RecorderControlStatus`, `RecorderControlCommand`, `RecorderControlEndpoint`.
- `RecorderControlRequest.protocolVersion` is exactly `1`.
- `RecorderControlEndpoint` maps bundle IDs ending in `.staging` to `staging.sock`; all other Local Meeting Recorder bundle IDs map to `production.sock`.

- [ ] **Step 1: Add the failing contract tests and empty SwiftPM target declaration**

Add products/targets to `Package.swift` so the test target compiles far enough to report missing shared types:

```swift
.library(name: "RecorderControl", targets: ["RecorderControl"]),
```

```swift
.target(name: "RecorderControl"),
.testTarget(
    name: "RecorderControlTests",
    dependencies: ["RecorderControl"]
),
```

Add `RecorderControl` to the existing `RecorderApp` and `RecorderAppTests`
dependencies. Do not declare the CLI target until Task 4 creates its source
directory.

Write tests that construct this exact request and round-trip it through `JSONEncoder`/`JSONDecoder`:

```swift
let request = RecorderControlRequest(
    requestID: "request-1",
    command: .setAuto,
    argument: "on"
)
XCTAssertEqual(request.protocolVersion, 1)
XCTAssertEqual(try roundTrip(request), request)
```

Write one full `RecorderControlStatus` fixture and assert response round-trip equality. Add endpoint assertions:

```swift
XCTAssertEqual(
    RecorderControlEndpoint.socketName(
        bundleIdentifier: "local.meeting.recorder.staging"
    ),
    "staging.sock"
)
XCTAssertEqual(
    RecorderControlEndpoint.socketName(
        bundleIdentifier: "local.meeting.recorder"
    ),
    "production.sock"
)
XCTAssertLessThan(endpoint.socketPath.utf8.count, 100)
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
swift test --filter 'RecorderControl(Messages|Endpoint)Tests'
```

Expected: compile failure for missing `RecorderControlRequest`, `RecorderControlStatus`, and `RecorderControlEndpoint`.

- [ ] **Step 3: Implement the minimal shared value types**

Use these public signatures:

```swift
public enum RecorderControlCommand: String, Codable, Sendable {
    case status
    case start
    case stop
    case setAuto = "set-auto"
    case setMic = "set-mic"
}

public struct RecorderControlRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public let protocolVersion: Int
    public let requestID: String
    public let command: RecorderControlCommand
    public let argument: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        command: RecorderControlCommand,
        argument: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.command = command
        self.argument = argument
    }
}

public struct RecorderControlErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
}

public struct RecorderControlStatus: Codable, Equatable, Sendable {
    public let appRunning: Bool
    public let appVersion: String
    public let recordingState: String
    public let lifecycleOperation: String
    public let recordingOwnership: String?
    public let elapsedSeconds: Int?
    public let activeRecordingFolder: String?
    public let statusMessage: String
    public let autoModeEnabled: Bool
    public let autoMeetingState: String
    public let meetingDetectionState: String
    public let selectedMicrophoneName: String?
    public let selectedMicrophoneUID: String?
    public let localMicMuted: Bool
    public let nativeInputMicMuted: Bool
    public let teamsMicState: String
    public let effectiveMicMuted: Bool
    public let virtualMicState: String
    public let systemAudioPermission: String
    public let microphonePermission: String
    public let outputFolder: String
}

public struct RecorderControlResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let ok: Bool
    public let status: RecorderControlStatus?
    public let error: RecorderControlErrorPayload?
}
```

Give every public struct an explicit public memberwise initializer with exactly
the stored properties above; do not rely on Swift's internal synthesized
initializer.

Implement `RecorderControlEndpoint` with `/tmp/lmr-<uid>/staging.sock` and `/tmp/lmr-<uid>/production.sock`, explicit `0700` directory validation, and no recursive deletion. Reject a symlink, non-directory, wrong owner, or group/other-accessible directory.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run:

```bash
swift test --filter 'RecorderControl(Messages|Endpoint)Tests'
```

Expected: all new contract and endpoint tests pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Package.swift Sources/RecorderControl Tests/RecorderControlTests
git commit -m "feat: define recorder control protocol"
```

---

### Task 2: Idempotent AppModel Control Adapter

**Files:**
- Create: `Sources/RecorderApp/Control/AppModelControlAdapter.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Create: `Tests/RecorderAppTests/AppModelControlAdapterTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelMuteTests.swift`

**Interfaces:**
- Consumes: Task 1 request/response/status values.
- Produces: `AppModelControlAdapter.handle(_:) async -> RecorderControlResponse`.
- Produces explicit `AppModel.startRecordingFromControl()`, `stopRecordingFromControl()`, and `setRecorderMicMuted(_:source:)` actions.
- Produces `RecorderControlActionOutcome` with `.accepted`, `.noOp`, and `.rejected(code:message:)` so transport success is not confused with an app operation rejection.

- [ ] **Step 1: Write failing idempotency and status tests**

Use an `AppModel` with injected fake recorder dependencies and assert:

```swift
let first = await adapter.handle(.init(
    requestID: "auto-1", command: .setAuto, argument: "on"
))
let second = await adapter.handle(.init(
    requestID: "auto-2", command: .setAuto, argument: "on"
))
XCTAssertTrue(first.ok)
XCTAssertTrue(second.ok)
XCTAssertTrue(model.teamsAutoMeetingEnabled)
```

Add focused cases for:

- `start` while already recording does not call a second start.
- `stop` with nothing active is a successful no-op.
- `stop` during a pending/active automatic meeting suppresses that meeting.
- repeated `mic mute` remains muted and repeated `mic unmute` remains unmuted.
- unsupported protocol version returns `unsupported_protocol` without mutation.
- invalid arguments return `invalid_argument`.
- status maps the selected mic, permissions, auto state, ownership, active folder, and all mute sources without credentials.

- [ ] **Step 2: Run the focused adapter tests and confirm RED**

Run:

```bash
swift test --filter AppModelControlAdapterTests
```

Expected: compile failure for the missing adapter and explicit AppModel actions.

- [ ] **Step 3: Add explicit AppModel actions without changing GUI semantics**

Add:

```swift
enum RecorderControlActionOutcome: Equatable {
    case accepted
    case noOp
    case rejected(code: String, message: String)
}

func startRecordingFromControl() -> RecorderControlActionOutcome {
    if recorder.isRecording { return .noOp }
    guard !isCaptureLifecycleWorking else {
        return .rejected(
            code: "busy",
            message: "Another capture operation is in progress."
        )
    }
    guard captureReadiness == .ready else {
        return .rejected(code: "not_ready", message: readinessMessage)
    }
    teamsAutoMeetingCoordinator.manualRecordingStarted()
    beginRecording(ownership: .manual, requestPermissions: false)
    return .accepted
}

func stopRecordingFromControl() -> RecorderControlActionOutcome {
    let hadWork = recorder.isRecording || pendingRecordingAttempt != nil
    guard hadWork else { return .noOp }
    stopCaptureLifecycle(playAfterStop: false)
    return .accepted
}

func setRecorderMicMuted(
    _ muted: Bool,
    source: String = "Control"
) {
    let snapshot = microphoneMuteGate.setLocalMuted(muted)
    publishMicrophoneMuteSnapshot(snapshot)
    statusMessage = "\(source): recorder mic \(snapshot.effectiveMuted ? "muted" : "active")"
}
```

Refactor `toggleRecorderMicMute` to calculate the desired local value and call `setRecorderMicMuted`; retain its existing user-facing status for the native-input-remains-muted case.

- [ ] **Step 4: Implement request validation, command routing, and status projection**

Create the main-actor adapter:

```swift
@MainActor
final class AppModelControlAdapter {
    private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    func handle(
        _ request: RecorderControlRequest
    ) async -> RecorderControlResponse
}
```

Route only exact arguments `on`, `off`, `mute`, and `unmute`. Convert
`.rejected` into `ok: false` with its stable code/message; `.accepted` and
`.noOp` return `ok: true`. After every command, return a fresh snapshot. Map
enums through exhaustive private functions rather than `String(describing:)`,
so JSON values remain stable.

Use `model.recorder.outputFolder` as the active recording folder and calculate elapsed whole seconds from `startedAt`. Set `effectiveMicMuted` from the microphone-gate snapshot, not from a UI label.

- [ ] **Step 5: Run focused tests and existing mute/auto tests**

Run:

```bash
swift test --filter AppModelControlAdapterTests
swift test --filter AppModelMuteTests
swift test --filter TeamsAutoMeetingCoordinatorTests
```

Expected: all selected suites pass with no duplicate start/stop/mute action.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/RecorderApp/Control Sources/RecorderApp/AppModel.swift Tests/RecorderAppTests/AppModelControlAdapterTests.swift Tests/RecorderAppTests/AppModelMuteTests.swift
git commit -m "feat: expose idempotent recorder controls"
```

---

### Task 3: Same-User Unix Socket Transport and App Server

**Files:**
- Create: `Sources/RecorderControl/UnixSocketTransport.swift`
- Create: `Sources/RecorderApp/Control/RecorderControlServerRuntime.swift`
- Modify: `Sources/RecorderApp/AppRuntime.swift`
- Create: `Tests/RecorderControlTests/UnixSocketTransportTests.swift`
- Create: `Tests/RecorderAppTests/RecorderControlServerRuntimeTests.swift`

**Interfaces:**
- Produces: `RecorderControlSocketClient.send(_:to:timeout:) async throws -> RecorderControlResponse`.
- Produces: `RecorderControlSocketServer.start()` and `stop()` with an async request handler.
- The maximum request or response frame is `65_536` bytes including its terminating newline.

- [ ] **Step 1: Write failing one-request/one-response transport tests**

Use a temporary short socket path and a handler that echoes the request ID. Cover only:

```swift
let response = try await client.send(request, to: endpoint, timeout: 1)
XCTAssertEqual(response.requestID, request.requestID)
XCTAssertTrue(response.ok)
```

Add one oversized-frame rejection, one cleanup assertion after `stop()`, and one injected peer-UID mismatch. Do not add load or fuzz testing.

- [ ] **Step 2: Run transport tests and confirm RED**

Run:

```bash
swift test --filter UnixSocketTransportTests
```

Expected: compile failure for missing socket client/server.

- [ ] **Step 3: Implement bounded Darwin socket transport**

Use `AF_UNIX`, `SOCK_STREAM`, `bind`, `listen`, `accept`, `connect`, `poll`, `read`, and `write`. The server must:

- create only the exact validated endpoint from Task 1;
- unlink only an existing socket owned by the same UID;
- validate accepted peers using `getpeereid`;
- read until one newline or 65,536 bytes;
- decode one request and write one response;
- process clients away from the main actor;
- close every descriptor on all paths;
- stop accept work and unlink its exact socket on shutdown.

Expose injectable `currentUID` and `peerUID` closures to make ownership tests deterministic.

- [ ] **Step 4: Add the app server runtime and lifecycle test**

Create:

```swift
@MainActor
final class RecorderControlServerRuntime {
    private let adapter: AppModelControlAdapter
    private let server: RecorderControlSocketServer

    init(model: AppModel, bundleIdentifier: String)
    func start() throws
    func stop()
}
```

The request handler hops to `MainActor` and calls the adapter. `AppRuntime` starts this runtime once and stops it before `model.shutdown()`. In tests, inject a temporary endpoint/server factory and prove a real `status` request reaches the model once.

- [ ] **Step 5: Run focused socket and server tests**

Run:

```bash
swift test --filter UnixSocketTransportTests
swift test --filter RecorderControlServerRuntimeTests
```

Expected: both suites pass; no socket remains after each test.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/RecorderControl/UnixSocketTransport.swift Sources/RecorderApp/Control/RecorderControlServerRuntime.swift Sources/RecorderApp/AppRuntime.swift Tests/RecorderControlTests/UnixSocketTransportTests.swift Tests/RecorderAppTests/RecorderControlServerRuntimeTests.swift
git commit -m "feat: add local recorder control socket"
```

---

### Task 4: CLI Parsing, Background Launch, Status, and Watch

**Files:**
- Create: `Sources/RecorderControlCLI/RecorderCLICommand.swift`
- Create: `Sources/RecorderControlCLI/RecorderCLIApplication.swift`
- Create: `Sources/RecorderControlCLI/RecorderAppLauncher.swift`
- Create: `Sources/RecorderControlCLI/main.swift`
- Modify: `Sources/RecorderApp/LocalMeetingRecorderApp.swift`
- Create: `Tests/RecorderControlCLITests/RecorderCLICommandTests.swift`
- Create: `Tests/RecorderControlCLITests/RecorderCLIApplicationTests.swift`
- Create: `Tests/RecorderAppTests/AppLaunchModeTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: shared client and message types.
- Produces exact commands approved in the design; `--json` is valid only for `status` and `watch`.
- Produces `AppLaunchMode(arguments:)` with `.interactive` and `.backgroundControl`.

- [ ] **Step 1: Write failing parser and orchestration tests**

Table-test these argument arrays:

```swift
["status"]                 -> .status(json: false)
["status", "--json"]      -> .status(json: true)
["watch", "--json"]       -> .watch(json: true)
["start"]                  -> .request(.start, nil)
["stop"]                   -> .request(.stop, nil)
["auto", "on"]            -> .request(.setAuto, "on")
["auto", "off"]           -> .request(.setAuto, "off")
["mic", "mute"]           -> .request(.setMic, "mute")
["mic", "unmute"]         -> .request(.setMic, "unmute")
```

Reject missing/extra/unknown arguments with usage exit code `2`. With fake client/launcher/clock, prove:

- existing socket sends once without launching;
- missing socket launches once, retries until ready, then sends once;
- bounded startup timeout exits `3`;
- rejected app operation exits `4` and prints its stable error;
- `watch --json` emits the first status and only later changed statuses as NDJSON.

- [ ] **Step 2: Run CLI tests and confirm RED**

Run:

```bash
swift test --filter 'RecorderCLI(Command|Application)Tests'
```

Expected: compile failure for missing parser/application types.

- [ ] **Step 3: Implement the CLI without external argument packages**

At this step, add the `recorderctl` executable product, `RecorderControlCLI`
executable target, and `RecorderControlCLITests` test target to `Package.swift`:

```swift
.executable(name: "recorderctl", targets: ["RecorderControlCLI"]),
```

```swift
.executableTarget(
    name: "RecorderControlCLI",
    dependencies: ["RecorderControl"]
),
.testTarget(
    name: "RecorderControlCLITests",
    dependencies: ["RecorderControlCLI", "RecorderControl"]
),
```

Use:

```swift
enum RecorderCLICommand: Equatable {
    case status(json: Bool)
    case watch(json: Bool)
    case request(RecorderControlCommand, String?)
}

struct RecorderCLIApplication {
    func run(arguments: [String]) async -> Int32
}
```

Human status must use a stable labelled list; JSON output must encode the shared response/status directly with sorted keys. `watch` sleeps one second, compares `RecorderControlStatus` values, and emits only changes. Handle SIGINT by ending with exit `0` and no stack trace.

- [ ] **Step 4: Implement containing-app resolution and bounded background launch**

Resolve symlinks from the executable path, require the layout
`<app>/Contents/Helpers/recorderctl`, and launch exactly:

```text
/usr/bin/open -gj <resolved-app-path> --args --background-control
```

Do not use a shell. Retry socket connection for at most five seconds with a
100-millisecond delay. Read `CFBundleIdentifier` from that containing app's
`Info.plist` and use it to select the staging or production endpoint; do not use
the CLI process's `Bundle.main.bundleIdentifier`.

- [ ] **Step 5: Implement tested background-control app launch behavior**

Add:

```swift
enum AppLaunchMode: Equatable {
    case interactive
    case backgroundControl

    init(arguments: [String]) {
        self = arguments.contains("--background-control")
            ? .backgroundControl
            : .interactive
    }
}
```

In background mode, `AppDelegate` uses `.accessory`, never calls
`NSApp.activate`, and orders the SwiftUI window out once it exists. A normal
launch keeps current behavior. `applicationShouldHandleReopen` restores
`.regular`, activates, and shows the existing window.

- [ ] **Step 6: Run CLI and launch-mode tests**

Run:

```bash
swift test --filter RecorderControlCLITests
swift test --filter AppLaunchModeTests
```

Expected: all parsing, orchestration, rendering, timeout, and launch-mode cases pass.

- [ ] **Step 7: Commit Task 4**

```bash
git add Package.swift Sources/RecorderControlCLI Sources/RecorderApp/LocalMeetingRecorderApp.swift Tests/RecorderControlCLITests Tests/RecorderAppTests/AppLaunchModeTests.swift
git commit -m "feat: add recorder control CLI"
```

---

### Task 5: Bundle, Sign, Verify, and Install the CLI Helper

**Files:**
- Modify: `scripts/build-app.sh`
- Modify: `scripts/verify-app-bundle.sh`
- Create: `scripts/install-recorder-cli.sh`
- Modify: `Tests/PackagingTests/run-tests.sh`
- Modify: `Tests/ScriptTests/test_packaging_contract.py`

**Interfaces:**
- Produces: signed executable `Contents/Helpers/recorderctl`.
- Produces: safe symlink `/usr/local/bin/recorderctl` pointing into the selected installed app.

- [ ] **Step 1: Add failing packaging contract tests**

Assert the build script:

- requires the `recorderctl` SwiftPM product;
- creates `Contents/Helpers`;
- copies and release-strips the helper;
- signs the helper before signing the app;
- verifies both arm64 binaries.

Assert `verify-app-bundle.sh` requires an executable helper and checks its
macOS 26.0 load command. Add an install-script contract that refuses to replace
a real file, directory, or symlink not already targeting a Local Meeting
Recorder app helper.

- [ ] **Step 2: Run script tests and confirm RED**

Run:

```bash
python3 -m unittest Tests.ScriptTests.test_packaging_contract
```

Expected: failure because the helper copy/sign/install contracts are absent.

- [ ] **Step 3: Package and sign the helper**

Update `build-app.sh` to locate `$BIN_DIR/recorderctl`, copy it to
`$CONTENTS_DIR/Helpers/recorderctl`, strip it in release, and sign it with the
same mode before the main executable and outer app. Keep the existing owned
bundle replacement rules unchanged.

- [ ] **Step 4: Add a narrow safe CLI installation script**

`install-recorder-cli.sh` accepts one absolute `.app` path, validates its owner
marker and executable helper, then creates `/usr/local/bin/recorderctl`. If the
link exists, replace it only when its resolved target is a Recorder app's
`Contents/Helpers/recorderctl`; otherwise exit `73` without mutation. The script
never recursively removes `/usr/local/bin` or an app bundle.

- [ ] **Step 5: Run script and packaging tests**

Run:

```bash
python3 -m unittest Tests.ScriptTests.test_packaging_contract
bash Tests/PackagingTests/run-tests.sh
```

Expected: all packaging contracts pass; the temporary app contains two valid arm64 macOS 26 binaries.

- [ ] **Step 6: Commit Task 5**

```bash
git add scripts/build-app.sh scripts/verify-app-bundle.sh scripts/install-recorder-cli.sh Tests/PackagingTests/run-tests.sh Tests/ScriptTests/test_packaging_contract.py
git commit -m "build: package recorder control CLI"
```

---

### Task 6: Microphone Device Refresh Button

**Files:**
- Modify: `Sources/RecorderApp/UI/RecorderSettingsView.swift`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`

**Interfaces:**
- Consumes: existing `AppModel.refreshDevices()`.
- Produces Accessibility identifier `recorder.settings.microphone-refresh`.

- [ ] **Step 1: Write the failing render and behavior tests**

Extend the settings host assertions to require a button named
`recorder.settings.microphone-refresh`. While a fake recorder is recording,
assert the picker is disabled but the Refresh button remains enabled. Inject an
`inputDevices` closure whose return value changes, invoke `refreshDevices()`, and
assert the displayed device collection changes without changing the recorder's
continuity snapshot microphone UID.

- [ ] **Step 2: Run the focused UI/model tests and confirm RED**

Run:

```bash
swift test --filter RecorderWorkspaceRenderTests
swift test --filter AppModelScreenCaptureTests
```

Expected: missing accessibility element/contract for the new button.

- [ ] **Step 3: Add the narrow Refresh button**

Add beside the picker:

```swift
Button { model.refreshDevices() } label: {
    Image(systemName: "arrow.clockwise")
}
.buttonStyle(.bordered)
.help("Refresh microphones")
.accessibilityLabel("Refresh microphones")
.accessibilityIdentifier("recorder.settings.microphone-refresh")
```

Do not disable this button from `sourceControlsEnabled`; retain the existing
picker disable rule. Do not call `selectMicrophone` from Refresh.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the two commands from Step 2. Expected: both suites pass.

- [ ] **Step 5: Commit Task 6**

```bash
git add Sources/RecorderApp/UI/RecorderSettingsView.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift Tests/RecorderAppTests/AppModelScreenCaptureTests.swift
git commit -m "feat: refresh microphone devices from settings"
```

---

### Task 7: Optional Teams Accessibility Mute Sync and Floating Status

**Files:**
- Modify: `Package.swift`
- Create: `Sources/RecorderApp/Teams/TeamsMuteAccessibilityAdapter.swift`
- Create: `Sources/RecorderApp/Teams/TeamsMuteSyncCoordinator.swift`
- Modify: `Sources/RecorderApp/Teams/MicrophoneMuteCoordinator.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Modify: `Sources/RecorderApp/Views/RecordingControllerPresentation.swift`
- Create: `Tests/RecorderAppTests/TeamsMuteAccessibilityClassifierTests.swift`
- Create: `Tests/RecorderAppTests/TeamsMuteSyncCoordinatorTests.swift`
- Modify: `Tests/RecorderAppTests/MicrophoneMuteCoordinatorTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingControllerPanelTests.swift`

**Interfaces:**
- Produces: `TeamsMicMuteState` with `.muted`, `.unmuted`, and `.unknown(TeamsMuteUnknownReason)`.
- Produces: async `TeamsMuteControlling.readState(processID:)`, `setMuted(_:processID:)`, and synchronous permission request.
- Produces: AppModel `teamsMicMuteState`, `requestTeamsAccessibilityPermission()`, and `toggleTeamsAndRecorderMicMute()`.

- [ ] **Step 1: Write failing three-source microphone-gate tests**

Extend the existing coordinator with these exact state transitions:

```swift
gate.setLocalMuted(true)
gate.setTeamsMuted(false)
XCTAssertTrue(gate.snapshot.effectiveMuted)

gate.setLocalMuted(false)
gate.setNativeInputMuted(true)
gate.setTeamsMuted(false)
XCTAssertTrue(gate.snapshot.effectiveMuted)

gate.setNativeInputMuted(false)
gate.setTeamsMuted(true)
XCTAssertTrue(gate.snapshot.effectiveMuted)
```

Also prove clearing Teams mute after a known `.unmuted` observation never
clears a simultaneous local or native mute. Unknown is not passed to the gate;
the sync-coordinator tests below prove it preserves the last safe gate value.

- [ ] **Step 2: Run gate tests and confirm RED**

Run:

```bash
swift test --filter LocalMicrophoneMuteCoordinatorTests
```

Expected: compile failure for `setTeamsMuted` and missing Teams snapshot state.

- [ ] **Step 3: Add the optional Teams source to the existing gate**

Add `teamsMuted: Bool` to `MicrophoneMuteCoordinator` and
`MicrophoneMuteSnapshot`, with:

```swift
var effectiveMuted: Bool {
    localMuted || nativeInputMuted || teamsMuted
}
```

Implement `setTeamsMuted(_ muted: Bool)` through the existing serialized gate
transition machinery. The sync coordinator calls it only for known `.muted` or
`.unmuted` observations. An `unknown` observation leaves the previous gate
value unchanged; an explicit meeting-end/reset path clears the Teams source.

- [ ] **Step 4: Write failing pure Accessibility classifier tests**

Define descriptor fixtures containing role, identifier, title, description,
help, value, enabled, and visible. Test only:

- English `Mute` action means current Teams state is unmuted.
- English `Unmute` action means current Teams state is muted.
- `靜音`/`静音` mean unmuted; `取消靜音`/`取消静音` mean muted.
- hidden/disabled controls are ignored.
- two equally valid controls produce `unknown(.ambiguousControls)`.
- no supported semantic evidence produces `unknown(.controlNotFound)`.

- [ ] **Step 5: Run classifier tests and confirm RED**

Run:

```bash
swift test --filter TeamsMuteAccessibilityClassifierTests
```

Expected: compile failure for missing descriptor/classifier/state types.

- [ ] **Step 6: Implement the bounded Accessibility adapter**

Link `ApplicationServices`. Implement:

```swift
enum TeamsMicMuteState: Equatable, Sendable {
    case muted
    case unmuted
    case unknown(TeamsMuteUnknownReason)
}

protocol TeamsMuteControlling: Sendable {
    func readState(processID: pid_t) async -> TeamsMicMuteState
    func setMuted(_ muted: Bool, processID: pid_t) async -> TeamsMicMuteState
    @MainActor func requestPermission()
}
```

Use `AXIsProcessTrusted` for passive reads and
`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` only from
the explicit permission action. Traverse at most 1,500 elements and depth 12,
avoid revisiting elements, require button role plus supported semantic evidence,
and return ambiguity instead of selecting arbitrarily. `setMuted` performs
`kAXPressAction` only when the known current state differs, then re-reads for up
to two seconds; lack of confirmation returns `unknown(.confirmationFailed)`.

- [ ] **Step 7: Write failing sync-order and floating-presentation tests**

With a fake adapter and manual ticker, prove:

- mute applies Recorder local mute before the fake Teams action;
- Teams mute failure leaves Recorder muted;
- unmute calls Teams first and clears local mute only after `.unmuted` confirmation;
- unmute unknown/failure leaves local mute set;
- observed Teams mute updates the Teams gate source;
- observed Teams unmute cannot clear local/native mute;
- an unknown observation after known Teams mute leaves effective mute true;
- no Accessibility permission renders `Teams status unknown` and an Enable Accessibility action;
- muted, live, unknown, and mismatch states remain distinct in the floating panel.

- [ ] **Step 8: Run sync/presentation tests and confirm RED**

Run:

```bash
swift test --filter TeamsMuteSyncCoordinatorTests
swift test --filter RecordingControllerPanelTests
```

Expected: failures for missing sync coordinator, AppModel state, and panel presentation.

- [ ] **Step 9: Integrate one-second polling and fail-safe actions**

`TeamsMuteSyncCoordinator` owns one cancellable task and polls only while the
floating recorder panel is active, a Teams process is selected, and recording
is active. AppModel publishes the latest state, feeds known values to
`microphoneMuteGate.setTeamsMuted`, and resets to `unknown(.inactive)` when the
conditions end.

Replace the floating mic action with an async AppModel action:

```swift
func toggleTeamsAndRecorderMicMute() {
    let wantsMute = !microphoneMuteGate.snapshot.localMuted
    Task { @MainActor [weak self] in
        await self?.setTeamsAndRecorderMicMuted(wantsMute)
    }
}
```

For mute, set local first and then call Teams. For unmute, call Teams first and
clear local only after `.unmuted`. When no Teams app is selected, keep the
existing local-only behavior. Add a compact Teams state label and an Enable
Accessibility button for the permission-required unknown reason; never prompt
at startup.

- [ ] **Step 10: Run all focused mute and panel tests**

Run:

```bash
swift test --filter LocalMicrophoneMuteCoordinatorTests
swift test --filter AppModelMuteTests
swift test --filter TeamsMuteAccessibilityClassifierTests
swift test --filter TeamsMuteSyncCoordinatorTests
swift test --filter RecordingControllerPanelTests
```

Expected: all selected suites pass.

- [ ] **Step 11: Commit Task 7**

```bash
git add Package.swift Sources/RecorderApp/Teams Sources/RecorderApp/AppModel.swift Sources/RecorderApp/Views/RecordingControllerPanel.swift Sources/RecorderApp/Views/RecordingControllerPresentation.swift Tests/RecorderAppTests/TeamsMuteAccessibilityClassifierTests.swift Tests/RecorderAppTests/TeamsMuteSyncCoordinatorTests.swift Tests/RecorderAppTests/MicrophoneMuteCoordinatorTests.swift Tests/RecorderAppTests/RecordingControllerPanelTests.swift Tests/RecorderAppTests/AppModelMuteTests.swift
git commit -m "feat: show and control Teams mute status"
```

---

### Task 8: Integrated Verification, Installed Build, and Focused UAT

**Files:**
- Modify only if a verified defect requires it: files owned by Tasks 1-7 and their focused tests.
- Create: `docs/testing/2026-08-05-recorder-cli-and-teams-mute-uat.md`

**Interfaces:**
- Final installed staging version: `0.2.0 (336)` unless a newer build number is already present when execution reaches this task; never reuse an installed build number.

- [ ] **Step 1: Run all Swift and script tests**

Run:

```bash
swift test
python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
bash Tests/PackagingTests/run-tests.sh
```

Expected: all tests pass; only intentionally documented skips remain.

- [ ] **Step 2: Build and verify the release staging bundle**

Run with the next unused build number:

```bash
scripts/build-app.sh --configuration release --version 0.2.0 --build-number 336 --bundle-id local.meeting.recorder.staging --bundle-name 'Local Meeting Recorder Staging' --sign ad-hoc
scripts/verify-app-bundle.sh 'build/Local Meeting Recorder Staging.app'
codesign --verify --deep --strict 'build/Local Meeting Recorder Staging.app'
```

Expected: app and embedded CLI are arm64, macOS 26.0, signed, and verified.

- [ ] **Step 3: Install the exact app and CLI link**

Quit only the staging app, replace exactly
`/Applications/Local Meeting Recorder Staging.app` with the verified bundle,
run `scripts/install-recorder-cli.sh` against it, and remove only the duplicate
owned staging bundle from `build/`. Verify:

```bash
/usr/local/bin/recorderctl status --json
readlink /usr/local/bin/recorderctl
```

Expected: the link resolves into the installed staging app and status is valid JSON.

- [ ] **Step 4: Perform CLI/background acceptance without GUI control**

Verify:

1. Quit staging, focus another app, run `recorderctl status`, and confirm Recorder starts without focus or a visible main window.
2. Run `watch --json`; exercise `auto on`, `auto off`, `mic mute`, `mic unmute`, `start`, and `stop`; confirm changed snapshots and idempotent repeats.
3. Confirm `stop` finalizes a nonempty recording folder.
4. Start through Auto Mode in a Teams meeting, issue CLI `stop`, keep the meeting active, and confirm no second countdown appears.

- [ ] **Step 5: Perform one bounded GUI/Teams mute acceptance**

Use one live Teams meeting only:

1. Confirm microphone Refresh shows a newly connected/disconnected device and remains enabled during recording while the picker stays disabled.
2. Before Accessibility permission, confirm `Teams status unknown` and no startup prompt.
3. Use the explicit Enable Accessibility action and grant the staging app.
4. Confirm Teams muted/live states when exposed by the current Teams UI.
5. Confirm floating mute is local-first and floating unmute is Teams-confirmed-first.
6. Press AirPods mute/unmute and confirm the Teams badge updates on the next poll when Teams exposes the state.
7. If the current Teams build does not expose a unique mute control, record `unknown` as the correct best-effort outcome; do not weaken ambiguity handling to force a green result.

- [ ] **Step 6: Write the concise UAT record**

Document commands, installed version/build, permission state, results for each
acceptance item, any Teams `unknown` reason, test totals, and recording folder
paths. Do not add screenshots or exhaustive permutations unless they expose a
real defect.

- [ ] **Step 7: Final diff and repository review**

Run:

```bash
git diff --check
git status --short
git log --oneline -10
```

Expected: no unstaged tracked changes; preserve the existing unrelated
`.superpowers/`, tutorial, and `docs/assets/` untracked files.

- [ ] **Step 8: Commit the UAT record if it is not already included**

```bash
git add docs/testing/2026-08-05-recorder-cli-and-teams-mute-uat.md
git commit -m "docs: record CLI and Teams mute acceptance"
```

---

## Completion Conditions

Work is complete only when:

- the installed staging app is the verified new build;
- `/usr/local/bin/recorderctl` controls that exact bundle;
- all eight approved commands and `--json`/watch behavior pass acceptance;
- background launch is visually non-disruptive;
- user stop suppresses the same Teams meeting;
- microphone Refresh behaves correctly during recording;
- floating Recorder/Teams mute states are distinct;
- Accessibility failure stays `unknown` and cannot accidentally unmute;
- all focused and full tests pass without adding exhaustive or duplicative test matrices;
- unrelated user files remain untouched.
