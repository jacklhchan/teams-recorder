# Teams Screen Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record Microsoft Teams meeting-window video, Teams application audio, and the selected microphone into one synchronized, storage-conscious MP4 while preserving current mute, virtual-microphone, library, playback, and oMLX transcription behavior.

**Architecture:** Keep one ScreenCaptureKit stream. A deterministic Teams-window resolver selects a meeting window, and a serialized filter coordinator switches the running stream between its current application filter and a desktop-independent window filter. Existing timestamp-aligned mixed audio and bounded video frames enter a dedicated media coordinator, which writes a fixed-profile HEVC/AAC MP4 plus a temporary AAC safety file. Library, recovery, playback, and transcription layers consume one final MP4 or a recovered M4A.

**Tech Stack:** Swift 5.9, SwiftUI, ScreenCaptureKit, AVFoundation, AVKit, VideoToolbox, CoreMedia, CoreVideo, CoreGraphics, XCTest, macOS 15+

## Global Constraints

- The approved design is `docs/superpowers/specs/2026-07-26-teams-screen-capture-design.md`.
- Task 1 is a hard viability gate. Do not start Tasks 2-14 unless the installed-app probe proves that one window-filtered `SCStream` preserves Teams audio, microphone audio, and complete meeting-window video on this Mac.
- If Task 1 fails, record the evidence and revisit the design. Do not silently introduce a second stream or a new clock domain.
- Never change the Mac output device and never reintroduce BlackHole or Multi-Output Device routing.
- Screen capture is available only when `com.microsoft.teams2` is the selected application source.
- Every new recording starts with screen capture off and preconfigures one video input so it can be enabled later.
- New successful sessions end with exactly one `recording.mp4`; legacy and recovered audio sessions remain `recording.m4a`.
- Use a fixed 1600 x 900 canvas, HEVC at 1.2 Mbps, at most 10 fps, and AAC stereo at 48 kHz/128 kbps.
- ScreenCaptureKit must use `scalesToFit = true`, `preservesAspectRatio = true`, a black background, and a fixed canvas. Do not stretch the Teams window.
- Prefer NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`); retry stream startup once with BGRA only when the preferred pixel format cannot start.
- Video callbacks, rendering, conversion, and writer work must never execute on the audio callback path or the main actor.
- Video ingress is bounded and latest-frame-wins. Encoder backpressure drops video; it never blocks audio.
- The existing mixed-audio `startFrame` remains the authoritative 48 kHz source timestamp.
- Application reconnect, resolver refresh, manual selection, and screen toggles must serialize filter changes and reject stale completions.
- New screen/video failures must not enter the existing system-audio disconnect cases in `RecordingEngine.receive(_:ticket:)`.
- Manual transcription import remains audio-only. Do not add `mp4` to `ManualTranscriptionImporter.supportedExtensions`.
- Old `recording-info.json` files must decode with title, tags, and favorite intact and safe defaults for every new field.
- Partial MP4 and backup M4A files are recovery artifacts and must never appear as normal library sessions.
- Use test-driven development, path-limited commits, and an independent cumulative review before installing a candidate.
- Do not claim completion until the live Teams share, AirPods mute, playback, transcription, recovery, storage, and 30-minute synchronization checks pass.

---

## File Structure

### New production files

- `Sources/RecorderApp/Capture/TeamsCaptureViabilityProbe.swift`: installed-app same-stream probe and report evaluator.
- `Sources/RecorderApp/Capture/TeamsMeetingWindow.swift`: stable window identity, descriptors, confidence, resolution, and deterministic resolver.
- `Sources/RecorderApp/Capture/CaptureFilterCoordinator.swift`: serialized/coalesced application-window filter state machine.
- `Sources/RecorderApp/Media/ScreenVideoFrame.swift`: retained pixel buffer, source PTS, frame status, pixel format, and filter revision.
- `Sources/RecorderApp/Media/RecordingTimeline.swift`: 48 kHz source-time to session-time mapping and video timestamp validation.
- `Sources/RecorderApp/Media/VideoGate.swift`: black-frame holds, enabled intervals, stalls, and final frame decisions.
- `Sources/RecorderApp/Media/VideoFrameSurface.swift`: fixed-canvas validation, aspect-fit calculations, and black NV12/BGRA buffers.
- `Sources/RecorderApp/Media/MuxedMediaWriter.swift`: HEVC/AAC AVAssetWriter implementation and synthetic media validation.
- `Sources/RecorderApp/Media/RecordingMediaCoordinator.swift`: bounded ingress, timeline, gate, mux/safety writers, finalization, and fallback.
- `Sources/RecorderApp/RecordingMedia.swift`: persisted media kind, screen intervals, Teams window identity, and recovery state.
- `Sources/RecorderApp/Storage/RecordingStoragePolicy.swift`: selected-volume capacity provider and deterministic thresholds.
- `Sources/RecorderApp/Recovery/IncompleteSessionRecovery.swift`: idempotent backup validation and promotion.
- `Sources/RecorderApp/Transcription/TranscriptionAudioPreparer.swift`: MP4-to-temporary-M4A extraction and cleanup token.
- `Sources/RecorderApp/Playback/PlaybackCoordinator.swift`: unified AVPlayer lifecycle and observable playback state.
- `Sources/RecorderApp/Views/TeamsCaptureViabilityProbeView.swift`: command-line-only live probe UI.
- `Sources/RecorderApp/Views/TeamsScreenCaptureControlsView.swift`: Teams window status, toggle, and manual correction menu.
- `Sources/RecorderApp/Views/RecordingPlaybackView.swift`: compact audio controls or AVKit video playback.

### New tests

- `Tests/RecorderAppTests/TeamsCaptureViabilityReportTests.swift`
- `Tests/RecorderAppTests/TeamsMeetingWindowResolverTests.swift`
- `Tests/RecorderAppTests/CaptureFilterCoordinatorTests.swift`
- `Tests/RecorderAppTests/ScreenCaptureVideoRoutingTests.swift`
- `Tests/RecorderAppTests/RecordingTimelineTests.swift`
- `Tests/RecorderAppTests/VideoGateTests.swift`
- `Tests/RecorderAppTests/VideoFrameSurfaceTests.swift`
- `Tests/RecorderAppTests/MuxedMediaWriterIntegrationTests.swift`
- `Tests/RecorderAppTests/RecordingMediaCoordinatorTests.swift`
- `Tests/RecorderAppTests/IncompleteSessionRecoveryTests.swift`
- `Tests/RecorderAppTests/RecordingStoragePolicyTests.swift`
- `Tests/RecorderAppTests/TranscriptionAudioPreparerTests.swift`
- `Tests/RecorderAppTests/PlaybackCoordinatorTests.swift`
- `Tests/RecorderAppTests/AppModelPlaybackTests.swift`
- `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`

### Modified files

- `Package.swift`
- `Sources/RecorderApp/LocalMeetingRecorderApp.swift`
- `Sources/RecorderApp/Capture/CaptureModels.swift`
- `Sources/RecorderApp/Capture/ScreenCaptureSource.swift`
- `Sources/RecorderApp/RecordingEngine.swift`
- `Sources/RecorderApp/RecordingModels.swift`
- `Sources/RecorderApp/MixedAudioWriter.swift`
- `Sources/RecorderApp/RecordingLibrary.swift`
- `Sources/RecorderApp/RecordingSession.swift`
- `Sources/RecorderApp/AppModel.swift`
- `Sources/RecorderApp/ContentView.swift`
- `Tests/RecorderAppTests/RecordingEngineStateTests.swift`
- `Tests/RecorderAppTests/MixedAudioWriterTests.swift`
- `Tests/RecorderAppTests/RecordingLibraryTests.swift`
- `Tests/RecorderAppTests/AppModelMuteTests.swift`
- `Tests/RecorderAppTests/CaptureStatusTests.swift`
- `Tests/RecorderAppTests/NativeAudioCaptureHardeningTests.swift`
- `Tests/RecorderAppTests/TeamsMuteSyncTests.swift`

### Acceptance evidence

- `docs/testing/2026-07-26-teams-screen-capture-viability.md`
- `docs/testing/2026-07-26-teams-screen-capture-acceptance.md`

---

### Task 1: Installed-App Same-Stream Viability Gate

**Files:**
- Create: `Sources/RecorderApp/Capture/TeamsCaptureViabilityProbe.swift`
- Create: `Sources/RecorderApp/Views/TeamsCaptureViabilityProbeView.swift`
- Modify: `Sources/RecorderApp/LocalMeetingRecorderApp.swift`
- Test: `Tests/RecorderAppTests/TeamsCaptureViabilityReportTests.swift`
- Create: `docs/testing/2026-07-26-teams-screen-capture-viability.md`

**Interfaces:**

```swift
struct TeamsCaptureViabilityDwell: Codable, Equatable {
    let filterRevision: UInt64
    let windowID: UInt32?
    let duration: TimeInterval
    let streamIdentity: String
    let completeScreenFrameCount: Int
    let nonSilentSystemBufferCount: Int
    let nonSilentMicrophoneBufferCount: Int
    var maximumSystemPTSGap: TimeInterval
    var maximumMicrophonePTSGap: TimeInterval
    let capturedFramePNG: String?
}

