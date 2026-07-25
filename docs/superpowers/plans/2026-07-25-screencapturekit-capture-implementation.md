# ScreenCaptureKit Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the BlackHole runtime capture path with native all-system or single-application audio capture plus microphone capture, while preserving one mixed `recording.m4a` and all existing recorder features.

**Architecture:** `SCShareableContent` resolves displays and running applications into a `CaptureSelection`. One audio-only `SCStream` emits system/application and microphone `CMSampleBuffer` values. A timestamp-aware 48 kHz Float32 mixer aligns both sources, inserts silence for gaps, and feeds the existing AAC writer, meters, and health report.

**Tech Stack:** Swift 5.9, SwiftUI, ScreenCaptureKit, AVFoundation, CoreMedia, CoreAudio, XCTest, macOS 15+

## Global Constraints

- Do not change the current macOS output device.
- Support `All System Audio` and one `Selected App`; default to all-system capture.
- Exclude Local Meeting Recorder audio from all-system capture.
- Do not register a ScreenCaptureKit `.screen` output.
- Capture and normalize system/application and microphone audio to 48 kHz stereo Float32.
- Write one 48 kHz stereo 192 kbps AAC `recording.m4a`.
- When a selected app exits, continue recording microphone audio and insert system-track silence until explicit reconnect.
- Preserve waveform, playback, library, health, manual upload, and transcription behavior.
- Remove BlackHole, Multi-Output Device, Routing Assistant, and Audio MIDI Setup from runtime UI and capture logic.
- Keep unrelated `ReleaseManifest.swift` and `ReleaseManifestTests.swift` changes out of every commit.
- Use test-driven development and commit each independently reviewable task.

---

## File Structure

### New files

- `Sources/RecorderApp/Capture/CaptureModels.swift`: capture modes, application identity, persisted selection, resolved selection, and permission state.
- `Sources/RecorderApp/Capture/CaptureSelectionResolver.swift`: pure source-resolution and disconnect/reconnect policy.
- `Sources/RecorderApp/Capture/ScreenCaptureSource.swift`: `SCShareableContent`, filters, `SCStream`, and sample output callbacks.
- `Sources/RecorderApp/Audio/AudioFrameBlock.swift`: normalized timestamped PCM value types.
- `Sources/RecorderApp/Audio/TimestampedAudioMixer.swift`: deterministic timeline alignment, silence insertion, gains, mute, and limiting.
- `Sources/RecorderApp/Audio/SampleBufferConverter.swift`: `CMSampleBuffer` to normalized PCM conversion.
- `Sources/RecorderApp/Capture/CapturePermission.swift`: permission state and System Settings routing.
- `Tests/RecorderAppTests/CaptureSelectionResolverTests.swift`: all-system/single-app/disconnect policy.
- `Tests/RecorderAppTests/TimestampedAudioMixerTests.swift`: alignment, gaps, mute, clipping, and duration.
- `Tests/RecorderAppTests/CaptureStatusTests.swift`: health/status mapping.

### Modified files

- `Sources/RecorderApp/AudioDevice.swift`: expose stable Core Audio device UID.
- `Sources/RecorderApp/RecordingEngine.swift`: orchestrate `ScreenCaptureSource`, converter, mixer, file writer, meters, and stop lifecycle.
- `Sources/RecorderApp/RecordingModels.swift`: capture errors and extended health counters.
- `Sources/RecorderApp/AppModel.swift`: capture selection, application refresh/reconnect, permissions, and async start/stop.
- `Sources/RecorderApp/ContentView.swift`: source controls and permission/connection UI; remove BlackHole routing UI.
- `Sources/RecorderApp/RecordingLibrary.swift`: update live audio health wording for app/system capture.
- `Package.swift`: link ScreenCaptureKit and CoreMedia.
- `scripts/build-app.sh`: add Screen/System Audio usage description and stable bundle metadata.

---

### Task 1: Capture Selection Domain

**Files:**
- Create: `Sources/RecorderApp/Capture/CaptureModels.swift`
- Create: `Sources/RecorderApp/Capture/CaptureSelectionResolver.swift`
- Test: `Tests/RecorderAppTests/CaptureSelectionResolverTests.swift`

**Interfaces:**
- Produces: `CaptureMode`, `CaptureApplication`, `CaptureSelection`, `ResolvedCaptureSelection`, and `CaptureSelectionResolver.resolve(selection:availableApplications:)`.
- Consumes: no runtime frameworks beyond Foundation.

- [ ] **Step 1: Write the failing selection tests**

