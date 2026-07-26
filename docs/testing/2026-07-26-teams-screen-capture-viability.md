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
3. Start the probe. It begins on the Teams application filter using one `SCStream` with audio, microphone, and screen outputs.
4. With continuous Teams playback and microphone speech active, switch application-window-application at least four times.
5. During window-filter dwells, occlude, resize, move to another display, minimize and restore, and pop out or replace the meeting window.
6. Keep every window-filter dwell active for at least five seconds. Stop and save after the final application dwell.
7. Inspect every saved PNG to confirm it visibly contains the complete meeting window, then run `TeamsCaptureViabilityEvaluator.failures(in:)` on the saved JSON report.

## Required Evidence

| Item | Actual value |
| --- | --- |
| JSON report path | Pending |
| PNG paths, one per window dwell | Pending |
| Stream identity set | Pending |
| Filter transition count | Pending |
| Observed window IDs | Pending |
| System/microphone non-silent buffer counts per dwell | Pending |
| Complete frame count per dwell | Pending |
| Maximum system/microphone PTS gaps per dwell | Pending |
| Callback-stop notes | Pending |
| Evaluator failures | Pending |
| Gate result | Pending: do not begin Task 2 until pass evidence is reviewed |

## Pass Criteria

The gate passes only when the evaluator returns no failures: one stream identity, at least four filter transitions, every window dwell at least five seconds with non-silent Teams and microphone audio, at least ten complete frames, one PNG, no callback stop, and no audio PTS gap above 250 ms. Any failure must be committed as failed evidence and stops Task 2.