struct TeamsCaptureViabilityReport: Codable, Equatable {
    var streamIdentities: Set<String>
    var filterTransitionCount: Int
    var applicationBaseline: TeamsCaptureViabilityDwell
    var windowFilterDwells: [TeamsCaptureViabilityDwell]
    var observedWindowIDs: Set<UInt32>
    var notes: [String]
}

enum TeamsCaptureViabilityEvaluator {
    static func failures(in report: TeamsCaptureViabilityReport) -> [String]
}
```

Pass only when there is one stream identity, at least four
application-window-application transitions, and every window-filter dwell lasts
at least five seconds while a known continuous Teams clip and microphone speech
are active. Every such dwell must contain non-silent system and microphone
buffers, at least ten complete frames, its own captured PNG, no callback stop,
and no unexplained audio PTS gap above 250 ms.

- [ ] **Step 1: Write the failing report-evaluator tests**

Test one passing report and separate failures for a replaced stream, missing Teams audio, missing microphone audio, missing complete frames, too few filter transitions, and an audio PTS gap over 250 ms.

```swift
func testReportPassesOnlyWhenOneStreamPreservesAllThreeMediaOutputs()
func testReportFailsWhenWindowFilterLosesTeamsAudio()
func testReportFailsWhenOnlyApplicationFilterHasMicrophoneAudio()
func testReportFailsWhenAnyWindowDwellLacksItsOwnCompleteFrame()
func testReportFailsWhenFilterUpdateRecreatesTheStream()
func testReportFailsWhenAudioPTSHasAnUnexplainedGap()
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter TeamsCaptureViabilityReportTests
```

Expected: compilation fails because the viability report and evaluator do not exist.

- [ ] **Step 3: Implement the command-line-only installed-app probe**

`LocalMeetingRecorderApp` selects the probe UI only when launched with
`--teams-screen-viability-probe`; normal launches still show `ContentView`.

The probe must:

- enumerate only windows owned by `com.microsoft.teams2`;
- let the operator manually select a window;
- create one `SCStream` with `.audio`, `.microphone`, and `.screen`;
- begin with the existing Teams application filter;
- switch to `SCContentFilter(desktopIndependentWindow:)` and back without recreating the stream;
- configure 1600 x 900, 10 fps, queue depth 3, NV12, aspect preservation, black background, and hidden local cursor;
- tag every callback with the active filter revision and accumulate separate
  metrics for the application baseline and each window-filter dwell;
- show live system RMS, microphone RMS, complete-frame count, stream identity,
  filter revision, and PTS-gap counters;
- save JSON plus one complete-frame PNG for every window-filter dwell to
  Downloads when stopped.

Do not share this probe's lifecycle implementation with production capture yet; the gate must remain a small, auditable experiment.

- [ ] **Step 4: Run tests and build the installed candidate**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter TeamsCaptureViabilityReportTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
scripts/build-app.sh
scripts/install-app.sh
open -n -a "/Applications/Local Meeting Recorder.app" \
  --args --teams-screen-viability-probe
```

Expected: evaluator tests pass, the app builds, and the probe appears under the installed app's existing TCC identity.

- [ ] **Step 5: Execute the hard live gate**

Join a real Teams call with participant speech and microphone speech, then:

1. capture with the application filter;
2. switch to the selected meeting-window filter;
3. occlude, resize, move, and place the window on another display;
4. minimize and restore it;
5. pop out or replace the meeting window;
6. switch application-window-application at least four times;
7. confirm the complete meeting window, Teams audio, and microphone continue on the same stream identity.

Write exact app version, Teams version, selected window IDs, output JSON/PNG paths, counters, observed gaps, and pass/fail in the viability document.

Expected: `TeamsCaptureViabilityEvaluator.failures(in:)` returns an empty array,
every window-filter dwell independently passes audio/mic/video checks, and every
saved frame visibly contains the complete meeting window.

**Hard stop:** If any criterion fails, commit the failed evidence and stop. Do not execute Task 2.

- [ ] **Step 6: Commit the probe and evidence**

```bash
git add Sources/RecorderApp/Capture/TeamsCaptureViabilityProbe.swift \
  Sources/RecorderApp/Views/TeamsCaptureViabilityProbeView.swift \
  Sources/RecorderApp/LocalMeetingRecorderApp.swift \
  Tests/RecorderAppTests/TeamsCaptureViabilityReportTests.swift \
  docs/testing/2026-07-26-teams-screen-capture-viability.md
```

On pass:

```bash
git commit -m "Validate same-stream Teams window capture"
```

On hard-gate failure:

```bash
git commit -m "Document failed Teams screen capture gate"
```

---

### Task 2: Teams Meeting-Window Domain and Resolver

**Files:**
- Create: `Sources/RecorderApp/Capture/TeamsMeetingWindow.swift`
- Test: `Tests/RecorderAppTests/TeamsMeetingWindowResolverTests.swift`

**Interfaces:**

```swift
struct TeamsWindowIdentity: Codable, Hashable, Sendable {
    let processID: pid_t
    let windowID: CGWindowID
}

struct TeamsWindowSnapshot: Identifiable, Equatable, Sendable {
    let identity: TeamsWindowIdentity
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
    var id: TeamsWindowIdentity { identity }
}

struct TeamsWindowDescriptor: Identifiable, Equatable, Sendable {
    let identity: TeamsWindowIdentity
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
    let firstSeenAt: Date
    let lastSurfacedAt: Date?
    var id: TeamsWindowIdentity { identity }
}

enum TeamsWindowConfidence: Int, Codable, Sendable {
    case low
    case medium
    case high
}

struct TeamsWindowMatch: Equatable, Sendable {
    let window: TeamsWindowDescriptor
    let confidence: TeamsWindowConfidence
}

enum TeamsWindowResolution: Equatable, Sendable {
    case ready(TeamsWindowMatch)
    case ambiguous([TeamsWindowDescriptor])
    case waiting
}

struct TeamsMeetingWindowResolver {
    mutating func observe(
        _ windows: [TeamsWindowSnapshot],
        meetingActive: Bool,
        now: Date
    ) -> TeamsWindowResolution
    mutating func selectManualOverride(_ identity: TeamsWindowIdentity?)
    mutating func resetForApplicationRestart()
}
```

Resolver policy:

- identities always include owner PID and window ID because `CGWindowID` can be reused;
- manual selection clears the old current choice and wins immediately;
- otherwise retain the current window while its identity remains present;
- reject non-zero layer windows, width below 640, height below 360, area below 230,400 pixels, and known utility titles such as Settings, Notification, and Microsoft Teams Helper;
- only auto-select on-screen candidates;
- prefer candidates first observed or surfaced on-screen after entering a Teams
  meeting, then largest area;
- return `.ambiguous` when the top two candidates are within 10% area and have the same meeting-era score;
- keep manual override and first-seen state in memory only; never persist them across process restart;
- never request Accessibility permission.

- [ ] **Step 1: Write failing resolver tests**

```swift
func testRejectsNonTeamsUtilitySizedAndNonNormalLayerWindows()
func testRetainsCurrentWindowAcrossResizeAndOcclusion()
func testManualOverrideReplacesCurrentWindow()
func testPrefersWindowFirstSeenAfterMeetingBegan()
func testPrefersWindowSurfacedAfterMeetingBegan()
func testSelectsLargestHighConfidenceOnScreenCandidate()
func testSimilarCandidatesFailClosedAsAmbiguous()
func testOwnerPIDPreventsReusedWindowIDFromMatchingAfterRestart()
func testMinimizedCurrentWindowRemainsIdentifiedButIsNotCaptureReady()
```

