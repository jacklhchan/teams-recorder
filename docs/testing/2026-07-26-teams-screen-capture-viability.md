# Teams Same-Stream Screen-Capture Viability Gate

**Status:** Passed on the target Mac on 2026-07-27.

## Candidate

- Branch: `codex/native-audio-capture`
- Candidate commit: `f401053e431c3cf340dedfe0d66568ed36e3caff`
- Launch argument: `--teams-screen-viability-probe`
- Evidence output directory: `~/Downloads/TeamsCaptureViability/`

## Required Live Environment

| Field | Actual value |
| --- | --- |
| Local Meeting Recorder app version | `0.1.0 (1)` |
| Microsoft Teams version | `26183.1901.4874.5228` |
| macOS version | `26.5 (25F71)` |
| Teams account / tenant constraints | PCCW tenant; four Microsoft Teams Echo Bot test calls |
| Selected Teams window IDs | `4903`, `4965`, `4972`, `4977` |
| Known continuous Teams clip | Echo Bot call prompts and call audio |
| Microphone speech source | Selected physical `Jack的AirPods Pro`; MacBook-speaker acoustic speech |

The MacBook was in clamshell mode. Core Graphics reported one active
`3440 x 1440` display, so a cross-display move was not executable in this
environment.

## Required Procedure

1. Launch the installed app with `--teams-screen-viability-probe` under its existing TCC identity.
2. Refresh the manually selectable windows; only `com.microsoft.teams2` windows are eligible.
3. Start the probe. It attempts NV12 first and retries exactly once with BGRA if startup fails. A startup candidate stopped by its delegate before adoption is rejected; only the successfully adopted generation becomes the one active `SCStream` or enters the report identity set. It begins on the Teams application filter with system-audio, selected-microphone, and screen outputs on distinct callback queues.
4. With continuous Teams playback and selected physical microphone speech active, complete **four full application -> window -> application round trips**. The JSON field `filterTransitionCount` is retained for compatibility but counts completed round trips, not individual filter updates. Repeated selections and window-to-window replacement do not advance it.
5. During window-filter dwells, occlude, resize, move to another display, minimize and restore, and pop out or replace the meeting window.
6. Keep every window-filter dwell active for at least five seconds. Stop and save after the final application dwell.
7. Inspect every saved PNG to confirm it visibly contains the complete meeting window, then run `TeamsCaptureViabilityEvaluator.failures(in:)` on the saved JSON report.

## Actual Execution

- The core gate used four separate live Echo Bot call windows. Each call was
  selected while active, held under the window filter, and returned to the
  Teams application filter before Teams destroyed the call window.
- Bringing the probe to the foreground occluded Teams during every dwell.
  Every desktop-independent capture still contained the complete Teams window.
- The four distinct call-window IDs also exercised live meeting-window
  replacement without recreating the `SCStream`.
- A supplemental run on window `4985` resized the Teams window to the left
  half, zoomed it, minimized it for approximately 1.5 seconds, and restored it.
  The same stream continued to deliver frames and both audio outputs.

## Required Evidence

| Item | Actual value |
| --- | --- |
| JSON report path | `~/Downloads/TeamsCaptureViability/core-pass-f401053/teams-screen-capture-viability-report.json` |
| PNG paths, one per window dwell | `window-4903-revision-1.png`, `window-4965-revision-3.png`, `window-4972-revision-5.png`, `window-4977-revision-7.png` in `core-pass-f401053/` |
| Stream identity set | `{ "48963617920" }` |
| Completed application-window-application round trips (`filterTransitionCount`) | `4` |
| Observed window IDs | `{ 4903, 4965, 4972, 4977 }` |
| System/microphone non-silent buffer counts per dwell | See table below; every count is greater than zero |
| Complete frame count per dwell | `114`, `117`, `145`, `107` |
| Maximum system/microphone end-to-start PTS gaps per dwell, including cross-transition gaps | `0 ms` for both sources in every dwell |
| Audio timing diagnostics | None |
| Callback-stop notes | None |
| `Gate failure:` notes, including filter-update, stop, cleanup, and transition-boundary gap failures | None |
| Evaluator failures | `[]` |
| Gate result | **Pass** |

### Core Dwell Counters

| Revision | Window | Duration | Complete frames | Teams buffers | Microphone buffers | System gap | Microphone gap |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `1` | `4903` | `11.547 s` | `114` | `108` | `248` | `0 ms` | `0 ms` |
| `3` | `4965` | `12.028 s` | `117` | `124` | `157` | `0 ms` | `0 ms` |
| `5` | `4972` | `14.781 s` | `145` | `125` | `185` | `0 ms` | `0 ms` |
| `7` | `4977` | `10.948 s` | `107` | `125` | `179` | `0 ms` | `0 ms` |

The application baseline lasted `43.844 s` on the same identity and contained
`432` complete frames, `494` non-silent Teams buffers, and `973` non-silent
microphone buffers.

### Supplemental Window Operations

- Report:
  `~/Downloads/TeamsCaptureViability/supplemental-window-ops-f401053/teams-screen-capture-viability-report.json`
- PNG:
  `~/Downloads/TeamsCaptureViability/supplemental-window-ops-f401053/window-4985-revision-1.png`
- Result: one `116.009 s` window dwell, `903` complete frames, `208`
  non-silent Teams buffers, `751` non-silent microphone buffers, `0 ms`
  maximum PTS gaps, and no callback or gate-failure note.
- Visual inspection: all four core PNGs and the supplemental PNG are
  `1600 x 900` and visibly contain the complete Teams call window, including
  its top toolbar and local participant tile, without cropping.

## Pass Criteria

The gate passes only when the evaluator returns no failures: one stream identity shared by the application baseline and every dwell, at least four complete application-window-application round trips, every window dwell at least five seconds with non-silent Teams and selected-microphone audio, at least ten complete frames, one PNG, no callback stop, no invalid audio-timing diagnostic, no `Gate failure:` note, and no end-to-start audio PTS gap above 250 ms. Failed `updateContentFilter` and `stopCapture` calls remain deterministic gate-failing evidence even after a later retry; a stop error also triggers best-effort output detachment before one finalization. PTS history persists across filter revisions, and every gap above 250 ms is also stored globally as gate-failing evidence so a gap observed while a filter update is awaiting cannot disappear with a discarded application dwell. Complete frames are copied on the screen queue and encoded on the evidence queue for their exact revision; finalization waits for in-flight filter/stop outcomes and writes JSON/PNG evidence once. Any failure must be committed as failed evidence and stops Task 2.
