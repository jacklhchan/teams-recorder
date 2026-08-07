# Playback and Recordings Library UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved focused playback window and compact all-recordings library without adding an editor, thumbnail pipeline, or new persisted metadata.

**Architecture:** Keep the existing dedicated `PlaybackWindowController` and feature ownership. Add small pure presentation projections for deterministic time, grouping, filtering, sorting, and labels; SwiftUI views consume those projections while existing AppModel action closures retain canonical-session and lifecycle behavior.

**Tech Stack:** Swift 6, SwiftUI, AppKit, AVFoundation/AVKit, XCTest, Swift Package Manager.

## Global Constraints

- Work in `/Users/apple/Documents/recorder` on the user-approved `main` workflow; preserve unrelated untracked brainstorm, tutorial, assets, and UAT files.
- Follow strict RED → GREEN TDD for every production behavior.
- Use only focused Playback, Library query/presentation, AppModel playback, and recordings render tests; do not run the full suite.
- Do not add video-frame thumbnail extraction, thumbnail caching, persisted waveform generation, chapters, editing, transcript-in-player, cloud sync, or a metadata schema change.
- Do not claim persisted System Audio or Microphone capture health; the session model does not reliably store it.
- Keep playback outside the main workspace and keep one presenter pair owned by `ContentView`.
- Keep existing action identifiers stable for actions that still exist.
- The two unrelated baseline failures `testMicrophoneRefreshRemainsEnabledWhileRecording` and `testDirectionASettingsKeepsEveryExistingControlReachable` are outside this plan; do not modify Settings code or those assertions.

---

### Task 1: Focused Recording Playback Window

**Files:**
- Create: `Sources/RecorderApp/Views/RecordingPlaybackPresentation.swift`
- Modify: `Sources/RecorderApp/Views/RecordingPlaybackView.swift`
- Modify: `Sources/RecorderApp/Views/PlaybackWindow.swift`
- Modify: `Sources/RecorderApp/Playback/PlaybackCoordinator.swift`
- Modify: `Sources/RecorderApp/Playback/PlaybackFeatureModel.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Create: `Tests/RecorderAppTests/RecordingPlaybackPresentationTests.swift`
- Modify: `Tests/RecorderAppTests/PlaybackCoordinatorTests.swift`
- Modify: `Tests/RecorderAppTests/PlaybackFeatureModelTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelPlaybackTests.swift`

**Interfaces:**
- Consumes: `RecordingSession`, `PlaybackPresentationModel`, `PlaybackCoordinating`, and the existing `PlaybackWindowPresenting` lifecycle.
- Produces: `RecordingPlaybackPresentation`, `PlaybackFeatureModel.setVolume(_:)`, `PlaybackFeatureModel.setRate(_:)`, `AppModel.revealRecording(_:)`, and the redesigned standalone playback view.

- [ ] **Step 1: Write failing pure-presentation tests**

Create `RecordingPlaybackPresentationTests` covering elapsed/remaining formatting, clamped skip targets, factual badges, and video/audio sizing. The intended API is:

```swift
let presentation = RecordingPlaybackPresentation.make(
    session: session,
    progress: 61,
    duration: 125
)
XCTAssertEqual(presentation.elapsedText, "01:01")
XCTAssertEqual(presentation.remainingText, "-01:04")
XCTAssertEqual(presentation.skipBackwardTarget, 46)
XCTAssertEqual(presentation.skipForwardTarget, 76)
XCTAssertEqual(presentation.mediaLabel, "Video")
XCTAssertEqual(presentation.sourceLabel, "Teams automatic")
```

Also assert audio-only and recovery labels without mentioning system-audio or microphone health.

- [ ] **Step 2: Run the presentation tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-playback-ui-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-playback-ui-swiftpm \
swift test --disable-sandbox --filter RecordingPlaybackPresentationTests
```

Expected: compile failure because `RecordingPlaybackPresentation` does not exist.

- [ ] **Step 3: Implement the minimal pure presentation**

Create an immutable projection with the exact fields tested above and these rules:

```swift
struct RecordingPlaybackPresentation: Equatable {
    let title: String
    let detailText: String
    let elapsedText: String
    let remainingText: String
    let totalText: String
    let skipBackwardTarget: TimeInterval
    let skipForwardTarget: TimeInterval
    let mediaLabel: String
    let sourceLabel: String
    let recoveryLabel: String?
    let defaultContentSize: CGSize
    let minimumContentSize: CGSize

    static func make(
        session: RecordingSession,
        progress: TimeInterval,
        duration: TimeInterval
    ) -> Self
}
```

Clamp targets to `0...max(duration, 0)`. Use `HH:MM:SS` only when duration reaches one hour; otherwise use `MM:SS`. Use `session.metadata.source` and `session.recoveryState` directly.

- [ ] **Step 4: Write failing transport-control tests**

Extend coordinator and feature fakes first, then assert:

```swift
coordinator.setVolume(1.4)
XCTAssertEqual(player.volume, 1)
coordinator.setRate(1.5)
coordinator.play()
XCTAssertEqual(player.defaultRate, 1.5)
XCTAssertEqual(player.rate, 1.5)
```

At the feature layer, prove calls are ignored after shutdown and forwarded while a session is active. Update `AppModelPlaybackTests` presenter spy to require reveal, volume, and rate closures before production signatures change.

- [ ] **Step 5: Run transport tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-playback-ui-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-playback-ui-swiftpm \
swift test --disable-sandbox --filter 'PlaybackCoordinatorTests|PlaybackFeatureModelTests|AppModelPlaybackTests'
```

Expected: compile failures for the missing control methods and presenter closures.

- [ ] **Step 6: Implement minimal transport and reveal seams**

Extend `PlaybackCoordinating` with:

```swift
func setVolume(_ volume: Float)
func setRate(_ rate: Float)
```

`PlaybackCoordinator` clamps volume to `0...1`, accepts only `[0.5, 1, 1.25, 1.5, 2]` for rate, stores the selected rate, and uses it when playback starts. `PlaybackFeatureModel` forwards only while active and not shut down. `AppModel` forwards the two controls and exposes:

```swift
func revealRecording(_ session: RecordingSession) {
    NSWorkspace.shared.activateFileViewerSelecting([session.recordingURL])
}
```

Extend `PlaybackWindowPresenting.present` with `revealRecording`, `setVolume`, and `setRate` closures. `ContentView` supplies closures from the existing model and current presentation session; presenter ownership must not move.

- [ ] **Step 7: Redesign the SwiftUI playback view**

Replace the small card with the approved hierarchy:

```swift
VStack(spacing: 16) {
    metadataHeader
    mediaStage
    timeline
    transportControls
    metadataChips
}
```

Requirements:

- Video uses the existing native `VideoPlayer` with a rounded 16:9 stage.
- Audio-only uses a fixed, accessible waveform-symbol placeholder; do not synthesize waveform data.
- Overlay skip-back/play-pause/skip-forward controls are always keyboard reachable.
- The timeline shows elapsed and remaining values and retains the existing seek closure.
- Volume and rate controls call the injected closures.
- Space toggles playback; left/right arrow buttons expose 5-second keyboard shortcuts only when the window owns focus.
- Add stable identifiers under `recorder.playback.*` and meaningful accessibility labels.
- Header contains title/details and Show in Finder; factual chips show media, source, and optional recovery only.

Update window default/minimum sizing from `RecordingPlaybackPresentation` and keep `windowWillClose` stopping playback.

- [ ] **Step 8: Run focused playback GREEN tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-playback-ui-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-playback-ui-swiftpm \
swift test --disable-sandbox --filter 'RecordingPlaybackPresentationTests|PlaybackCoordinatorTests|PlaybackFeatureModelTests|AppModelPlaybackTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 9: Self-review and commit Task 1**

Run `git diff --check`, inspect only Task 1 files, then commit:

```bash
git add Sources/RecorderApp/Views/RecordingPlaybackPresentation.swift \
  Sources/RecorderApp/Views/RecordingPlaybackView.swift \
  Sources/RecorderApp/Views/PlaybackWindow.swift \
  Sources/RecorderApp/Playback/PlaybackCoordinator.swift \
  Sources/RecorderApp/Playback/PlaybackFeatureModel.swift \
  Sources/RecorderApp/AppModel.swift Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/RecordingPlaybackPresentationTests.swift \
  Tests/RecorderAppTests/PlaybackCoordinatorTests.swift \
  Tests/RecorderAppTests/PlaybackFeatureModelTests.swift \
  Tests/RecorderAppTests/AppModelPlaybackTests.swift