- [ ] **Step 2: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter TeamsMeetingWindowResolverTests
```

Expected: compilation fails because the Teams window domain does not exist.

- [ ] **Step 3: Implement the deterministic resolver**

Keep all thresholds as named static constants. The source emits only raw
`TeamsWindowSnapshot` values because `SCWindow` has no creation timestamp. The
resolver tracks first-seen time and every false-to-true `isOnScreen` transition,
then emits enriched descriptors. Expose candidate rejection as a pure helper so
each rejection reason is testable. A meeting transition snapshots pre-existing
identities; a later identity or later surfaced transition receives the
meeting-era preference.

- [ ] **Step 4: Verify GREEN and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter TeamsMeetingWindowResolverTests
git add Sources/RecorderApp/Capture/TeamsMeetingWindow.swift \
  Tests/RecorderAppTests/TeamsMeetingWindowResolverTests.swift
git commit -m "Add Teams meeting window resolver"
```

---

### Task 3: Serialized Filter Updates and Screen Frame Routing

**Files:**
- Create: `Sources/RecorderApp/Capture/CaptureFilterCoordinator.swift`
- Create: `Sources/RecorderApp/Media/ScreenVideoFrame.swift`
- Modify: `Sources/RecorderApp/Capture/CaptureModels.swift`
- Modify: `Sources/RecorderApp/Capture/ScreenCaptureSource.swift`
- Modify: `Sources/RecorderApp/RecordingEngine.swift`
- Test: `Tests/RecorderAppTests/CaptureFilterCoordinatorTests.swift`
- Test: `Tests/RecorderAppTests/ScreenCaptureVideoRoutingTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingEngineStateTests.swift`
- Modify: `Tests/RecorderAppTests/CaptureStatusTests.swift`
- Modify: `Tests/RecorderAppTests/NativeAudioCaptureHardeningTests.swift`

**Interfaces:**

```swift
struct CaptureFilterRevision: Hashable, Sendable {
    let sessionGeneration: UInt64
    let revision: UInt64
}

struct CaptureFilterUpdate: Equatable, Sendable {
    let intent: CaptureStreamIntent
    let revision: CaptureFilterRevision
}

enum CaptureFilterIntent: Equatable, Sendable {
    case application(CaptureApplication)
    case teamsWindow(TeamsWindowIdentity)
}

enum ScreenFrameCadence: Equatable, Sendable {
    case idle
    case enabled
}

struct CaptureStreamIntent: Equatable, Sendable {
    let filter: CaptureFilterIntent
    let cadence: ScreenFrameCadence
}

struct ScreenVideoFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
}

struct CaptureFilterCoordinator {
    mutating func request(_ intent: CaptureStreamIntent) -> CaptureFilterUpdate?
    mutating func complete(
        _ update: CaptureFilterUpdate,
        result: Result<Void, CaptureSourceError>
    ) -> CaptureFilterUpdate?
    mutating func stop()
}

struct ScreenVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sourcePTS: CMTime
    let status: SCFrameStatus
    let filterRevision: CaptureFilterRevision
}

protocol CaptureSourceProtocol: AnyObject {
    var screenVideoFormat: ScreenVideoFormat { get }
    func refreshContent() async throws -> [CaptureApplication]
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot]
    func reconnect(selection: ResolvedCaptureSelection) async throws
    func updateVideoTarget(
        _ target: TeamsWindowIdentity?
    ) async throws -> CaptureFilterRevision
    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onVideo: @escaping (ScreenVideoFrame) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws
    func stop() async
}
```

- Add `Sendable` conformance to `CaptureApplication`; all of its stored values
  are value types and it crosses the serialized filter boundary.

- [ ] **Step 1: Write failing filter state-machine tests**

Cover application-to-window, window replacement, window-to-application,
duplicate coalescing, a newer request arriving during an update, stale
completion, failed filter or configuration update, interleaved
toggle/reconnect cadence changes, reconnect sharing the same coordinator, and
stop winning over every pending update.

- [ ] **Step 2: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter CaptureFilterCoordinatorTests
```

- [ ] **Step 3: Implement the pure filter coordinator**

Only one update transaction may be in flight. Each transaction contains both
the content filter and the idle/enabled screen cadence. Keep only the newest
desired transaction. Completion returns the next coalesced update when needed.
Every update carries session generation plus revision so a completion from a
stopped stream cannot mutate a new stream.

- [ ] **Step 4: Write failing ScreenCaptureSource routing tests**

Add injectable configuration/filter factories and test:

```swift
func testTeamsStreamRegistersAudioMicrophoneAndScreenOutputs()
func testNonTeamsStreamDoesNotDeliverRealScreenFrames()
func testProductionScreenConfigurationIsFixedStorageProfile()
func testNV12IsPreferredAndBGRAIsTheOnlyFallback()
func testVideoUsesAQueueSeparateFromAudioDelivery()
func testFilterRevisionChangesOnlyAfterVideoQueueBarrier()
func testFilterAndFrameCadenceCommitAsOneRevision()
func testOverlappingDisableReconnectEnableEndsAtNewestFilterAndTenFPS()
func testVideoFailureDoesNotEmitSystemAudioDisconnect()
func testStopDrainsAndRemovesAllThreeOutputs()
```

- [ ] **Step 5: Extend ScreenCaptureSource**

For a selected Teams stream:

```swift
configuration.width = 1_600
configuration.height = 900
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
configuration.queueDepth = 3
configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
configuration.scalesToFit = true
configuration.preservesAspectRatio = true
configuration.backgroundColor = CGColor(gray: 0, alpha: 1)
configuration.showsCursor = false
```

Register `.screen` on `local-meeting-recorder.capture.video`. Parse
`SCStreamFrameInfo.status`; deliver only retained image buffers with valid,
numeric PTS. Keep audio/microphone on the existing serial audio delivery.

`updateVideoTarget(nil)` restores the existing selected-application filter and
sets the off configuration to one ignored screen frame per second.
`updateVideoTarget(window)` resolves the exact owner PID/window ID, applies
`desktopIndependentWindow`, restores 10 fps, and returns the new revision.

Apply `updateContentFilter` and `updateConfiguration` as one revisioned
transaction. If either fails, attempt to restore the prior complete intent and
report one screen-only failure. After both succeed, execute a synchronous
barrier on the video sample queue before publishing the new revision. This
drains frames from the old filter without touching the audio callback gate.

Application reconnect must request its filter through the same coordinator.
Update the two existing `CaptureSourceProtocol` fakes in
`RecordingEngineStateTests.swift` and `CaptureStatusTests.swift` in this task;
SwiftPM compiles every test source even when `--filter` selects one test class.

- [ ] **Step 6: Run focused and regression tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'CaptureFilterCoordinatorTests|ScreenCaptureVideoRoutingTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'NativeAudioCaptureHardeningTests|CaptureStatusTests'
```

Expected: all selected tests pass, stale revisions are rejected, and screen-only failures do not change system-audio connection state.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderApp/Capture/CaptureFilterCoordinator.swift \
  Sources/RecorderApp/Media/ScreenVideoFrame.swift \
  Sources/RecorderApp/Capture/CaptureModels.swift \
  Sources/RecorderApp/Capture/ScreenCaptureSource.swift \
  Sources/RecorderApp/RecordingEngine.swift \
  Tests/RecorderAppTests/CaptureFilterCoordinatorTests.swift \
  Tests/RecorderAppTests/ScreenCaptureVideoRoutingTests.swift \
  Tests/RecorderAppTests/RecordingEngineStateTests.swift \
  Tests/RecorderAppTests/CaptureStatusTests.swift \
  Tests/RecorderAppTests/NativeAudioCaptureHardeningTests.swift
