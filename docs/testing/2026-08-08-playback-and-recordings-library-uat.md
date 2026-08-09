# Playback and Recordings Library UI UAT

**Date:** 2026-08-08

**Result:** Accepted

**Repository HEAD:** `2da6bf41e334980210cd0d8de780c7c2356fcadc`

## Build and automated verification

- Preview: `/Users/apple/Documents/recorder/build/Local Meeting Recorder UI Preview.app`
- Identity: `Local Meeting Recorder UI Preview`, `local.meeting.recorder.ui-preview`, version `0.2.0 (340)`
- Build/signing: debug, arm64, ad-hoc; bundle verification and `codesign --verify --deep --strict` passed.
- The required combined Swift filter ran exactly once: **60 tests passed, 0 failures**. The full suite and unrelated Settings tests were not run.

## Bounded GUI acceptance

| Check | Result | Evidence |
|---|---|---|
| Compact grouped library | Pass | The Downloads library showed 52 compact recordings grouped by date at normal width. A safe macOS **Move & Resize → Left** action drove the 860-point-minimum workspace to its supported narrow layout; search, filters, sort, rows, Play, and overflow actions remained visible without horizontal clipping. The previous size was restored. |
| Search and one filter | Pass | Searching `meeting-2026-08-07-092849` changed 52 visible recordings to 1. Applying **Favorites** changed the result to 0 and displayed the filtered empty state; returning to **All** restored 52. |
| Standalone video and audio-only layouts | Pass | Existing `meeting-2026-08-07-092849` opened as a standalone **Video / Teams automatic** player. Existing `meeting-2026-08-07-163620` opened as a standalone **Audio only / Manual** player. Only one playback window was opened at a time. |
| Playback controls | Pass | Play/pause changed the transport state; −15 seconds moved 00:16 → 00:01 and +15 moved 00:01 → 00:16; timeline seek moved to 02:00; volume changed 1.0 → 0.9; speed changed 1× → 1.5×. **Show in Finder** selected the existing `recording.mp4` without modifying it, and Close returned to the library. |
| No embedded player | Pass | Playback used a dedicated `Playing …` window. After closing it, the main `Recordings` workspace contained the library hierarchy and no `recorder.playback.root`. |

Both video and audio-only saved fixtures were available; no fixture check was unavailable. No meeting, recording, transcript, thumbnail, deletion, Trash action, permission change, or installation was performed.

## Known unrelated baseline

`testMicrophoneRefreshRemainsEnabledWhileRecording` and `testDirectionASettingsKeepsEveryExistingControlReachable` are pre-existing, unrelated Settings baseline failures. They were intentionally excluded from this focused run, and no Settings code or assertion was changed.
