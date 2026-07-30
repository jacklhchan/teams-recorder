# Virtual Microphone and AirPods Mute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Local Recorder Virtual Mic` so Teams can stay unmuted while an AirPods gesture silences both recorded microphone audio and the microphone stream sent to Teams.

**Architecture:** The recorder publishes normalized 48 kHz mono microphone PCM into a bounded lock-free shared ring buffer. A local Core Audio HAL plug-in exposes the buffer as an input device and emits silence whenever the producer is missing, muted, disconnected, or late. `AVAudioApplication` unifies compatible AirPods gestures, the app button, and the existing hotkey.

**Tech Stack:** Swift 5.9, AVFAudio, CoreAudio AudioServerPlugIn, C++17 atomics, POSIX shared memory, XCTest, XCTest/C++ harness, macOS 26+

## Global Constraints

- `Local Recorder Virtual Mic` carries physical microphone audio only, never system/application audio.
- Teams may remain unmuted and selects the virtual microphone once.
- Mute zeroes microphone samples before both meeting mix and virtual-mic publication.
- Driver realtime callbacks do not allocate, block, log, access files, or use network APIs.
- Missing producer, mute, disconnect, app crash, and underrun always emit fresh silence.
- Overrun drops oldest unread frames; stale samples are never replayed.
- User enters administrator authentication directly; no password is received, embedded, stored, or logged.
- Initial delivery is local/ad-hoc development use. Developer ID, notarization, public packaging, and updater hardening are deferred.
- Keep unrelated installer manifest files out of every commit.
- Complete Phase 1 before integrating Phase 2 into the app.

## Execution Amendment (2026-07-26)

The implementation follows these corrections before the numbered tasks below:

1. Start with a driver-host viability slice derived from Apple's
   `CreatingAnAudioServerDriverPlugIn` NullAudio sample. Publish an input-only
   silence device first, install it only with explicit user approval, reboot,
   and prove that Core Audio and Teams enumerate it before building the PCM
   bridge.
2. Use the exact device contract:
   - display name: `Local Recorder Virtual Mic`
   - device UID: `local.meeting.recorder.virtual-mic.v1`
   - model UID: `local.meeting.recorder.virtual-mic.model.v1`
   - input-only 48,000 Hz mono Float32
3. Do not let the producer advance a shared consumer cursor. The producer owns
   a monotonically increasing write sequence; every reader owns its own sample
   cursor and advances itself on overrun.
4. Tag published slots with source/mute generations. A mute, disconnect, or
   producer restart invalidates queued speech so unmute cannot replay stale
   microphone frames.
5. Support multiple HAL clients and same-cycle fan-out. Reads are indexed by
   device sample time, or one device-cycle result is copied to every client;
   clients must never destructively consume one global stream.
6. Publish normalized microphone blocks while monitoring, before the recording
   writer guard. Make system-audio publication impossible at the Swift API
   boundary.
7. Apply mute/source-generation changes synchronously through one atomic gate.
   Main-actor state is display state only.
8. Treat direct POSIX shared-memory access from the sandboxed plug-in as
   unproven until the installed driver-host spike passes. If blocked, retain
   shared memory for realtime PCM and use a declared Mach-service handshake for
   setup/control only.
9. Do not assume mode `0666`, ad-hoc signing, or restarting `coreaudiod` is
   sufficient. First install/removal uses the supported reboot flow. If the
   ad-hoc bundle does not load with SIP enabled, obtain an Apple Development
   identity or use the dedicated-helper process-tap fallback; do not disable
   SIP by default.
10. AirPods/Beats mute gesture support through `AVAudioApplication` is
    conditional until observed with the exact accessory. App button and hotkey
    mute are deterministic and feed the same recorder-plus-virtual-mic gate;
    Teams UI mute is neither read nor changed.

The effective execution order is therefore: driver viability, bridge and
multi-reader tests, recorder publisher, unified mute, full driver data path,
packaging/integration, then live isolation/Teams/AirPods acceptance.

---

## File Structure

### New files