git commit -m "Add Teams screen frame routing"
```

---

### Task 4: Shared Recording Timeline, Fixed Canvas, and Video Gate

**Files:**
- Create: `Sources/RecorderApp/RecordingMedia.swift`
- Create: `Sources/RecorderApp/Media/RecordingTimeline.swift`
- Create: `Sources/RecorderApp/Media/VideoGate.swift`
- Create: `Sources/RecorderApp/Media/VideoFrameSurface.swift`
- Test: `Tests/RecorderAppTests/RecordingTimelineTests.swift`
- Test: `Tests/RecorderAppTests/VideoGateTests.swift`
- Test: `Tests/RecorderAppTests/VideoFrameSurfaceTests.swift`

**Interfaces:**

```swift
enum RecordingMediaKind: String, Codable, Hashable, Sendable {
    case audio
    case video
}

struct RecordedScreenInterval: Codable, Equatable, Hashable, Sendable {
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
}

struct RecordedTeamsWindowIdentity: Codable, Equatable, Hashable, Sendable {
    let processID: pid_t
    let windowID: CGWindowID
    let title: String
}

enum RecordingRecoveryState: String, Codable, Hashable, Sendable {
    case none
    case videoLostAudioPreserved
    case recoveredAfterInterruption
}

struct TimedMixedAudioBlock: Equatable {
    let block: MixedAudioBlock
    let presentationTime: CMTime
}

enum VideoTimestampDecision: Equatable {
    case pending
    case append(CMTime)
    case dropDuplicate
    case dropBackward
    case dropFarFuture
}

struct RecordingTimeline {
    mutating func mapAudio(_ block: MixedAudioBlock) -> TimedMixedAudioBlock
    mutating func mapVideo(_ sourcePTS: CMTime) -> VideoTimestampDecision
    mutating func establishVideoAnchor(at sourcePTS: CMTime)
    var currentAudioEndTime: CMTime { get }
}

enum VideoGateAction: Equatable {
    case appendBlack(CMTime)
    case appendReal(CMTime)
    case drop
}
```

Timeline rules:

- first mixed audio establishes the normal source anchor;
- the media coordinator holds at most ten early video frames or one second,
  whichever comes first;
- if audio has not arrived at that bound, the coordinator calls
  `establishVideoAnchor(at:)` with the earliest valid queued frame;
- convert source PTS to the 48 kHz frame scale before subtraction;
- accept monotonic video no more than two seconds beyond the later of current
  audio end or the last accepted video timestamp;
- reject duplicate, backward, and farther-future video PTS and increment separate counters;
- preserve mixed-audio source gaps as sparse MP4 presentation times without allocating gap-sized arrays;
- retain the current mixer regression contract: a one-hour sparse source jump does not make the mixer or fake writer allocate one hour of PCM, and health still reports the discontinuity.

Video gate rules:

- emit one black frame at time zero;
- screen intent off drops real frames;
- first accepted real frame opens an interval;
- disable, unavailable source, stale revision, or 1.5 seconds without a complete frame closes the interval and emits one black frame at current audio time;
- a later valid frame reopens a new interval;
- finish closes an open interval, emits a final black frame before the audio end when needed, and lets the writer call `endSession(atSourceTime:)` at exact audio duration.

- [ ] **Step 1: Write failing timeline tests**

```swift
func testFirstMixedAudioAnchorsSessionAtZero()
func testEarlyVideoIsBoundedUntilAudioAnchorExists()
func testVideoCanAnchorAfterOneSecondWithoutAudio()
func testAudioGapUsesSparsePresentationTimeWithoutAllocatingSilence()
func testDuplicateBackwardAndFarFutureVideoPTSIsRejected()
func testAudioEndTimeUsesStartFramePlusFrameCount()
```

- [ ] **Step 2: Write failing gate and surface tests**

```swift
func testGateStartsWithBlackAndDropsFramesWhileOff()
func testEnableDisableReenableCreatesTwoIntervals()
func testStallClosesIntervalAndHoldsBlack()
func testStaleFilterRevisionCannotEnterRecording()
func testFinishExtendsVideoTrackToAudioDuration()
func testAspectFitPreservesWideAndTallSources()
func testBlackNV12AndBGRABuffersAre1600By900()
```

- [ ] **Step 3: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingTimelineTests|VideoGateTests|VideoFrameSurfaceTests'
```

- [ ] **Step 4: Implement the pure timeline/gate and fixed surfaces**

Use integer 48 kHz frames for comparisons and convert to `CMTime` only at output boundaries. `VideoFrameSurface` creates black NV12 by filling Y with video-range black and UV with neutral chroma; BGRA fallback fills opaque black. Assert even dimensions for NV12.

- [ ] **Step 5: Verify GREEN and preserve mixer regressions**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingTimelineTests|VideoGateTests|VideoFrameSurfaceTests|TimestampedAudioMixerTests'
```

- [ ] **Step 6: Commit**

```bash
git add Sources/RecorderApp/RecordingMedia.swift \
  Sources/RecorderApp/Media/RecordingTimeline.swift \
  Sources/RecorderApp/Media/VideoGate.swift \
  Sources/RecorderApp/Media/VideoFrameSurface.swift \
  Tests/RecorderAppTests/RecordingTimelineTests.swift \
  Tests/RecorderAppTests/VideoGateTests.swift \
  Tests/RecorderAppTests/VideoFrameSurfaceTests.swift
git commit -m "Add synchronized recording timeline"
```

---

### Task 5: HEVC/AAC Muxed Media Writer

**Files:**
- Modify: `Package.swift`
- Create: `Sources/RecorderApp/Media/MuxedMediaWriter.swift`
- Test: `Tests/RecorderAppTests/MuxedMediaWriterIntegrationTests.swift`

**Interfaces:**

```swift
struct MuxedMediaProfile: Equatable, Sendable {
    let width: Int
    let height: Int
    let maximumFramesPerSecond: Int
    let videoBitRate: Int
    let audioBitRate: Int
    let pixelFormat: OSType

    static func production(pixelFormat: OSType) -> MuxedMediaProfile {
        MuxedMediaProfile(
            width: 1_600,
            height: 900,
            maximumFramesPerSecond: 10,
            videoBitRate: 1_200_000,
            audioBitRate: 128_000,
            pixelFormat: pixelFormat
        )
    }
}

protocol MuxedMediaWriting: AnyObject {
    func appendAudio(_ block: TimedMixedAudioBlock) throws
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws
    func finish(at audioEndTime: CMTime) async throws
}
```

- [ ] **Step 1: Write failing production-settings tests**

Assert `.mp4`, `AVVideoCodecType.hevc`, 1600 x 900, 1.2 Mbps, expected
frame-rate key, a VideoToolbox hardware-acceleration preference that does not
require hardware, AAC 48 kHz stereo at 128 kbps, and all inputs configured
before `startWriting()`.

```swift
func testProductionDimensionsFrameRateAndBitratesAreStable()
func testProductionSettingsPreferButDoNotRequireHardwareHEVC()
```

- [ ] **Step 2: Write failing synthetic integration tests**

Build deterministic PCM and black/colored pixel buffers for:

- audio starting before the first real screen frame;
- never-enabled screen capture;
- two enabled intervals;
- a source-size change already normalized to the fixed canvas;
- dropped video frames;
- screen disabled at stop;
- temporary audio-input backpressure followed by recovery;
- audio FIFO pressure exceeding five seconds.

The backpressure cases must include:

```swift
func testTemporaryAudioBackpressureRecoversWithoutDroppedSamples()
func testAudioFIFOOverflowReturnsTypedTerminalMuxFailure()
func testFinishTimesOutWhenAudioFIFOCannotDrain()
```

Inspect each output with `AVURLAsset` and `AVAssetReader`. Assert one AAC audio track, one HEVC video track, 1600 x 900 production dimensions, no video rate above 10 fps, monotonic sample PTS, seekable media, and A/V end-time difference at or below 100 ms.

- [ ] **Step 3: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter MuxedMediaWriterIntegrationTests
```

- [ ] **Step 4: Implement AVAssetWriter and PCM sample-buffer creation**

Create both inputs before writing, set `expectsMediaDataInRealTime = true`, start the asset writer at session time zero, and append the initial black frame from `VideoGate`.

Link VideoToolbox and set
`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder` to true.
Do not set the corresponding require-hardware key; software fallback must remain
possible.

Convert each non-interleaved Float32 `MixedAudioBlock` into a retained
`CMSampleBuffer` whose PTS is `TimedMixedAudioBlock.presentationTime`. Do not
flatten `startFrame` gaps into callback arrival order.

