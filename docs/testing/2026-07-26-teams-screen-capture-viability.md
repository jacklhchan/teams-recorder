# Teams Same-Stream Screen-Capture Viability Gate

**Status:** Pending live execution. This document is not pass evidence.

## Candidate

- Branch: `codex/native-audio-capture`
- Baseline: `f4a892c`
- Launch argument: `--teams-screen-viability-probe`
- Evidence output directory: `~/Downloads/TeamsCaptureViability/`

## Required Live Environment

| Field | Actual value |
| --- | --- |
| Local Meeting Recorder app version | Pending |
| Microsoft Teams version | Pending |
| macOS version | Pending |
| Teams account / tenant constraints | Pending |
| Selected Teams window IDs | Pending |
| Known continuous Teams clip | Pending |
| Microphone speech source | Pending |

## Required Procedure

1. Launch the installed app with `--teams-screen-viability-probe` under its existing TCC identity.
2. Refresh the manually selectable windows; only `com.microsoft.teams2` windows are eligible.
3. Start the probe. It attempts NV12 first and retries exactly once with BGRA if startup fails. A startup candidate stopped by its delegate before adoption is rejected; only the successfully adopted generation becomes the one active `SCStream` or enters the report identity set. It begins on the Teams application filter with system-audio, selected-microphone, and screen outputs on distinct callback queues.
4. With continuous Teams playback and selected physical microphone speech active, complete **four full application -> window -> application round trips**. The JSON field `filterTransitionCount` is retained for compatibility but counts completed round trips, not individual filter updates. Repeated selections and window-to-window replacement do not advance it.
5. During window-filter dwells, occlude, resize, move to another display, minimize and restore, and pop out or replace the meeting window.
6. Keep every window-filter dwell active for at least five seconds. Stop and save after the final application dwell.
7. Inspect every saved PNG to confirm it visibly contains the complete meeting window, then run `TeamsCaptureViabilityEvaluator.failures(in:)` on the saved JSON report.

## Required Evidence

| Item | Actual value |
| --- | --- |
| JSON report path | Pending |
| PNG paths, one per window dwell | Pending |
| Stream identity set | Pending |
| Completed application-window-application round trips (`filterTransitionCount`) | Pending |
| Observed window IDs | Pending |
| System/microphone non-silent buffer counts per dwell | Pending |
| Complete frame count per dwell | Pending |
| Maximum system/microphone end-to-start PTS gaps per dwell, including cross-transition gaps | Pending |
| Audio timing diagnostics | Pending |
| Callback-stop notes | Pending |
| `Gate failure:` notes, including filter-update, stop, cleanup, and transition-boundary gap failures | Pending |
| Evaluator failures | Pending |
| Gate result | Pending: do not begin Task 2 until pass evidence is reviewed |

## Pass Criteria

The gate passes only when the evaluator returns no failures: one stream identity shared by the application baseline and every dwell, at least four complete application-window-application round trips, every window dwell at least five seconds with non-silent Teams and selected-microphone audio, at least ten complete frames, one PNG, no callback stop, no invalid audio-timing diagnostic, no `Gate failure:` note, and no end-to-start audio PTS gap above 250 ms. Failed `updateContentFilter` and `stopCapture` calls remain deterministic gate-failing evidence even after a later retry; a stop error also triggers best-effort output detachment before one finalization. PTS history persists across filter revisions, and every gap above 250 ms is also stored globally as gate-failing evidence so a gap observed while a filter update is awaiting cannot disappear with a discarded application dwell. Complete frames are copied on the screen queue and encoded on the evidence queue for their exact revision; finalization waits for in-flight filter/stop outcomes and writes JSON/PNG evidence once. Any failure must be committed as failed evidence and stops Task 2.