```swift
import XCTest
@testable import RecorderApp

final class CaptureSelectionResolverTests: XCTestCase {
    func testAllSystemAudioDoesNotRequireAnApplication() {
        let result = CaptureSelectionResolver.resolve(
            selection: .init(mode: .allSystemAudio),
            availableApplications: []
        )
        XCTAssertEqual(result, .allSystemAudio)
    }

    func testSelectedAppResolvesExactBundleIdentifier() {
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let result = CaptureSelectionResolver.resolve(
            selection: .init(mode: .selectedApplication,
                             selectedBundleIdentifier: teams.bundleIdentifier),
            availableApplications: [teams]
        )
        XCTAssertEqual(result, .application(teams))
    }

    func testSelectedAppBecomesDisconnectedInsteadOfFallingBackToAllAudio() {
        let result = CaptureSelectionResolver.resolve(
            selection: .init(mode: .selectedApplication,
                             selectedBundleIdentifier: "com.microsoft.teams2"),
            availableApplications: []
        )
        XCTAssertEqual(result, .disconnected("com.microsoft.teams2"))
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter CaptureSelectionResolverTests
```

Expected: compilation fails because `CaptureSelectionResolver` and capture domain types do not exist.

- [ ] **Step 3: Add the minimal domain implementation**

```swift
import Foundation

enum CaptureMode: String, Codable, CaseIterable {
    case allSystemAudio
    case selectedApplication
}

struct CaptureApplication: Identifiable, Codable, Hashable {
    let processID: pid_t
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

struct CaptureSelection: Codable, Equatable {
    var mode: CaptureMode
    var selectedBundleIdentifier: String?
}

enum ResolvedCaptureSelection: Equatable {
    case allSystemAudio
    case application(CaptureApplication)
    case disconnected(String)
}

enum CaptureSelectionResolver {
    static func resolve(
        selection: CaptureSelection,
        availableApplications: [CaptureApplication]
    ) -> ResolvedCaptureSelection {
        guard selection.mode == .selectedApplication else {
            return .allSystemAudio
        }
        let bundleID = selection.selectedBundleIdentifier ?? ""
        guard let app = availableApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            return .disconnected(bundleID)
        }
        return .application(app)
    }
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run the Task 1 test command. Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderApp/Capture/CaptureModels.swift \
  Sources/RecorderApp/Capture/CaptureSelectionResolver.swift \
  Tests/RecorderAppTests/CaptureSelectionResolverTests.swift
git commit -m "Add native capture selection model"
```

---

### Task 2: Timestamped PCM Mixer

**Files:**
- Create: `Sources/RecorderApp/Audio/AudioFrameBlock.swift`
- Create: `Sources/RecorderApp/Audio/TimestampedAudioMixer.swift`
- Test: `Tests/RecorderAppTests/TimestampedAudioMixerTests.swift`

**Interfaces:**
- Produces: `AudioSourceKind`, `AudioFrameBlock`, `MixedAudioBlock`, and `TimestampedAudioMixer.push(_:)`.
- Consumes: normalized 48 kHz stereo Float32 samples; no ScreenCaptureKit types.

- [ ] **Step 1: Write failing tests for alignment, silence, and mute**

```swift
import XCTest
@testable import RecorderApp

final class TimestampedAudioMixerTests: XCTestCase {
    func testAlignsSourcesByAbsoluteStartFrame() {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        _ = mixer.push(.stereo(source: .system, startFrame: 0,
                               left: [1, 1, 1, 1], right: [1, 1, 1, 1]))
        let output = mixer.push(.stereo(source: .microphone, startFrame: 2,
                                        left: [1, 1, 1, 1], right: [1, 1, 1, 1]))

        XCTAssertEqual(output.first?.startFrame, 0)
        XCTAssertEqual(output.first?.left.count, 4)
        XCTAssertEqual(output.first?.left[0], 0.48, accuracy: 0.001)
        XCTAssertGreaterThan(output.first?.left[2] ?? 0, 0.48)
    }

    func testMissingSourceProducesSilenceWithoutBlockingTimeline() {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        let output = mixer.flushThrough(frame: 4)
        XCTAssertEqual(output, [.silence(startFrame: 0, frameCount: 4)])
    }

    func testMutedMicrophoneDoesNotEnterMix() {
        var mixer = TimestampedAudioMixer(sampleRate: 48_000, blockFrames: 4)
        mixer.isMicrophoneMuted = true
        _ = mixer.push(.stereo(source: .system, startFrame: 0,
                               left: [0.5, 0.5, 0.5, 0.5],
                               right: [0.5, 0.5, 0.5, 0.5]))
        let output = mixer.push(.stereo(source: .microphone, startFrame: 0,
                                        left: [1, 1, 1, 1], right: [1, 1, 1, 1]))
        XCTAssertEqual(output.first?.left[0], 0.24, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter TimestampedAudioMixerTests
```