When video input is not ready, throw a typed droppable-video result. For audio,
retain at most five seconds of timestamped sample buffers in a bounded FIFO and
drain it with `requestMediaDataWhenReady(on:)`; a temporary
`isReadyForMoreMediaData == false` is normal flow control and must not fail the
mux. Throw a terminal mux error only when the writer reports `.failed`, FIFO
duration exceeds five seconds, or the FIFO cannot drain before a ten-second
finalization timeout. This lets the coordinator latch into safety-audio mode
without dropping audio silently.

At finish:

1. append the gate's final black frame;
2. call `endSession(atSourceTime: audioEndTime)`;
3. mark both inputs finished;
4. await `finishWriting()`;
5. require `.completed` and a reopenable asset with both tracks.

- [ ] **Step 5: Verify GREEN**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter MuxedMediaWriterIntegrationTests
```

- [ ] **Step 6: Commit**

```bash
git add Package.swift \
  Sources/RecorderApp/Media/MuxedMediaWriter.swift \
  Tests/RecorderAppTests/MuxedMediaWriterIntegrationTests.swift
git commit -m "Add HEVC AAC media writer"
```

---

### Task 6: Safety Audio, Bounded Coordinator, and Atomic Fallback

**Files:**
- Modify: `Sources/RecorderApp/MixedAudioWriter.swift`
- Create: `Sources/RecorderApp/Media/RecordingMediaCoordinator.swift`
- Modify: `Tests/RecorderAppTests/MixedAudioWriterTests.swift`
- Test: `Tests/RecorderAppTests/RecordingMediaCoordinatorTests.swift`

**Interfaces:**

```swift
struct RecordingOutputURLs: Equatable {
    let folder: URL
    let partialMP4: URL
    let finalMP4: URL
    let audioBackup: URL
    let recoveredM4A: URL
}

struct RecordingMediaOutcome: Equatable {
    let finalURL: URL
    let mediaKind: RecordingMediaKind
    let screenIntervals: [RecordedScreenInterval]
    let capturedWindow: RecordedTeamsWindowIdentity?
    let recoveryState: RecordingRecoveryState
    let videoDroppedFrames: Int
    let videoFailureDescription: String?
}

enum RecordingVideoEventKind: Equatable, Sendable {
    case sourceStalled
    case sourceRecovered
    case droppedFrames(Int)
    case muxFailed(String)
}

struct RecordingVideoEvent: Equatable, Sendable {
    let sourceSessionID: UUID
    let recordingEpoch: UInt64
    let kind: RecordingVideoEventKind
}

protocol RecordingMediaCoordinating: AnyObject {
    func setVideoEventHandler(
        _ handler: (@Sendable (RecordingVideoEvent) -> Void)?
    )
    func enqueueAudio(_ block: MixedAudioBlock)
    func enqueueVideo(_ frame: ScreenVideoFrame)
    func setScreenCaptureRequested(
        _ requested: Bool,
        expectedRevision: CaptureFilterRevision?,
        window: RecordedTeamsWindowIdentity?
    )
    func markScreenSourceUnavailable()
    func finish() async throws -> RecordingMediaOutcome
}
```

- [ ] **Step 1: Write failing AAC bitrate tests**

Add tests requiring `AACMixedAudioWriter.init(url:bitRate:)`, a default of
192 kbps, explicit 128 kbps settings, and a typed error for a non-positive
bitrate.

- [ ] **Step 2: Verify the AAC tests are RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter MixedAudioWriterTests
```

Expected: compilation fails because the bitrate initializer does not exist.

- [ ] **Step 3: Implement configurable AAC and verify GREEN**

Add `AACMixedAudioWriter.init(url:bitRate:)` with a default of 192 kbps so old
direct callers preserve behavior. Validate a positive bitrate. Safety creation
explicitly passes 128 kbps.

Run the Step 2 command. Expected: old 192 kbps and new 128 kbps tests pass.

- [ ] **Step 4: Write failing coordinator/fallback tests**

```swift
func testSuccessfulFinishPromotesPartialMP4AndDeletesBackup()
func testNeverEnabledScreenStillProducesFinalMP4()
func testDroppableVideoBackpressureKeepsAudioAndCountsDrop()
func testMuxFailureLatchesOnceAndContinuesSafetyAudio()
func testFailedMuxPromotesBackupToRecordingM4A()
func testFailedMuxRetainsPartialMP4AsRecoveryArtifact()
func testSafetyFailureIsReportedWithoutDeletingValidMP4()
func testVideoIngressHoldsAtMostTwoPendingFrames()
func testProducerFloodSchedulesOneDrainAndRetainsAtMostTwoPixelBuffers()
func testTemporaryMuxAudioBackpressureDoesNotTriggerFallback()
func testVideoStallAndRecoveryEmitLiveEvents()
func testVideoEventsCarrySourceSessionAndRecordingEpoch()
func testClearedEventHandlerReceivesNoDelayedEvents()
func testFinishDrainsQueuedAudioBeforeClosingWriters()
```

- [ ] **Step 5: Verify coordinator tests are RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter RecordingMediaCoordinatorTests
```

Expected: compilation fails because `RecordingMediaCoordinator` and its output
contracts do not exist.

- [ ] **Step 6: Implement the serial coordinator**

Use one private dispatch queue for timeline, gate, and both writers. Public
enqueue methods return immediately. Before dispatching any closure, offer video
to a lock-protected latest-frame mailbox with capacity two. The mailbox
schedules at most one drain job; a producer flood replaces the older retained
frame rather than placing one closure and `CVPixelBuffer` on the dispatch queue
per callback. Audio enqueue is never discarded by video pressure.

For each audio block:

1. write the 128 kbps safety AAC first;
2. map the block through `RecordingTimeline`;
3. advance stall detection using the audio end time;
4. append gate actions and audio to the mux writer while it remains healthy.

Latch the first terminal mux failure, stop sending it additional samples, and
continue the safety writer. A single droppable video-backpressure error does not
latch the mux.

Emit live `RecordingVideoEvent` values on a dedicated event queue when the gate
enters or recovers from its 1.5-second stall, when drop counts change, and when
the mux latches a terminal failure. Every event carries the coordinator's source
session ID and recording epoch. The handler is clearable and never calls the
existing audio `CaptureEvent` path.

Normal finalization:

1. drain queued work;
2. finalize and validate `recording.partial.mp4`;
3. use same-directory POSIX `rename` to promote it to `recording.mp4`;
4. close and delete `recording.audio-backup.m4a`;
5. return `.none` recovery state.

Fallback finalization:

1. close and validate the backup with `AVAudioFile`;
2. use same-directory `rename` to promote it to `recording.m4a`;
3. retain `recording.partial.mp4`;
4. return `.videoLostAudioPreserved`.

If both the mux and safety writer fail, throw a typed finalization error; never
return an outcome whose `finalURL` does not exist.

- [ ] **Step 7: Verify focused tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingMediaCoordinatorTests|MixedAudioWriterTests|MuxedMediaWriterIntegrationTests'
```

- [ ] **Step 8: Commit**

```bash
git add Sources/RecorderApp/MixedAudioWriter.swift \
  Sources/RecorderApp/Media/RecordingMediaCoordinator.swift \
  Tests/RecorderAppTests/MixedAudioWriterTests.swift \
  Tests/RecorderAppTests/RecordingMediaCoordinatorTests.swift
git commit -m "Add recording media fallback pipeline"
```

---

### Task 7: Backward-Compatible Session Schema, Library, and Recovery

