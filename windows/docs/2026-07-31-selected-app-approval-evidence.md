# Windows Selected App Audio approval evidence — 2026-07-31

This evidence applies to the standalone Windows branch only. The macOS `main`
branch remains separate and is not a merge target.

## Approval blockers fixed

- State-query correlation now retains up to eight outstanding request IDs per
  connection. A token refresh may issue a second query before the first reply;
  a delayed acknowledgement/error for either query is consumed as
  informational and cannot enter generic pairing/error handling.
- First-run microphone capture defaults to **No microphone**, even when Windows
  exposes a communications/default capture endpoint. A physical microphone is
  included only after an explicit user selection. The persisted public setting
  also defaults to `recordMicrophone=false`.
- The Teams opt-in documentation now matches runtime behaviour: the non-secret
  choice is persisted, while pairing credentials remain in the separate DPAPI
  store.
- The Release bridge probe now exposes the same selected-process-tree M4A ABI
  used by the application, including PID creation-time verification.

Managed regression tests cover overlapping query replies, privacy-first
microphone defaults, persisted no-microphone state, selected-source fail-closed
behaviour, stale PID rejection, recovery evidence, and restart generation.

## Dual-tone process isolation

Two independent Release `Recorder.TonePlayer` processes played 440 Hz (target)
and 880 Hz (distractor) simultaneously. Release `Recorder.BridgeProbe` recorded
the 440 Hz target PID through `recorder_native_start_selected_audio` for 15
seconds.

```text
containerDuration=15.040000
target440Mean=-24.1 dB
distractor880Mean=-57.2 dB
difference=33.1 dB
discontinuities=0
```

The selected recording retained the target signal while strongly suppressing
the unrelated process.

## Target exit / no fallback

The target process was terminated after approximately four seconds while the
880 Hz distractor continued playing. Selected capture stopped with:

```text
CAPTURE_ERROR
stage=Selected root process exited during capture
containerDuration=4.053313
```

The session did not continue to the requested 12 seconds, proving that target
exit failed closed instead of silently switching to system loopback.

## 120-second selected-process duration and isolation

The target process played a 30-second 440 Hz tone, 30 seconds of silence, then
60 seconds of the same tone. The independent 880 Hz distractor ran for the
whole test. Selected-process-tree capture reported:

```text
requestedSeconds=120
packets=11999
inputFrames=5291559
outputFrames=5760960
containerDuration=120.021313
discontinuities=0
```

Band-limited FFmpeg checks, excluding transition edges, reported:

```text
00:01-00:29 target 440 Hz    mean=-20.1 dB
00:31-00:59 target band      mean=-91.0 dB
01:01-01:59 target 440 Hz    mean=-20.1 dB
00:01-01:59 distractor 880 Hz mean=-54.5 dB
```

The 21.313 ms duration error is below both the 500 ms and 1% acceptance bounds;
the packetless silence remained on the timeline and the unrelated process did
not leak into the selected recording at a material level.

## Microphone gate

This Windows installation exposes only `Steam Streaming Microphone` as an
active capture endpoint; no physical microphone endpoint is available. A
10-second selected-process plus explicit Steam capture-endpoint smoke test
completed successfully at `10.048000` seconds, but this is not physical-input
evidence. A real built-in/USB/headset microphone signal and unplug test remains
a hardware release gate and must not be claimed as complete.