Expected: compilation fails because mixer types do not exist.

- [ ] **Step 3: Implement normalized frame blocks and deterministic timeline**

Use absolute frame numbers (`presentationTime.seconds * 48_000`) rather than
callback arrival order. Store pending samples in source-specific ranges, emit
fixed-size blocks when both ranges are known or `flushThrough(frame:)` advances
the timeline, treat absent samples as zero, apply 0.48 gain per source, then:

```swift
let normalized = tanh(sample * 1.15) / tanh(1.15)
```

`push(_:)` must return zero or more complete `MixedAudioBlock` values and remove
all consumed source samples.

- [ ] **Step 4: Add boundary tests**

Add tests for:

```swift
func testLateBlockCannotRewriteAlreadyEmittedFrames()
func testOverlappingBlocksReplaceOnlySameSourcePendingFrames()
func testSoftLimiterKeepsSamplesWithinUnitRange()
func testFlushAdvancesAcrossMultipleBlocks()
```

Expected assertions: emitted frame numbers are monotonic, output values remain
within `-1...1`, and late data increments `lateFrameCount`.

- [ ] **Step 5: Run mixer tests and full tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter TimestampedAudioMixerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: mixer suite and all existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/RecorderApp/Audio/AudioFrameBlock.swift \
  Sources/RecorderApp/Audio/TimestampedAudioMixer.swift \
  Tests/RecorderAppTests/TimestampedAudioMixerTests.swift
git commit -m "Add timestamp-aligned audio mixer"
```

---

### Task 3: ScreenCaptureKit Source Adapter

**Files:**
- Create: `Sources/RecorderApp/Capture/ScreenCaptureSource.swift`
- Create: `Sources/RecorderApp/Audio/SampleBufferConverter.swift`
- Modify: `Sources/RecorderApp/AudioDevice.swift`
- Modify: `Package.swift`
- Test: `Tests/RecorderAppTests/CaptureStatusTests.swift`

**Interfaces:**
- Consumes: `ResolvedCaptureSelection`, microphone Core Audio UID.
- Produces: `ScreenCaptureSource.refreshContent() async throws`,
  `start(selection:microphoneUID:onAudio:onEvent:) async throws`, `stop() async`,
  and normalized `AudioFrameBlock` callbacks.

- [ ] **Step 1: Write failing status and UID tests**

```swift
func testDisconnectedCaptureMapsToWarning() {
    XCTAssertEqual(
        CaptureStatusMapper.status(for: .applicationDisconnected("Teams")),
        .warning("App audio disconnected")
    )
}