**Files:**
- Modify: `Sources/RecorderApp/RecordingLibrary.swift`
- Modify: `Sources/RecorderApp/RecordingSession.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Create: `Sources/RecorderApp/Recovery/IncompleteSessionRecovery.swift`
- Modify: `Tests/RecorderAppTests/RecordingLibraryTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelMuteTests.swift`
- Test: `Tests/RecorderAppTests/IncompleteSessionRecoveryTests.swift`

**Schema:**

```swift
struct RecordingSessionMetadata: Codable, Equatable, Hashable {
    var title: String?
    var tags: [String]
    var isFavorite: Bool
    var mediaKind: RecordingMediaKind
    var screenIntervals: [RecordedScreenInterval]
    var capturedTeamsWindow: RecordedTeamsWindowIdentity?
    var recoveryState: RecordingRecoveryState
}
```

Implement custom `init(from:)` with `decodeIfPresent` defaults:
`.audio`, `[]`, `nil`, and `.none`.

- [ ] **Step 1: Write failing schema and discovery tests**

Cover old JSON retaining title/tags/favorite, MP4 precedence over M4A, exact
final filenames, ignoring `recording.partial.mp4` and
`recording.audio-backup.m4a`, audio-only MP4 based on empty intervals, video MP4
based on non-empty intervals, legacy M4A, manual imported formats, and
`AppModel.saveMetadata` preserving media kind, intervals, window identity, and
recovery state while changing title/tags/favorite.

- [ ] **Step 2: Write failing recovery tests**

Cover valid backup promotion, invalid backup retention, partial MP4 retention,
existing final media winning, idempotent second launch, no overwrite, and
recovery metadata.

- [ ] **Step 3: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingLibraryTests|IncompleteSessionRecoveryTests'
```

- [ ] **Step 4: Implement exact final-file precedence**

`RecordingSessionStore.recordingURL(in:)` checks:

1. exact `recording.mp4`;
2. exact `recording.m4a`;
3. exact `recording.<manual-audio-extension>`.

Do not broaden manual import extensions. `RecordingSession` retains
`recordingURL` for compatibility and adds media kind, intervals, and recovery
state projected from metadata.

- [ ] **Step 5: Run recovery before library discovery**

`IncompleteSessionRecovery.recover(in:)` scans only supported session folders.
It validates a backup before promoting it, never deletes a partial MP4, never
overwrites final media, and writes `.recoveredAfterInterruption`.

The default AppModel library loader calls recovery once on its existing
background library queue before `RecordingSessionStore.load(from:)`.

Change `AppModel.saveMetadata` to copy and mutate the session's existing metadata
instead of constructing a new three-field value. This prevents user edits from
erasing capture and recovery fields.

- [ ] **Step 6: Verify GREEN and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingLibraryTests|IncompleteSessionRecoveryTests|ManualTranscriptionImporterTests|AppModelMuteTests'
git add Sources/RecorderApp/RecordingLibrary.swift \
  Sources/RecorderApp/RecordingSession.swift \
  Sources/RecorderApp/AppModel.swift \
  Sources/RecorderApp/Recovery/IncompleteSessionRecovery.swift \
  Tests/RecorderAppTests/RecordingLibraryTests.swift \
  Tests/RecorderAppTests/AppModelMuteTests.swift \
  Tests/RecorderAppTests/IncompleteSessionRecoveryTests.swift
git commit -m "Add MP4 library and audio recovery"
```

---

### Task 8: RecordingEngine Media and Screen-State Integration

**Files:**
- Modify: `Sources/RecorderApp/RecordingEngine.swift`
- Modify: `Sources/RecorderApp/RecordingModels.swift`
- Modify: `Tests/RecorderAppTests/RecordingEngineStateTests.swift`
- Modify: `Tests/RecorderAppTests/CaptureStatusTests.swift`

**Interfaces:**

```swift
enum MeetingScreenCaptureState: Equatable {
    case unavailable
    case off
    case ready(TeamsWindowDescriptor)
    case waiting([TeamsWindowDescriptor])
    case capturing(TeamsWindowDescriptor)
    case failed(String)
}

struct RecordingResult: Equatable {
    let folderURL: URL
    let recordingURL: URL
    let health: RecordingHealthReport
    let mediaKind: RecordingMediaKind
    let screenIntervals: [RecordedScreenInterval]
    let recoveryState: RecordingRecoveryState
}
```

`RecordingHealthReport` adds video dropped-frame, invalid-timestamp, stall,
filter-failure, and mux-fallback counters.

- [ ] **Step 1: Update fakes and write failing engine tests**

```swift
func testNewRecordingRequestsPartialMP4AndAudioBackupURLs()
func testEveryNewRecordingResetsScreenIntentToOff()
func testVideoCallbackNeverUsesMixedAudioWriterPath()
func testVideoIngressRejectsMonitoringAndStaleRecordingEpochFrames()
func testVideoIngressForwardsWithoutMainActorHop()
func testEnableScreenUpdatesFilterWithoutRestartingSourceOrWriter()
func testDisableScreenKeepsAudioAndReturnsToApplicationFilter()
func testWindowReplacementPreservesSessionEpochAndMute()
func testScreenFailureDoesNotDisconnectSystemOrMicrophone()
func testVideoStallShowsWaitingWithoutDisconnectingAudio()
func testRecoveredVideoReturnsToCapturingState()
func testMuxFailureShowsScreenFailureWhileSafetyAudioContinues()
func testDelayedVideoEventFromPriorEpochCannotChangeNewRecordingState()
func testStopDrainsCallbacksFlushesMixerThenFinalizesCoordinator()
func testFallbackResultReturnsRecordingM4AAndRecoveryState()
func testRecordingMetadataPersistsIntervalsAndWindowIdentity()
```

- [ ] **Step 2: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter RecordingEngineStateTests
```

- [ ] **Step 3: Replace the recording writer seam**

Inject a `RecordingMediaCoordinatorFactory` instead of
`MixedAudioWriterFactory`. At start create:

- `recording.partial.mp4`;
- `recording.mp4`;
- `recording.audio-backup.m4a`;
- `recording.m4a`.

Build `MuxedMediaProfile.production(pixelFormat:)` from the active source's
`screenVideoFormat`; this keeps initial/final black frames in NV12 during the
preferred path and BGRA when ScreenCaptureKit used its startup fallback.

Keep monitoring and virtual-microphone behavior unchanged. Audio still reaches
the existing mixer on `@MainActor`, then enqueues mixed blocks to the media
coordinator. Screen callbacks only retain/enqueue a frame to the coordinator's
bounded video lane and return.

Add a `nonisolated` lock-protected video ingress owned by `RecordingEngine`.
Activate it with source session ID, recording epoch, and coordinator only after
recording start succeeds. The source's video callback validates its callback
ticket and forwards directly through this ingress; it must not create one
main-actor task per frame. Deactivate it during stop after the callback gate
reaches idle so monitoring frames and stale prior-session frames are dropped.

Install the coordinator's `RecordingVideoEvent` handler at creation. Dispatch
events to `@MainActor`, then require both source session ID and recording epoch
to match before updating `MeetingScreenCaptureState` or video health counters.
Clear the handler after finalization. Stalled, recovered, and mux-failed event
kinds must never call `disconnectSystemCapture()` or
`disconnectMicrophoneCapture()`.

- [ ] **Step 4: Add resolver and toggle orchestration**

Expose:

```swift
func refreshTeamsWindows(
    meetingActive: Bool,
    manualOverride: TeamsWindowIdentity?
) async
func setScreenCaptureRequested(_ requested: Bool) async
```

Enabling sets the gate intent, applies the resolved window filter, then accepts
only its returned revision. Disabling closes the gate before restoring the
application filter. A waiting/ambiguous result restores the application filter,
keeps intent true, and holds black until a high-confidence or manual window is
available.

- [ ] **Step 5: Preserve stop ordering and write metadata**

Stop order:

1. stop source callbacks and wait for callback-gate idle;
2. flush the timestamp mixer;
3. enqueue the final mixed blocks;
4. finalize the media coordinator;
5. save media metadata;
6. clear session state.

- [ ] **Step 6: Run engine, mute, and native-capture regressions**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingEngineStateTests|CaptureStatusTests|TimestampedAudioMixerTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'AppModelMuteTests|TeamsMuteSyncTests|VirtualMicPublisherTests|NativeAudioCaptureHardeningTests'
```

Expected: all selected tests pass; mute still silences both the recording mix and virtual mic while Teams participant audio/video continue.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderApp/RecordingEngine.swift \
  Sources/RecorderApp/RecordingModels.swift \
  Tests/RecorderAppTests/RecordingEngineStateTests.swift \
  Tests/RecorderAppTests/CaptureStatusTests.swift
git commit -m "Integrate screen capture recording state"
```

---

### Task 9: Selected-Volume Storage Policy

**Files:**
- Create: `Sources/RecorderApp/Storage/RecordingStoragePolicy.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Test: `Tests/RecorderAppTests/RecordingStoragePolicyTests.swift`
- Test: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`