git commit -m "feat: refine recording playback UI"
```

---

### Task 2: Compact All-Recordings Library

**Files:**
- Create: `Sources/RecorderApp/UI/RecordingsLibraryPresentation.swift`
- Modify: `Sources/RecorderApp/UI/RecordingsLibraryView.swift`
- Create: `Tests/RecorderAppTests/RecordingsLibraryPresentationTests.swift`
- Modify: `Tests/RecorderAppTests/RecordingLibraryQueryTests.swift`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`

**Interfaces:**
- Consumes: `RecordingLibraryQuery`, `RecordingSession`, current transcription projections, canonical-session admission, and all current row action closures.
- Produces: deterministic library filter/sort/date sections and the compact grouped list UI.

- [ ] **Step 1: Write failing library-presentation tests**

Test one deterministic projection with sessions spanning today, yesterday, and a prior month. The intended API is:

```swift
let presentation = RecordingsLibraryPresentation.make(
    sessions: sessions,
    query: RecordingLibraryQuery(text: ""),
    filter: .all,
    sort: .newestFirst,
    now: now,
    calendar: calendar,
    hasTranscript: { transcriptIDs.contains($0.id) },
    transcriptionPhase: { phases[$0.id] }
)
XCTAssertEqual(presentation.itemCountText, "4 recordings")
XCTAssertEqual(presentation.sections.map(\.title), ["Today", "Yesterday", "July 2026"])
```

Add focused assertions for Favorites, Has transcript, Needs attention, Oldest first, total duration text, and stable empty results. `Needs attention` is recovery state not `.none` or transcription phase failed/cancelled/interrupted.

- [ ] **Step 2: Run presentation tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-library-ui-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-library-ui-swiftpm \
swift test --disable-sandbox --filter RecordingsLibraryPresentationTests
```

Expected: compile failure because the presentation types do not exist.

- [ ] **Step 3: Implement the minimal library projection**

Create:

```swift
enum RecordingLibraryFilter: String, CaseIterable, Identifiable {
    case all, favorites, hasTranscript, needsAttention
    var id: Self { self }
}

enum RecordingLibrarySort: String, CaseIterable, Identifiable {
    case newestFirst, oldestFirst
    var id: Self { self }
}

struct RecordingLibrarySection: Identifiable, Equatable {
    let id: String
    let title: String
    let sessions: [RecordingSession]
}

struct RecordingsLibraryPresentation: Equatable {
    let sections: [RecordingLibrarySection]
    let itemCountText: String
    let totalDurationText: String