func testAudioDeviceCarriesStableUID() {
    let device = AudioDevice(id: 1, uid: "BuiltInMicrophoneDevice",
                             name: "MacBook Microphone",
                             manufacturer: "Apple", channelCount: 1)
    XCTAssertEqual(device.uid, "BuiltInMicrophoneDevice")
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter CaptureStatusTests
```

Expected: compile failure for missing capture status types and `AudioDevice.uid`.

- [ ] **Step 3: Add ScreenCaptureKit and CoreMedia linkage**

```swift
.linkedFramework("ScreenCaptureKit"),
.linkedFramework("CoreMedia"),
```

Add `import ScreenCaptureKit` and implement:

```swift
let content = try await SCShareableContent.excludingDesktopWindows(
    false,
    onScreenWindowsOnly: false
)
```

Map `SCRunningApplication` values with non-empty bundle identifiers into sorted
`CaptureApplication` values. Resolve the main display, then build:

```swift
SCContentFilter(display: display,
                excludingApplications: [recorderApplication],
                exceptingWindows: [])
```

or:

```swift
SCContentFilter(display: display,
                includingApplications: [selectedApplication],
                exceptingWindows: [])
```

- [ ] **Step 4: Configure and start an audio-only stream**

```swift
let configuration = SCStreamConfiguration()
configuration.capturesAudio = true
configuration.captureMicrophone = true
configuration.sampleRate = 48_000
configuration.channelCount = 2
configuration.excludesCurrentProcessAudio = true
configuration.microphoneCaptureDeviceID = microphoneUID

let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
try stream.addStreamOutput(output, type: .audio,
                           sampleHandlerQueue: systemAudioQueue)
try stream.addStreamOutput(output, type: .microphone,
                           sampleHandlerQueue: microphoneQueue)
try await stream.startCapture()
```

Do not add `.screen`. Copy data out of the callback-owned
`CMSampleBuffer` immediately. Convert its audio buffer list to a normalized
48 kHz stereo `AudioFrameBlock`, preserving presentation timestamp as
`startFrame`.

- [ ] **Step 5: Implement lifecycle events**

Map stream stop errors, invalid sample buffers, conversion errors, selected-app
disappearance, and microphone silence/disconnect into `CaptureEvent`. `stop()`
must remove both outputs and call `stopCapture()` exactly once.

- [ ] **Step 6: Run tests and compile**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter CaptureStatusTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: tests pass and app target links ScreenCaptureKit.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/RecorderApp/AudioDevice.swift \
  Sources/RecorderApp/Capture/ScreenCaptureSource.swift \
  Sources/RecorderApp/Audio/SampleBufferConverter.swift \
  Tests/RecorderAppTests/CaptureStatusTests.swift
git commit -m "Add ScreenCaptureKit audio source"
```

---

### Task 4: Recording Engine Integration

**Files:**
- Modify: `Sources/RecorderApp/RecordingEngine.swift`
- Modify: `Sources/RecorderApp/RecordingModels.swift`
- Modify: `Sources/RecorderApp/RecordingLibrary.swift`
- Test: `Tests/RecorderAppTests/RecordingEngineStateTests.swift`

**Interfaces:**
- Consumes: `ScreenCaptureSource`, `TimestampedAudioMixer`, `CaptureSelection`,
  selected microphone UID.
- Produces: async `startMonitoring(selection:microphoneUID:)`,
  `start(selection:microphoneUID:baseFolder:folderPrefix:)`, `stop()`, source
  connection state, levels, and expanded `RecordingHealthReport`.

- [ ] **Step 1: Write failing engine-state tests against injected fakes**

Define protocols `CaptureSourceProtocol` and `MixedAudioWriting` so tests can
inject deterministic sources and writers. Verify:

```swift
func testStartDoesNotRequireBlackHoleDevice()
func testSelectedAppDisconnectKeepsRecordingActive()
func testMicrophoneDisconnectKeepsSystemRecordingActive()
func testStopFlushesMixerAndClosesWriter()
func testCaptureFailureAppearsInHealthReport()
```

- [ ] **Step 2: Run tests and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter RecordingEngineStateTests
```

Expected: compile failure because the injected engine interfaces do not exist.

- [ ] **Step 3: Replace dual `AVAudioEngine` capture**

Remove `systemEngine`, `micEngine`, Core Audio input-node binding, pending
arrival-order buffers, and `writeMixedFramesIfReady()`. Retain file settings,
meter smoothing, health summary, and mute state. Feed normalized blocks into
`TimestampedAudioMixer`, write every returned mixed block through an
`AVAudioFile` adapter, and update each source level before mixing.

- [ ] **Step 4: Make lifecycle async and idempotent**

`startMonitoring` and `start` await the source. `stop` first stops the stream,
flushes the mixer through the latest observed frame, closes the file, and
returns one `RecordingResult`. Repeated stop calls return `nil`.

- [ ] **Step 5: Expand health**

Add:

```swift
var conversionFailures = 0
var lateFrames = 0
var systemDisconnects = 0
var microphoneDisconnects = 0
var streamFailures = 0
```

Include non-zero values in `summary`, and update `AudioHealthAdvisor` wording
from device/BlackHole language to system/application capture language.

- [ ] **Step 6: Run targeted and full tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter RecordingEngineStateTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderApp/RecordingEngine.swift \
  Sources/RecorderApp/RecordingModels.swift \
  Sources/RecorderApp/RecordingLibrary.swift \
  Tests/RecorderAppTests/RecordingEngineStateTests.swift
git commit -m "Use native capture in recording engine"
```

---

### Task 5: App Model, Permissions, and SwiftUI

**Files:**
- Create: `Sources/RecorderApp/Capture/CapturePermission.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Modify: `scripts/build-app.sh`
- Test: `Tests/RecorderAppTests/CaptureStatusTests.swift`

**Interfaces:**
- Consumes: async engine API, source applications, permission and connection
  state.
- Produces: persisted capture selection, refresh/reconnect actions, segmented
  mode control, application picker, microphone picker, and status rows.

- [ ] **Step 1: Add failing permission and UI-state mapping tests**

```swift
func testDeniedSystemAudioPermissionBlocksStart() {
    let state = CaptureReadiness.evaluate(
        permission: .denied,
        selection: .init(mode: .allSystemAudio),
        resolvedSelection: .allSystemAudio,
        microphoneAvailable: true
    )
    XCTAssertEqual(state, .blocked("Screen & System Audio Recording permission is required."))
}

func testDisconnectedSelectedAppShowsReconnectWithoutChangingMode() {
    let state = CaptureReadiness.evaluate(
        permission: .granted,
        selection: .init(mode: .selectedApplication,
                         selectedBundleIdentifier: "com.microsoft.teams2"),
        resolvedSelection: .disconnected("com.microsoft.teams2"),
        microphoneAvailable: true
    )
    XCTAssertEqual(state, .reconnectRequired)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run the CaptureStatus test filter. Expected: missing `CaptureReadiness`.

- [ ] **Step 3: Add model state and persistence**

Use `UserDefaults` keys:

```swift
"capture.mode"
"capture.selectedBundleIdentifier"
"capture.microphoneUID"
```

Publish `availableCaptureApplications`, `captureSelection`,
`captureConnectionState`, `systemAudioPermission`, and selected microphone.
Replace synchronous BlackHole refresh/start calls with `Task`-backed async
source refresh and engine lifecycle. Disable source changes while recording.

- [ ] **Step 4: Replace runtime UI**

Remove `RoutingAssistantView`, `openAudioMIDISetup`, system input-device picker,
and BlackHole/Multi-Output copy. Add:

```swift
Picker("Capture", selection: $model.captureSelection.mode) {
    Text("All System Audio").tag(CaptureMode.allSystemAudio)
    Text("Selected App").tag(CaptureMode.selectedApplication)
}
.pickerStyle(.segmented)
```

Show a searchable single-app menu only in Selected App mode, plus refresh and
Reconnect buttons. Keep the microphone picker. Update meter subtitle with the
mode or selected app name.

- [ ] **Step 5: Add permission UI and package metadata**

Add a `Screen & System Audio Recording` status row with an icon, exact action,
and restart message. Add to `Info.plist` generation:

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>Local Meeting Recorder captures system or selected app audio without changing your Mac output.</string>
```

- [ ] **Step 6: Run full tests and inspect BlackHole references**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
rg -n 'BlackHole|Multi-Output|Audio MIDI' \
  Sources/RecorderApp/AppModel.swift \
  Sources/RecorderApp/ContentView.swift \
  Sources/RecorderApp/RecordingEngine.swift \
  Sources/RecorderApp/RecordingModels.swift
```

Expected: all tests pass; `rg` returns no runtime references.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderApp/Capture/CapturePermission.swift \
  Sources/RecorderApp/AppModel.swift Sources/RecorderApp/ContentView.swift \
  scripts/build-app.sh Tests/RecorderAppTests/CaptureStatusTests.swift
git commit -m "Add native audio capture controls"
```

---

### Task 6: Phase 1 Build and Live Acceptance

**Files:**
- Modify only if a test exposes a defect in Phase 1 files.
- Create: `docs/testing/2026-07-25-screencapturekit-acceptance.md`

**Interfaces:**
- Consumes: complete Phase 1 app.
- Produces: installed app plus recorded evidence for all-system, selected-app,
  disconnect, source isolation, and 30-minute quality checks.

- [ ] **Step 1: Run clean verification**

```bash
git diff --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: zero failures and no whitespace errors.

- [ ] **Step 2: Install the app**

```bash
scripts/install-app.sh
open -a "/Applications/Local Meeting Recorder.app"
```

Expected: `/Applications/Local Meeting Recorder.app` launches with native
capture controls and no BlackHole routing UI.

- [ ] **Step 3: Grant and verify permission**

Grant Screen & System Audio Recording and microphone permission in System
Settings. Restart the app if macOS requests it. Confirm the UI reports both
permissions ready.

- [ ] **Step 4: Test All System Audio**

Keep macOS output on current speakers/AirPods, play a known spoken clip, record
10 seconds, and play the resulting `recording.m4a`. Confirm system audio and mic
are present and output device never changed.

- [ ] **Step 5: Test Selected App isolation and disconnect**

Play different known clips in two applications. Select one app and record.
Confirm only the selected clip is present. Quit the selected app during a second
recording; confirm recording continues with mic and UI reports
`App audio disconnected`.

- [ ] **Step 6: Run 30-minute quality test**

Record continuous system tone/spoken audio plus intermittent microphone speech.
Inspect playback for periodic ticks and compare file duration with wall time.
Acceptance: no audible periodic tick, no unexplained stop, and duration differs
from wall time by less than 250 ms.

- [ ] **Step 7: Document evidence and commit milestone**

Record date, selected sources, output paths, durations, observed health
counters, and pass/fail for each check in the acceptance document.

```bash
git add docs/testing/2026-07-25-screencapturekit-acceptance.md
git commit -m "Validate native audio capture"
```