**Policy:**

```swift
enum RecordingStorageDecision: Equatable {
    case normal
    case warn
    case audioOnly
    case stop
}

struct RecordingStoragePolicy {
    static let warningBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    static let videoMinimumBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    static let audioStopBytes: Int64 = 256 * 1_024 * 1_024

    func decision(availableBytes: Int64) -> RecordingStorageDecision
}

protocol VolumeCapacityProviding {
    func availableBytes(onVolumeContaining url: URL) throws -> Int64
}
```

The 256 MB audio stop threshold is injectable in tests and is the concrete
implementation value for the design's audio safety threshold.

- [ ] **Step 1: Write failing threshold and selected-volume tests**

Test exact boundaries, the selected output volume URL, under-1-GB video refusal,
under-256-MB recording refusal/stop, and a capacity provider error that warns but
does not silently stop a healthy recording.

- [ ] **Step 2: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter RecordingStoragePolicyTests
```

- [ ] **Step 3: Implement preflight and a 15-second runtime check**

Before start:

- below 5 GB: show warning;
- below 1 GB: allow audio recording but disable the screen toggle;
- below 256 MB: refuse a new recording with an explicit message.

During recording, AppModel checks the selected output volume every 15 seconds:

- below 1 GB: call `setScreenCaptureRequested(false)`, preserve audio, and report why;
- below 256 MB: invoke the normal stop lifecycle so writers finalize safely.

Capacity checks run on a utility queue, never a capture callback.

- [ ] **Step 4: Verify GREEN and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingStoragePolicyTests|AppModelScreenCaptureTests'
git add Sources/RecorderApp/Storage/RecordingStoragePolicy.swift \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/RecordingStoragePolicyTests.swift \
  Tests/RecorderAppTests/AppModelScreenCaptureTests.swift
git commit -m "Add recording storage safeguards"
```

---

### Task 10: MP4 Transcription Audio Preparation

**Files:**
- Create: `Sources/RecorderApp/Transcription/TranscriptionAudioPreparer.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Test: `Tests/RecorderAppTests/TranscriptionAudioPreparerTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelMuteTests.swift`

**Interfaces:**

```swift
struct PreparedTranscriptionAudio: Equatable {
    let audioURL: URL
    let cleanupURL: URL?
}

protocol TranscriptionAudioPreparing {
    func prepare(for session: RecordingSession) async throws
        -> PreparedTranscriptionAudio
    func cleanup(_ prepared: PreparedTranscriptionAudio)
}
```

- [ ] **Step 1: Write failing preparer tests**

Cover pass-through for M4A/manual audio, extraction from a synthetic MP4,
reopenable AAC output, unique temporary names, no modification of the session
folder, cleanup after success, cleanup after export failure, and cleanup after
cancellation.

- [ ] **Step 2: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter TranscriptionAudioPreparerTests
```

- [ ] **Step 3: Implement AVFoundation extraction**

For MP4, require one audio track and use `AVAssetExportPresetAppleM4A` to export
to a UUID-named temporary M4A. Bridge exporter completion to async/await and call
`cancelExport()` when the task is cancelled. `cleanup` is idempotent.

- [ ] **Step 4: Make AppModel own the complete transcription task**

Wrap prepare, shell launch, process completion, and cleanup in one cancellable
task. Use `defer` to delete only `cleanupURL`. Continue passing the prepared
audio URL and existing output folder to `transcribe-qwen-asr.sh`; do not change
the script's public contract.

`cancelTranscription()` cancels extraction when no `Process` exists yet and
terminates the process once launched.

- [ ] **Step 5: Verify focused and regression tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'TranscriptionAudioPreparerTests|AppModelMuteTests|RecordingLibraryTests'
```

- [ ] **Step 6: Commit**

```bash
git add Sources/RecorderApp/Transcription/TranscriptionAudioPreparer.swift \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/TranscriptionAudioPreparerTests.swift \
  Tests/RecorderAppTests/AppModelMuteTests.swift
git commit -m "Add MP4 transcription audio extraction"
```

---

### Task 11: Unified AVPlayer Playback

**Files:**
- Modify: `Package.swift`
- Create: `Sources/RecorderApp/Playback/PlaybackCoordinator.swift`
- Create: `Sources/RecorderApp/Views/RecordingPlaybackView.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Test: `Tests/RecorderAppTests/PlaybackCoordinatorTests.swift`
- Test: `Tests/RecorderAppTests/AppModelPlaybackTests.swift`

**Interfaces:**

```swift
struct PlaybackSnapshot: Equatable {
    let sessionID: RecordingSession.ID?
    let progress: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
}

@MainActor
protocol PlaybackCoordinating: AnyObject {
    var player: AVPlayer { get }
    var onSnapshot: ((PlaybackSnapshot) -> Void)? { get set }
    func load(_ session: RecordingSession) async throws
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    func stop()
}
```

- [ ] **Step 1: Write failing coordinator and AppModel tests**

Cover M4A and MP4 loading, play, pause, seek clamping, stop reset, item
completion, observer cleanup on replacement/deinit, and the 10-second test
recording using the same coordinator path as library playback.

- [ ] **Step 2: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'PlaybackCoordinatorTests|AppModelPlaybackTests'
```

- [ ] **Step 3: Implement AVPlayer lifecycle**

Use a 100 ms periodic time observer, one item-end notification, async duration
loading, and explicit observer removal before replacing an item, on stop, and in
deinit. AppModel injects `PlaybackCoordinating` and removes both direct
`AVAudioPlayer` code paths.

- [ ] **Step 4: Add compact and video playback views**

Add AVKit to Package.swift. `RecordingPlaybackView` shows:

- `VideoPlayer` only when `session.screenIntervals` is non-empty;
- compact icon controls for legacy audio and audio-only MP4;
- play/pause, stop, draggable timeline, current time, and duration in both modes.

Do not infer presentation from MP4 extension or video-track presence; an
audio-only MP4 intentionally contains a black video track.

- [ ] **Step 5: Verify GREEN and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'PlaybackCoordinatorTests|AppModelPlaybackTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
git add Package.swift \
  Sources/RecorderApp/Playback/PlaybackCoordinator.swift \
  Sources/RecorderApp/Views/RecordingPlaybackView.swift \
  Sources/RecorderApp/AppModel.swift Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/PlaybackCoordinatorTests.swift \
  Tests/RecorderAppTests/AppModelPlaybackTests.swift
git commit -m "Add unified audio video playback"
```

---

### Task 12: Teams Screen Controls, Resolver Refresh, and Status UI

**Files:**
- Create: `Sources/RecorderApp/Views/TeamsScreenCaptureControlsView.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Modify: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`
- Modify: `Tests/RecorderAppTests/TeamsMuteSyncTests.swift`

**User-visible states:**

```swift
enum TeamsScreenStatusText {
    static let off = "Screen off"
    static let ready = "Teams window ready"
    static let capturing = "Capturing Teams window"
    static let waiting = "Waiting for Teams window"
    static let unavailable = "Screen capture unavailable"
}
```

- [ ] **Step 1: Write failing AppModel state tests**

```swift
func testControlsAppearOnlyForSelectedTeamsApplication()
func testEveryRecordingStartsWithScreenOff()
func testTeamsMeetingEventIsForwardedToWindowResolver()
func testResolverRefreshesEverySecondWhileRecordingOrRequested()
func testAmbiguityShowsWaitingAndDoesNotCaptureEitherWindow()
func testManualSelectionEnablesRequestedCapture()
func testReplacementWindowUpdatesWithoutWriterRestart()
func testSourceChangeBeforeRecordingClearsManualOverride()
func testLowStorageDisablesToggleButKeepsAudioStartEnabled()
```

