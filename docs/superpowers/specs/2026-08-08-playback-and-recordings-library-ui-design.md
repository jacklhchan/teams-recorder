# Playback and Recordings Library UI Design

**Date:** 2026-08-08  
**Status:** Approved for implementation  
**Scope:** Standalone recording playback window and the all-recordings library view

## Goal

Make saved recordings faster to scan and more pleasant to review while preserving the existing native macOS architecture. The library remains a compact local-media browser; the playback window remains a focused player rather than becoming an editor or meeting-intelligence workspace.

## Design Principles

- Put the primary task first: find a recording, then play it.
- Show only claims supported by persisted session metadata.
- Keep secondary actions available without displaying seven buttons on every row.
- Preserve keyboard and accessibility access for every action.
- Reuse the existing dark graphite visual language and native SwiftUI/AppKit controls.
- Avoid asynchronous thumbnail extraction, waveform analysis, chapter generation, and new persistence formats.

## 1. Recording Playback Window

### Layout

The standalone window keeps the existing `PlaybackWindowController` ownership and lifecycle. Its content is reorganized into:

1. A compact metadata header with the recording display name, creation date, duration, file name, a **Show in Finder** action, and an overflow menu when a secondary action is needed.
2. A media stage. Video sessions retain the native `VideoPlayer` in a rounded 16:9 surface. Audio-only sessions show a calm waveform-symbol placeholder instead of collapsing into a 150-point utility strip.
3. A precision timeline with elapsed time on the left, remaining time on the right, and the existing seek behavior.
4. A transport row with skip back 15 seconds, play/pause, skip forward 15 seconds, volume, playback speed (`0.5×`, `1×`, `1.25×`, `1.5×`, `2×`), and a compact elapsed/total readout.
5. Factual metadata chips derived only from `RecordingSession`: `Video` or `Audio only`, `Teams automatic` or `Manual`, and a recovery warning when `recoveryState != .none`.

Native `VideoPlayer` remains responsible for its built-in full-screen behavior. Closing the playback window continues to stop playback.

### Interaction

- Skip controls call the existing seek path with `progress - 15` and `progress + 15`; clamping stays in `PlaybackCoordinator`.
- Space toggles play/pause. Left and right arrow shortcuts seek by 5 seconds when the playback window is active.
- Volume changes `AVPlayer.volume` only for the playback player.
- Playback speed changes `AVPlayer.defaultRate`; if playback is active, the current rate is updated immediately.
- **Show in Finder** reveals `session.recordingURL` through `NSWorkspace` without changing the library selection.
- No transcript, summary, AI action, editing timeline, or clip export is embedded in this window.

### Window Sizing

- Video: default `980 × 720`, minimum `680 × 520`.
- Audio only: default `720 × 360`, minimum `600 × 300`.
- Controls reflow without horizontal clipping at the minimum sizes.

## 2. All Recordings Library

### Layout

The existing sidebar and `RecordingsLibraryView` destination remain. The destination changes from expandable cards to a compact grouped media list:

1. Header: `Recordings`, item count, total duration, the existing search field, Upload Audio, and Refresh.
2. Filter bar: `All`, `Favorites`, `Has transcript`, and `Needs attention`.
3. Sort menu: `Newest first` and `Oldest first`.
4. Date groups: `Today`, `Yesterday`, then month and year (for example, `July 2026`).
5. Compact rows containing a deterministic video or audio placeholder, favorite indicator, display name, date/time, duration, file size, relevant status chips, a primary Play button, and an overflow menu.
6. A selected row exposes only two common secondary actions inline: **Open Transcript** when available and **Show in Finder**. All other actions remain in the overflow menu.
7. Footer: current output folder and visible item count.

Rows use thin separators and a subtle selection surface instead of independent large cards. At the existing minimum workspace size, about six recordings should remain visible without expansion.

### Filters and Status

- `All`: all sessions matching the search text.
- `Favorites`: `session.isFavorite == true`.
- `Has transcript`: a transcript document resolves inside the session folder.
- `Needs attention`: a non-`.none` recovery state or a current transcription state that is failed, cancelled, or interrupted.
- Search continues to use `RecordingLibraryQuery`, including transcript snippets.
- Transcription progress displays the existing status message and spinner; the UI does not invent a percentage.
- Source chips use persisted metadata: `Teams`, `Manual`, or `Imported`. Media chips use `Video` or `Audio only`.

### Actions

- Play remains the only permanently visible row action.
- The overflow menu preserves Open Folder, Edit Details, Transcribe/Cancel, Open Transcript, Open ASR Log, and Move to Trash, with the same enablement and canonical-session admission rules as today.
- Clicking a row selects it; it does not start playback or expand a second full action panel.
- Search, filter, sort, refresh, deletion, library-revision invalidation, and transcript routing must keep their existing safe behavior.

### Thumbnails

This iteration uses deterministic placeholders based on `mediaKind`: a video-frame symbol for video and a waveform treatment for audio. Extracting frames from every recording would require asynchronous image generation, caching, cancellation, and invalidation; that is explicitly outside this iteration.

## Accessibility

- Every transport control and row action has a stable accessibility label and identifier.
- Selected rows expose selected state; status is not conveyed by color alone.
- Keyboard navigation can reach filters, rows, Play, inline actions, and overflow menus.
- Playback shortcuts do not fire while a text field or menu owns keyboard focus.
- Existing destination and action identifiers remain stable where their action still exists.

## Error and Empty States

- The current no-recordings/search-empty `ContentUnavailableView` remains.
- Playback load failure continues to dismiss stale playback state and publish the existing failure status.
- A missing transcript disables transcript actions rather than showing an empty detail screen.
- Recovered audio remains playable and receives a visible recovery badge without blocking playback.

## Focused Acceptance Criteria

1. Video and audio-only recordings both open in a comfortably sized standalone playback window.
2. Playback play/pause, seek, ±15-second skip, volume, speed, window close, and Show in Finder work without changing playback ownership semantics.
3. Playback UI never claims capture health that is absent from persisted session metadata.
4. The library shows compact date-grouped rows and preserves search, favorites, transcription, transcript, metadata, folder, and trash workflows.
5. Search/filter/sort combinations produce deterministic results and remain valid after a library refresh.
6. Secondary actions are accessible without rendering the former full action strip on every row.
7. Existing minimum window sizes render without clipped primary controls.
8. Focused playback, library query/presentation, AppModel playback, and workspace render tests pass.

## Non-Goals

- Video frame thumbnail extraction or thumbnail cache
- Persisted waveform generation
- Editing, trimming, chapters, bookmarks, or clip export
- Transcript or meeting-intelligence panels inside playback
- Cloud sync, sharing, collaboration, or analytics
- New recording metadata schema