- `Sources/VirtualMicBridge/include/VirtualMicShared.h`: shared ABI, atomics, capacity, state flags, counters.
- `Sources/VirtualMicBridge/VirtualMicRingBuffer.cpp`: producer/consumer implementation.
- `Sources/RecorderApp/VirtualMic/VirtualMicPublisher.swift`: shared-memory lifecycle and mic block publication.
- `Sources/RecorderApp/VirtualMic/InputMuteController.swift`: `AVAudioApplication` handler and notification bridge.
- `Sources/RecorderApp/VirtualMic/VirtualMicStatus.swift`: installed/connected/underrun/overrun state.
- `Driver/LocalRecorderVirtualMic/Info.plist`: HAL plug-in metadata.
- `Driver/LocalRecorderVirtualMic/VirtualMicDriver.cpp`: AudioServerPlugIn interfaces and realtime input read.
- `Driver/LocalRecorderVirtualMic/VirtualMicDriver.h`: driver object identifiers and declarations.
- `Driver/LocalRecorderVirtualMic/CMakeLists.txt`: deterministic local driver build.
- `scripts/build-virtual-mic.sh`: build and ad-hoc sign plug-in.
- `scripts/install-virtual-mic.sh`: explicit privileged copy and Core Audio reload.
- `scripts/uninstall-virtual-mic.sh`: move only this driver to Trash/backup and reload Core Audio.
- `Tests/VirtualMicBridgeTests/VirtualMicRingBufferTests.cpp`: wraparound, stress, silence, restart, mute.
- `Tests/VirtualMicBridgeTests/CMakeLists.txt`: dependency-free CTest harness for the C++ bridge.
- `Tests/RecorderAppTests/InputMuteControllerTests.swift`: mute fan-out behavior.
- `Tests/RecorderAppTests/VirtualMicStatusTests.swift`: health/status mapping.

### Modified files

- `Package.swift`: add C++ bridge target and link it to app/tests.
- `Sources/RecorderApp/RecordingEngine.swift`: publish mic blocks after mute and before stereo mix.
- `Sources/RecorderApp/AppModel.swift`: install/status actions and unified mute controller.
- `Sources/RecorderApp/ContentView.swift`: virtual mic status and exact mute label.
- `Sources/RecorderApp/RecordingModels.swift`: virtual mic health counters.
- `scripts/build-app.sh`: package driver setup scripts/resources.

---

### Task 1: Shared Ring Buffer ABI and Stress Tests

**Files:**
- Create: `Sources/VirtualMicBridge/include/VirtualMicShared.h`
- Create: `Sources/VirtualMicBridge/VirtualMicRingBuffer.cpp`
- Create: `Tests/VirtualMicBridgeTests/VirtualMicRingBufferTests.cpp`
- Modify: `Package.swift`

**Interfaces:**
- Produces C ABI: `VMOpenProducer`, `VMCloseProducer`, `VMWriteFrames`,
  `VMOpenConsumer`, `VMReadFrames`, `VMSetMuted`, `VMGetStats`.
- Consumes: mono Float32 frames at exactly 48,000 Hz.

- [ ] **Step 1: Add the failing C++ test target**

Define a dependency-free CTest executable that opens producer and consumer
handles against one unique test shared-memory name. Start with:

```cpp
static void emptyConsumerReceivesSilence() {
    const auto name = uniqueName();
    auto producer = VMOpenProducer(name.c_str(), 48000);
    auto consumer = VMOpenConsumer(name.c_str(), 48000);
    float output[128];
    auto read = VMReadFrames(consumer, output, 128);
    REQUIRE(read == 128u);
    REQUIRE(std::all_of(output, output + 128,
                        [](float value) { return value == 0.0f; }));
    VMCloseConsumer(consumer);
    VMCloseProducer(producer);
    VMUnlink(name.c_str());
}
```

- [ ] **Step 2: Run and verify RED**

Run:

```bash
cmake -S Tests/VirtualMicBridgeTests -B build/virtual-mic-bridge-tests
cmake --build build/virtual-mic-bridge-tests
ctest --test-dir build/virtual-mic-bridge-tests --output-on-failure
```

Expected: link failure because ring-buffer functions do not exist.

- [ ] **Step 3: Define fixed shared ABI**

Use a versioned header containing:

```cpp
struct alignas(64) VMSharedHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t capacityFrames;
    std::atomic<uint64_t> writeIndex;
    std::atomic<uint64_t> readIndex;
    std::atomic<uint64_t> producerGeneration;
    std::atomic<uint64_t> underruns;
    std::atomic<uint64_t> overruns;
    std::atomic<uint32_t> muted;
    std::atomic<uint32_t> producerConnected;
};
```

