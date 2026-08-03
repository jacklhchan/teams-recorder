# Floating Dual-Input Waveforms Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real System / Teams and Microphone waveforms to the existing floating recording controller.

**Architecture:** Keep the shared `RecordingEngine` as the sole level-data owner. Project its existing published levels and connection/mute flags directly into two compact SwiftUI rows inside `RecordingControllerPanelContent`; no new capture or timing layer is allowed.

**Tech Stack:** Swift 5, SwiftUI, AppKit `NSPanel`, XCTest.

## Global Constraints

- Panel size is exactly 390 by 180 points.
- Visible source labels are exactly `System / Teams` and `Microphone`.
- Visible statuses are exactly `Signal`, `Quiet`, `Muted`, and `Disconnected`.
- Status precedence is Disconnected, then Muted for microphone, then Quiet, then Signal.
- Reuse `RecordingEngine.systemLevel`, `micLevel`, `micMuted`, `isSystemCaptureConnected`, and `isMicrophoneCaptureConnected`.
- Reuse `WaveformView`; do not change `RecordingEngine` or add timers, audio taps, buffers, or fake waveform samples.
- Preserve all existing recording, Stop, timer, finalizing, Teams screen status, and toggle behavior.
- Verification is limited to the two focused panel test classes, `scripts/build-app.sh`, and `git diff --check`; do not run the full legacy suite.

---

### Task 1: Render both real recorder input waveforms

**Files:**
- Modify: `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- Test: `Tests/RecorderAppTests/RecordingControllerPanelTests.swift`
- Test: `Tests/RecorderAppTests/RecordingControllerRenderTests.swift`

**Interfaces:**
- Consumes: the existing `LevelSnapshot` and `WaveformView`, plus the five existing published properties on `RecordingEngine` named in Global Constraints.
- Produces: `RecordingControllerInputStatus.make(level:isConnected:isMuted:)`, accessibility IDs `recording-controller-system-waveform` and `recording-controller-microphone-waveform`, and a 390-by-180 `RecordingControllerPanelContent`.

- [ ] **Step 1: Write focused failing status tests**

Add one test method to `RecordingControllerPanelTests` that asserts these exact mappings:

```swift
XCTAssertEqual(RecordingControllerInputStatus.make(level: .init(rms: -12, peak: -3, samples: [0.7]), isConnected: true, isMuted: false), .signal)
XCTAssertEqual(RecordingControllerInputStatus.make(level: .init(), isConnected: true, isMuted: false), .quiet)
XCTAssertEqual(RecordingControllerInputStatus.make(level: .init(rms: -12, peak: -3, samples: [0.7]), isConnected: true, isMuted: true), .muted)
XCTAssertEqual(RecordingControllerInputStatus.make(level: .init(rms: -12, peak: -3, samples: [0.7]), isConnected: false, isMuted: false), .disconnected)
```

- [ ] **Step 2: Write the failing render test**

Update `RecordingControllerRenderTests` to construct `RecordingControllerPanelContent` with non-empty system and microphone levels, connected flags, and `micMuted: false`. Assert the host is exactly 390 by 180, both new waveform identifiers are present and inside bounds, and all pre-existing accessibility identifiers remain inside bounds.

- [ ] **Step 3: Run RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecordingControllerPanelTests|RecordingControllerRenderTests'
```

Expected: compilation or assertion failure because the input-status projection, waveform parameters, IDs, and 390-by-180 layout do not exist yet.

- [ ] **Step 4: Implement the minimal status projection**

In `RecordingControllerPanel.swift`, add:

```swift
enum RecordingControllerInputStatus: String, Equatable {
    case signal = "Signal"
    case quiet = "Quiet"
    case muted = "Muted"
    case disconnected = "Disconnected"

    static func make(
        level: LevelSnapshot,
        isConnected: Bool,
        isMuted: Bool
    ) -> Self {
        if !isConnected { return .disconnected }
        if isMuted { return .muted }
        return level.isSilent ? .quiet : .signal
    }
}
```

Add the two waveform accessibility IDs to `RecordingControllerAccessibility.allIDs` without renaming existing IDs.

- [ ] **Step 5: Route the existing real levels into the panel**

Pass these exact values from `RecordingControllerView` into `RecordingControllerPanelContent`:

```swift
systemLevel: recorder.systemLevel,
microphoneLevel: recorder.micLevel,
isSystemConnected: recorder.isSystemCaptureConnected,
isMicrophoneConnected: recorder.isMicrophoneCaptureConnected,
isMicrophoneMuted: recorder.micMuted
```

Add corresponding immutable properties to `RecordingControllerPanelContent`.

- [ ] **Step 6: Render the two compact waveform rows**

Create a private SwiftUI row helper in the same file. It must render an icon, exact source label, existing `WaveformView(samples:tint:)`, a small status indicator, and the status raw value. Use blue-cyan for System / Teams and green-teal for Microphone. Apply the required accessibility identifier, label, and value to each waveform. Do not add controls or dB text.

Insert both rows between the header and Teams screen row. Change both `RecordingControllerPanel.panelSize` and the content frame to exactly 390 by 180.

- [ ] **Step 7: Run GREEN and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecordingControllerPanelTests|RecordingControllerRenderTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh
git diff --check
```

Expected: both selected test classes pass, app build exits 0, and diff check prints no errors.

- [ ] **Step 8: Self-review and commit**

Confirm the diff touches only the three task files, uses only real `RecordingEngine` levels, preserves every existing control/action, and contains no fake waveform data. Commit:

```bash
git add Sources/RecorderApp/Views/RecordingControllerPanel.swift Tests/RecorderAppTests/RecordingControllerPanelTests.swift Tests/RecorderAppTests/RecordingControllerRenderTests.swift
git commit -m "feat: show dual input waveforms in floating recorder"
```
