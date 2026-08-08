# Teams shared-content capture: human acceptance runbook

Status: `NOT RUN` until a named operator records results in the evidence table.

Use two Windows devices and isolated test Teams accounts.  Device B shares the
synthetic test content (with sound); Device A selects exactly the live Teams
meeting window.  Never use real meeting content or production credentials.

## Before starting

1. Record Device A/B Windows build, Teams build, display/DPI topology, and the
   exact Git commit (`git rev-parse HEAD`).
2. Run `windows/scripts/Verify-Windows.ps1` and record its timestamp.
3. On Device A, run
   `Recorder.WgcWindowCaptureSession.Tests.exe --live-acceptance` from a
   visible interactive desktop.  A skipped/unobservable repaint is `NOT RUN`,
   not a pass.
4. Prepare distinctive dynamic privacy canaries on Device A's desktop, another
   application, a second Teams window, and (where available) the second monitor.

## Required runs

| Run | Duration | Required actions | Pass record |
| --- | ---: | --- | --- |
| A | 30 min | Share synthetic content with sound; resize Teams, change shared content, occlude/minimize/restore, move monitors, test 100/150/200% DPI. | MP4/M4A hashes; no canary in frames or diagnostics; no desktop/monitor source. |
| B | 10 min | Flash/beep marker every 30 s. | Every offset <=250 ms; first-to-last drift <=100 ms; stream duration delta <=1 s. |
| C | 10 min | Repeat B after resize/DPI change. | Same as B. |
| D | 10 min | Repeat B after monitor move/content switch. | Same as B. |
| E | 60 min | Soak, then close/destroy selected window while recording. | Video stops/fails closed; M4A remains playable and metadata is `videoLostAudioPreserved`. |

## Evidence table

| Date UTC | Operator | Commit | Device pair | Run | Result (`PASS`/`FAIL`/`NOT RUN`) | Media hashes / redacted notes |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | NOT RUN | |

Do not remove `CapturePipelineNotInstalled` until every row above is `PASS`
with saved hashes and redacted evidence.