The sample array follows the header. Use acquire/release atomics; never use a
mutex in read/write paths. Production uses the exact POSIX shared-memory name
`/local.meeting.recorder.virtualmic.v1`. Test names append a UUID and are always
unlinked in teardown. Local development creates the production object with
mode `0666` so the user app and Core Audio host can both map it; narrowing this
cross-process access is part of the deferred distribution/security milestone.

- [ ] **Step 4: Implement silence, wraparound, and overrun policy**

`VMReadFrames` always returns the requested frame count. It copies available
frames and zero-fills the remainder. On overrun, `VMWriteFrames` advances
`readIndex` to retain only the newest `capacityFrames`; increment `overruns`.
When producer generation changes, the consumer discards unread frames.

- [ ] **Step 5: Add concurrency tests**

Add dependency-free test functions:

```cpp
static void wraparoundPreservesFrameOrder()
static void mutedProducerYieldsSilence()
static void overrunDropsOldestFrames()
static void producerRestartNeverReplaysStaleFrames()
static void concurrentStressKeepsSamplesFinite()
```

Stress producer and consumer for at least one million frames. Expected: no
deadlock, non-finite sample, stale generation, or out-of-bounds counter.

- [ ] **Step 6: Run tests and commit**

Run the CMake/CTest commands three times. Expected: all pass.

```bash
git add Package.swift Sources/VirtualMicBridge Tests/VirtualMicBridgeTests
git commit -m "Add virtual microphone ring buffer"
```

---

### Task 2: Recorder Publisher

**Files:**
- Create: `Sources/RecorderApp/VirtualMic/VirtualMicPublisher.swift`
- Create: `Sources/RecorderApp/VirtualMic/VirtualMicStatus.swift`
- Test: `Tests/RecorderAppTests/VirtualMicStatusTests.swift`

**Interfaces:**
- Consumes: normalized microphone `AudioFrameBlock` from Phase 1.
- Produces: `VirtualMicPublishing.start()`, `publish(_:)`, `setMuted(_:)`,
  `stop()`, and `VirtualMicStats`.

- [ ] **Step 1: Write failing publisher-status tests**

Use a fake C bridge and assert:

```swift
func testStoppedPublisherReportsUnavailable()
func testPublishDownmixesStereoToMono()
func testMutedPublisherWritesOnlyZeros()
func testBridgeCountersMapToWarningStatus()
```

For downmix, input left `[1, 0]` and right `[0, 1]`; expected mono
`[0.5, 0.5]`.

- [ ] **Step 2: Run tests and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter VirtualMicStatusTests
```

Expected: compile failure for missing publisher and status types.

- [ ] **Step 3: Implement bounded publisher**

Open the producer when monitoring starts. Downmix normalized stereo blocks:

```swift
mono[index] = (left[index] + right[index]) * 0.5
```

If muted, fill the same frame count with zero. Do not retain unbounded Swift
arrays; reuse one capacity-limited buffer. Close producer on engine shutdown.

- [ ] **Step 4: Run tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter VirtualMicStatusTests
git add Sources/RecorderApp/VirtualMic Tests/RecorderAppTests/VirtualMicStatusTests.swift
git commit -m "Publish microphone audio to virtual device"
```

---

### Task 3: Unified AirPods and App Mute State

**Files:**
- Create: `Sources/RecorderApp/VirtualMic/InputMuteController.swift`
- Test: `Tests/RecorderAppTests/InputMuteControllerTests.swift`

**Interfaces:**
- Produces: `InputMuteControlling.install(onChange:)`,
  `setMuted(_:) throws`, `isMuted`, and `uninstall()`.
- Consumes: `AVAudioApplication.shared`.

- [ ] **Step 1: Write failing mute-controller tests**

Inject an `InputMuteApplication` protocol and verify:

```swift
func testAccessoryGestureUpdatesRecorderMute()
func testButtonMuteCallsApplicationSetInputMuted()
func testRejectedMuteReturnsFalseWithoutChangingState()
func testUninstallRemovesHandler()
```

- [ ] **Step 2: Run tests and verify RED**

Run the InputMuteController test filter. Expected: missing controller types.

- [ ] **Step 3: Implement macOS input mute integration**

Register:

```swift
try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] muted in
    guard let self else { return false }
    self.applyMuteToAudioPaths(muted)
    return true
}
```

Observe `AVAudioApplication.inputMuteStateChangeNotification` for main-thread
UI updates. Button and hotkey call `setInputMuted(_:)`; they do not toggle a
separate Boolean.

