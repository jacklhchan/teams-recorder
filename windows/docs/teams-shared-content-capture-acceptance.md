# Teams shared-content capture acceptance

## Status and scope

This is a test-first acceptance contract for the Windows recorder.  It applies
to the exact Git commit recorded at the start of a run.  The intended source is
one **user-selected Microsoft Teams top-level window**; it is never the desktop
or a monitor.  Capturing only a Teams-internal shared-content rectangle is out
of scope.  The full selected meeting window may include Teams chrome.

This document does not make the feature available.  A successful
`GraphicsCaptureItem` preflight is insufficient: the feature remains gated
until the frame, encoder, mux, recovery, and live acceptance gates below pass.

## Non-negotiable safety properties

- A target is current only when its `HWND`, PID, and process creation time all
  match the user selection.
- Hidden, child, cloaked, protected, elevated, destroyed, ambiguous, or stale
  targets are rejected.  No rejection may select a different window or any
  desktop/monitor source.
- A target replacement requires explicit user re-selection unless a separately
  approved identity policy can prove it is the original target.  Until then,
  video waits or stops while audio may continue.
- Runtime HWNDs, PIDs, process creation times, full titles, executable paths,
  thumbnails, and captured pixels are not persisted to recording metadata or
  diagnostics.
- Video/MP4 failure must not interrupt or delete the independent AAC/M4A audio
  safety recording.

## Deterministic fixtures

1. `synthetic-wgc`: a top-level test window with a monotonic frame counter,
   monotonic timestamp, distinct corner markers, moving shapes, colour cycles,
   deliberate static period, resize operation, and close/recreate operation.
2. `av-sync`: a 48 kHz audio beep and a 100 ms full-frame flash sharing a
   sequence number, emitted every 30 seconds for at least 60 minutes.
3. `privacy-canary`: distinct dynamic colour/pixel signatures outside the
   target window: on the desktop, in another app, in another Teams window, and
   on a second monitor.  It must not be present in output frames or diagnostics.

## Automated acceptance matrix

| ID | Test | Pass criteria |
| --- | --- | --- |
| AT-00 | Baseline regression | `Verify-Windows.ps1`, native CTest, managed tests, selected-app audio, M4A library, ASR, and package verification pass. |
| AT-01 | Target identity | Only live Teams top-level targets are offered. PID reuse, HWND replacement, stale creation time, child, hidden, cloaked, protected, elevated, and non-Teams targets are rejected. |
| AT-02 | Fail closed/privacy | Any rejected WGC target produces no desktop/monitor/other-window capture and no successful MP4 publication. |
| AT-03 | Synthetic capture | Five-minute H.264/AAC MP4 reopens and seeks; stream timestamps are monotonic; target markers are present and privacy canaries absent. |
| AT-04 | Resize/DPI/loss | At 100%, 150%, and 200% DPI, resize, occlusion, monitor move, minimize, and target loss do not leak other pixels or block audio. |
| AT-05 | A/V synchronization | Across three ten-minute runs, every flash/beep offset is at most 250 ms, first-to-last drift at most 100 ms, and stream-duration difference at most one second. |
| AT-06 | Fault recovery | WGC, GPU, encoder, mux, finalize, rename, disk-full, and target-loss injection never destroys audio. A final MP4 exists only after decode validation; otherwise the M4A is non-empty, playable, and marked `videoLostAudioPreserved`. |

## Human-assisted Teams acceptance

Use two Windows devices and two test Teams accounts only.  Device B shares the
synthetic content with sound; Device A explicitly selects the live Teams window.
Run remote share, resize, content switching, occlusion, DPI, multi-monitor,
window replacement, microphone, target loss, and a 30-minute plus 60-minute
soak.  Record redacted environment versions, commit SHA, media hashes, sync
analysis, and pass/fail locally.  A test that was not physically run is
`NOT RUN` or `BLOCKED`, never `PASS`.

## Release gate

Do not remove `CapturePipelineNotInstalled` until every automated test and the
human-assisted matrix pass with saved evidence.  Unit tests or capability probes
alone can never satisfy this gate.