- [ ] **Step 2: Verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter AppModelScreenCaptureTests
```

- [ ] **Step 3: Add AppModel refresh lifecycle**

Retain the current Teams `inMeeting` boolean from `TeamsMuteSyncEvent` and pass
it to the resolver without changing mute relay behavior. Perform one immediate
window refresh when Teams becomes the selected source. While recording or while
screen intent is requested, run one cancellable refresh every second. Cancel it
on stop, source change, or deinit.

Manual choices use `TeamsWindowIdentity(processID:windowID:)` and are scoped to
the current Teams process only.

- [ ] **Step 4: Build the screen controls**

Use an icon toggle for screen on/off, a status icon/text, and a Menu for manual
window correction. Show the selected title with middle truncation. Disable the
toggle before recording because every session must begin off; keep readiness and
manual selection visible before recording. Do not add a persistent preview.

Display exactly the approved state strings. For an ambiguous or missing window,
keep screen intent on, display waiting, and record black until a valid choice
appears.

Update footer wording from `recording.m4a` to one combined `recording.mp4`, with
a recovered-audio note shown only when the result is M4A.

- [ ] **Step 5: Run UI-model and mute regressions**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'AppModelScreenCaptureTests|TeamsMuteSyncTests|AppModelMuteTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

- [ ] **Step 6: Commit**

```bash
git add Sources/RecorderApp/Views/TeamsScreenCaptureControlsView.swift \
  Sources/RecorderApp/AppModel.swift Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/AppModelScreenCaptureTests.swift \
  Tests/RecorderAppTests/TeamsMuteSyncTests.swift
git commit -m "Add Teams screen capture controls"
```

---

### Task 13: Cumulative Regression, Media Inspection, and Independent Review

**Files:**
- Modify only files required by validated review findings.

- [ ] **Step 1: Run formatting and full automated verification**

```bash
git diff --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: zero whitespace errors, zero test failures, and a successful debug build.

- [ ] **Step 2: Inspect a production-profile synthetic MP4**

Run the integration fixture that writes 60 seconds of audio with two real-screen
intervals. Record:

- audio/video codec subtypes;
- 1600 x 900 dimensions;
- nominal and observed frame rate;
- audio/video durations;
- file size and projected MB/hour;
- seek test at the beginning, middle, and each interval boundary.

Expected: HEVC/AAC, no more than 10 fps, A/V end difference at or below 100 ms,
and projected continuous-video size near or below 600 MB/hour.

- [ ] **Step 3: Run an independent code review**

Use a fresh review subagent against the cumulative diff from the Task 1 baseline.
Require findings ordered by severity for:

- same-stream lifecycle and stale filter revisions;
- buffer ownership and queue bounds;
- audio callback isolation;
- AVAssetWriter finalization and sparse PTS;
- atomic promotion/recovery data loss;
- old metadata decoding;
- cancellation cleanup;
- AVPlayer observer leaks;
- storage-triggered stop races;
- missing failure tests.

Do not accept a clean worktree or passing tests as review evidence.

- [ ] **Step 4: Fix validated findings with RED-to-GREEN evidence**

For each accepted finding, add a failing regression test first, make the smallest
fix, rerun the focused test, then rerun the full suite.

- [ ] **Step 5: Commit review fixes if any**

For each accepted finding, stage only the exact source and regression-test paths
named by that finding, verify `git diff --cached --check`, and commit:

```bash
git commit -m "Harden Teams screen capture pipeline"
```

Do not use a repository-wide `git add`. Skip the commit only when the independent
review produces no accepted code changes.

---

### Task 14: Build, Install, and Live Acceptance

**Files:**
- Create: `docs/testing/2026-07-26-teams-screen-capture-acceptance.md`
- Modify production/test files only when live evidence exposes a defect.

- [ ] **Step 1: Build and install one candidate**

```bash
scripts/build-app.sh
scripts/install-app.sh
codesign --verify --deep --strict --verbose=2 \
  "/Applications/Local Meeting Recorder.app"
open -a "/Applications/Local Meeting Recorder.app"
```

Expected: one installed Local Meeting Recorder candidate launches and preserves existing Screen/System Audio, microphone, Teams API, and virtual-mic permissions.

- [ ] **Step 2: Validate an audio-only MP4**

Keep screen off for the entire recording. Confirm:

- final output is only `recording.mp4`;
- temporary backup is gone;
- Teams audio and selected microphone are audible;
- compact playback, play/pause, stop, and seeking work;
- library labels it audio, not video;
- file size projects near 60 MB/hour.

- [ ] **Step 3: Validate mid-recording screen intervals**

Join Teams, begin recording with screen off, enable screen during a PowerPoint or
document share, disable it, re-enable it, and stop. Confirm black holds outside
captured intervals, full Teams meeting-window video inside them, uninterrupted
audio, one final MP4, and correct interval metadata.

- [ ] **Step 4: Validate window lifecycle**

While capturing, resize, occlude, move displays, minimize/restore, and pop out or
replace the Teams meeting window. Confirm automatic replacement only at high
confidence; otherwise the app explicitly waits for manual selection. The app
must never raise or unminimize Teams.

- [ ] **Step 5: Validate AirPods/Teams mute**

Use AirPods as Mac output and selected microphone. Mute and unmute from AirPods.
Confirm Teams and `Local Recorder Virtual Mic` follow the accepted mute behavior,
the recording mic becomes silence while muted, and participant audio plus screen
video continue.

- [ ] **Step 6: Validate playback and oMLX transcription**

Play and seek the MP4 at interval boundaries. Start oMLX transcription, confirm a
temporary M4A is created outside the session folder, and confirm it is removed
after success. Repeat with cancellation and confirm cleanup.

- [ ] **Step 7: Validate storage and fallback**

Run the deterministic acceptance fixtures immediately before the live soak:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecordingStoragePolicyTests|RecordingMediaCoordinatorTests|AppModelScreenCaptureTests'
```

Use their injected capacity provider to confirm the 5 GB warning, 1 GB video
disable with continuing audio, and 256 MB normal stop. Use the coordinator's
injected mux failure after several frames to inspect a playable
`recording.m4a`, retained partial MP4, explicit recovery state, and no deleted
sole valid media. Record fixture paths and assertions in the acceptance document.

- [ ] **Step 8: Run a 30-minute synchronization soak**

Record continuous Teams speech or a time-coded clip plus intermittent mic speech
and at least two screen intervals. Acceptance:

- no electrical ticks or repeated samples;
- no unexplained capture stop;
- no A/V drift above one 10 fps frame (100 ms);
- no unbounded memory growth;
- no dropped audio caused by video backpressure;
- file size remains within the storage profile.

- [ ] **Step 9: Close any live defect before continuing**

If live acceptance exposes a defect:

1. add a failing automated regression test that reproduces it;
2. make the smallest production fix;
3. run the focused test plus the full test/build commands from Task 13;
4. stage only the exact fix and regression-test paths;
5. run `git diff --cached --check`;
6. commit with `git commit -m "Fix Teams screen capture acceptance defect"`;
7. rebuild and reinstall the candidate;
8. rerun every affected acceptance step and the 30-minute soak when timing,
   audio continuity, memory, or writer lifecycle changed.

When no live defect is found, record this step as not applicable. Never proceed
with modified production/test files left unstaged or unverified.

- [ ] **Step 10: Document exact evidence**

Record date, app commit, installed app path, Teams/macOS versions, device choices,
session paths, media metadata, sizes, durations, drift measurement, health
counters, transcript path, recovery artifacts, and pass/fail for every check.

- [ ] **Step 11: Commit acceptance evidence**

```bash
git add docs/testing/2026-07-26-teams-screen-capture-acceptance.md
git commit -m "Validate Teams screen capture"
git status --short --branch
```

Expected: acceptance evidence is committed and the worktree is clean. Only then is the feature ready for branch completion.

---

## Execution Ordering

1. Task 1 is strictly serial and blocks all later work.
2. Tasks 2 and 3 establish the capture contract and must finish before media integration.
3. Tasks 4-8 are the core media path and should remain serial because they share timestamp and finalization contracts.
4. After Task 8, subagents may implement the isolated new units and their tests
   from Tasks 9, 10, and 11 in parallel, but they must not edit
   `AppModel.swift`. One integration owner then applies the three AppModel steps
   sequentially and reruns all three focused suites.
5. Task 12 integrates UI and runtime state after those lanes merge.
6. Tasks 13 and 14 are serial review and live-acceptance gates.

## Completion Contract

Implementation is complete only when:

- every task checkbox is backed by the named test or live evidence;
- Task 1 and Task 14 live gates pass on the installed app;
- the full Swift test suite and build pass;
- independent review findings are resolved or explicitly rejected with evidence;
- exact final commits and any intentionally uncommitted files are reported;
- the final worktree is clean.