- [ ] **Step 4: Run tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter InputMuteControllerTests
git add Sources/RecorderApp/VirtualMic/InputMuteController.swift \
  Tests/RecorderAppTests/InputMuteControllerTests.swift
git commit -m "Unify AirPods and recorder mute state"
```

---

### Task 4: Core Audio HAL Virtual Device

**Files:**
- Create: `Driver/LocalRecorderVirtualMic/Info.plist`
- Create: `Driver/LocalRecorderVirtualMic/VirtualMicDriver.h`
- Create: `Driver/LocalRecorderVirtualMic/VirtualMicDriver.cpp`
- Create: `Driver/LocalRecorderVirtualMic/CMakeLists.txt`
- Reuse: `Sources/VirtualMicBridge/include/VirtualMicShared.h`
- Reuse: `Sources/VirtualMicBridge/VirtualMicRingBuffer.cpp`

**Interfaces:**
- Consumes: shared ring buffer at 48 kHz mono Float32.
- Produces: Core Audio input device `Local Recorder Virtual Mic`, one input
  stream, stable UID `local.meeting.recorder.virtual-mic`.

- [ ] **Step 1: Create a driver contract smoke test**

Add a C++ test that instantiates the plug-in factory and verifies the published
object graph contains plug-in, box, device, and one input stream object with:

```text
sample rate: 48000
channels: 1
format: Float32
direction: input
device UID: local.meeting.recorder.virtual-mic
```

- [ ] **Step 2: Run and verify RED**

Build the driver test. Expected: missing plug-in factory symbol.

- [ ] **Step 3: Implement required AudioServerPlugIn interfaces**

Implement factory, initialize, object-property dispatch, device start/stop,
zero timestamp, IO operation negotiation, and read-input processing. Advertise
only the fixed 48 kHz mono format. Reject unsupported format changes with the
correct Core Audio status.

- [ ] **Step 4: Implement realtime read**

During read-input operation, request exactly the host frame count from
`VMReadFrames`. The C bridge fills silence for missing data. Do not call
`NSLog`, allocate, lock, open shared memory, or update UI in this callback.
Open/close the consumer during device start/stop.

- [ ] **Step 5: Run driver tests and inspect binary**

```bash
cmake -S Driver/LocalRecorderVirtualMic \
  -B build/virtual-mic-driver \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build/virtual-mic-driver
ctest --test-dir build/virtual-mic-driver --output-on-failure
otool -L build/virtual-mic-driver/LocalRecorderVirtualMic.driver/Contents/MacOS/LocalRecorderVirtualMic
```

Expected: tests pass; binary links only macOS system frameworks and C++ runtime.

- [ ] **Step 6: Commit**

```bash
git add Driver/LocalRecorderVirtualMic
git commit -m "Add Local Recorder virtual microphone driver"
```

---

### Task 5: Driver Build, Install, and Detection

**Files:**
- Create: `scripts/build-virtual-mic.sh`
- Create: `scripts/install-virtual-mic.sh`
- Create: `scripts/uninstall-virtual-mic.sh`
- Modify: `scripts/build-app.sh`
- Test: `Tests/RecorderAppTests/VirtualMicStatusTests.swift`

**Interfaces:**
- Produces: signed `.driver` bundle, explicit local install/remove commands, and
  app-visible installed status.
- Consumes: Task 4 driver output.

- [ ] **Step 1: Add failing installed-status tests**

Test exact path and Core Audio UID mapping:

```swift
XCTAssertEqual(
    VirtualMicInstallation.driverURL.path,
    "/Library/Audio/Plug-Ins/HAL/LocalRecorderVirtualMic.driver"
)
```

Installed means both the bundle exists and Core Audio enumerates
`local.meeting.recorder.virtual-mic`.

- [ ] **Step 2: Run and verify RED**

Run the VirtualMicStatus test filter. Expected: missing installation type.

- [ ] **Step 3: Build and sign script**

Build Release, assemble the bundle, validate its plist and executable, then:

```bash
codesign --force --sign - \
  build/LocalRecorderVirtualMic.driver
codesign --verify --deep --strict \
  build/LocalRecorderVirtualMic.driver