    static func make(
        sessions: [RecordingSession],
        query: RecordingLibraryQuery,
        filter: RecordingLibraryFilter,
        sort: RecordingLibrarySort,
        now: Date,
        calendar: Calendar,
        hasTranscript: (RecordingSession) -> Bool,
        transcriptionPhase: (RecordingSession) -> TranscriptionState.Phase?
    ) -> Self
}
```

Use the supplied calendar and now for date grouping. The production call uses `.current` and `Date()`. Do not read files inside the projection; callers supply transcript existence and phases.

- [ ] **Step 4: Run pure presentation GREEN tests**

Run the same `RecordingsLibraryPresentationTests` filter and expect all tests to pass.

- [ ] **Step 5: Write failing compact-library render tests**

Replace the obsolete card-expansion assertion with focused render expectations:

- grouped row identifiers exist for video and audio sessions;
- each row exposes Play and More Actions;
- selecting exactly one row exposes Open Transcript only when available and Open Folder/Show in Finder equivalent;
- transcript-missing rows do not expose a misleading inline transcript action;
- the minimum recordings destination keeps the visible Play and More controls inside the window;
- light and dark appearance markers remain.

Run only the new/changed Recordings render tests and verify failures occur because compact row/filter identifiers are absent.

- [ ] **Step 6: Implement the compact grouped library**

Keep the current outer dependency wiring and replace the expandable-card body with:

```swift
VStack(spacing: 0) {
    librarySummaryHeader
    filterAndSortBar
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(presentation.sections) { section in
                Text(section.title)
                    .font(.headline)
                ForEach(section.sessions) { session in
                    recordingRow(session: session)
                }
            }
        }
    }
    libraryFooter
}
```

Use `@State` for selected session ID, `RecordingLibraryFilter`, and `RecordingLibrarySort`. Keep the existing `.searchable`, upload, refresh, route invalidation, sheets, and trash confirmation.

Each compact row must:

- use a deterministic video or audio symbol placeholder;
- show favorite state, display name, formatted date/time, duration, size, source/media chips, tags, transcript snippet, and current transcription status when present;
- use the existing canonical-session admission before every action;
- permanently expose only Play and a More Actions `Menu`;
- expose Open Transcript and Open Folder inline only for the selected row, with transcript disabled/absent accurately;
- keep Transcribe/Cancel, Edit, Transcript, ASR Log, Open Folder, and Trash inside the menu with current enablement;
- retain existing action identifiers or provide stable equivalent markers.

On library revision, clear a selected ID that no longer exists, matching the current stale expansion/route behavior.

- [ ] **Step 7: Run focused library GREEN tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-library-ui-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-library-ui-swiftpm \
swift test --disable-sandbox --filter 'RecordingsLibraryPresentationTests|RecordingLibraryQueryTests|RecorderWorkspaceRenderTests/testDirectionARecordings|RecorderWorkspaceRenderTests/testMinimumRecordings|RecorderWorkspaceRenderTests/testRecordings'
```

Expected: selected Library tests pass with zero failures. Do not run the two unrelated Settings render tests.

- [ ] **Step 8: Self-review and commit Task 2**

Run `git diff --check`, inspect only Task 2 files, then commit:

```bash
git add Sources/RecorderApp/UI/RecordingsLibraryPresentation.swift \
  Sources/RecorderApp/UI/RecordingsLibraryView.swift \
  Tests/RecorderAppTests/RecordingsLibraryPresentationTests.swift \
  Tests/RecorderAppTests/RecordingLibraryQueryTests.swift \
  Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git commit -m "feat: refine recordings library UI"
```

---

### Task 3: Focused Integration Verification and Acceptance Record

**Files:**
- Modify: `docs/testing/2026-08-08-playback-and-recordings-library-uat.md` (create if absent)

**Interfaces:**
- Consumes: Task 1 and Task 2 committed UI behavior.
- Produces: concise acceptance evidence; no product behavior.

- [ ] **Step 1: Run one combined focused verification**

Run once:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-saved-media-ui-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-saved-media-ui-swiftpm \
swift test --disable-sandbox --filter 'RecordingPlaybackPresentationTests|PlaybackCoordinatorTests|PlaybackFeatureModelTests|AppModelPlaybackTests|RecordingsLibraryPresentationTests|RecordingLibraryQueryTests|RecorderWorkspaceRenderTests/testDirectionARecordings|RecorderWorkspaceRenderTests/testMinimumRecordings|RecorderWorkspaceRenderTests/testRecordings'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 2: Build and perform bounded GUI acceptance**

Build one debug or release app using the repository script. Open the installed/test app through Computer Use and verify only:

1. Recordings shows compact grouped rows at normal and minimum supported width.
2. Search and one filter update visible rows.
3. Play opens one standalone window; video and audio-only layouts are both usable if fixtures exist.
4. Play/pause, seek, ±15 seconds, volume, speed, reveal, and close work.
5. Main workspace never embeds the player.

Do not create a meeting, new recording, transcript, or thumbnail fixture for this UAT.

- [ ] **Step 3: Write and commit the concise UAT record**

Record build identity, focused test count, the five checks, any unavailable fixture, and known unrelated Settings baseline failures. Then:

```bash
git add docs/testing/2026-08-08-playback-and-recordings-library-uat.md
git commit -m "docs: record saved media UI acceptance"
```