```

- [ ] **Step 4: Explicit install and uninstall scripts**

Install only the exact built bundle to:

```text
/Library/Audio/Plug-Ins/HAL/LocalRecorderVirtualMic.driver
```

Use `/usr/bin/sudo` interactively, set root ownership, then reload Core Audio.
Never accept a password argument or environment variable. Uninstall moves only
that exact bundle to a timestamped backup under the user's Trash or a dedicated
backup path before reloading Core Audio.

- [ ] **Step 5: Package setup resources and verify**

Include driver scripts/resources in app build output, run tests, build driver,
and validate signatures.

- [ ] **Step 6: Commit**

```bash
git add scripts/build-virtual-mic.sh scripts/install-virtual-mic.sh \
  scripts/uninstall-virtual-mic.sh scripts/build-app.sh \
  Tests/RecorderAppTests/VirtualMicStatusTests.swift
git commit -m "Add local virtual mic setup"
```

---

### Task 6: Recorder and UI Integration

**Files:**
- Modify: `Sources/RecorderApp/RecordingEngine.swift`
- Modify: `Sources/RecorderApp/RecordingModels.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Test: `Tests/RecorderAppTests/RecordingEngineStateTests.swift`

**Interfaces:**
- Consumes: `VirtualMicPublisher`, `InputMuteController`, installation status.
- Produces: mic fan-out, exact mute state, driver health UI, setup action.

- [ ] **Step 1: Add failing fan-out tests**

Verify one normalized mic block reaches the meeting mixer and publisher; after
mute, both paths receive equal-length zeros. Verify system blocks never reach
the virtual publisher. Verify app stop closes producer.

- [ ] **Step 2: Run and verify RED**

Run RecordingEngineStateTests. Expected: missing publisher integration.

- [ ] **Step 3: Integrate publisher and mute controller**

Install mute handler once during app initialization. Route app button and hotkey
to `InputMuteController.setMuted`. Publish only `.microphone` blocks after mute
has been applied. Keep capture and driver clocks running while muted.

- [ ] **Step 4: Add UI**

Display:

```text
Local Recorder Virtual Mic: Ready / Not Installed / Disconnected / Warning
Recorder + Virtual Mic Muted
```

Provide setup/log actions only when relevant. Do not display or alter Teams'
mute state.

- [ ] **Step 5: Run full tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git diff --check
git add Sources/RecorderApp/RecordingEngine.swift \
  Sources/RecorderApp/RecordingModels.swift Sources/RecorderApp/AppModel.swift \
  Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/RecordingEngineStateTests.swift
git commit -m "Connect recorder mute to virtual microphone"
```

---

### Task 7: Phase 2 Installation and Live Teams Acceptance

**Files:**
- Create: `docs/testing/2026-07-25-virtual-mic-acceptance.md`
- Modify implementation files only when a failing acceptance check has a
  reproducing automated test.

**Interfaces:**
- Consumes: complete Phase 2 build.
- Produces: installed virtual device, Teams test evidence, AirPods mute evidence,
  crash/disconnect silence evidence.

- [ ] **Step 1: Run clean automated verification**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cmake --build build/virtual-mic-driver
ctest --test-dir build/virtual-mic-driver --output-on-failure
git diff --check
```

Expected: all suites pass.

- [ ] **Step 2: Install driver with user authentication**

Run:

```bash
scripts/install-virtual-mic.sh
```

The user enters the administrator password directly in the interactive prompt.
Verify `Local Recorder Virtual Mic` appears in Audio MIDI Setup and:

```bash
system_profiler SPAudioDataType
```

- [ ] **Step 3: Verify normal Teams audio**

Select `Local Recorder Virtual Mic` as Teams microphone. Keep Teams unmuted.
Start recorder monitoring and perform a Teams test call. Confirm speech reaches
the remote/test-call playback and the recording.

- [ ] **Step 4: Verify AirPods mute**

Press the compatible AirPods mute gesture. Confirm UI changes to
`Recorder + Virtual Mic Muted`, recorded mic waveform becomes zero, and Teams
test-call playback receives silence. Press again and confirm both paths resume.

- [ ] **Step 5: Verify failure-safe silence**

While Teams remains unmuted, separately test recorder quit, AirPods disconnect,
producer restart, and forced ring-buffer underrun. Every case must produce
silence without stale speech, tick, or non-finite output.

- [ ] **Step 6: Document evidence and commit milestone**

Record macOS version, AirPods model, driver UID, Teams version, call/test method,
output recording paths, counter values, and pass/fail. Do not claim AirPods
gesture support if the connected model does not generate the callback.

```bash
git add docs/testing/2026-07-25-virtual-mic-acceptance.md
git commit -m "Validate virtual microphone and AirPods mute"
```
