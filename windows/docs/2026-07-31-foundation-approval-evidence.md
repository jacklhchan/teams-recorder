# Windows audio foundation approval evidence — 2026-07-31

This evidence applies only to the standalone Windows branch. It does not
authorize or imply a merge into the macOS `main` branch.

## Automated verification

- `windows/scripts/Verify-Windows.ps1` passed for Debug and Release.
- Native CTest passed 25/25 in each configuration, including the new
  `Recorder.M4aWriter.Duration` regression test.
- Managed lifecycle tests passed, including a recoverable native fault that
  retains the backup, refuses clean publication, preserves the native
  diagnostic, invalidates the old generation, and permits a new recording.
- WinUI x64 Release build and unpackaged publish completed with zero warnings
  and zero errors.
- All recording-session JSON fixtures passed the canonical schema validator.

## 120-second real-device duration run

The Release `Recorder.TonePlayer` played a 120-second fixture through the
default render endpoint while Release `Recorder.BridgeProbe` captured system
loopback in mixed mode with no microphone selected. The fixture contains a
30-second 440 Hz tone, 30 seconds of silence, then 60 seconds of the same tone.

Observed bridge result:

```text
requestedSeconds=120
packets=11998
inputFrames=5759040
outputFrames=5760960
outputSampleRate=48000
peak=0.140483
```

`ffprobe` reported `120.021313` seconds for the finalized AAC M4A. The absolute
error is 21.313 ms, below both the 500 ms and 1% acceptance bounds.

Segment checks with FFmpeg `volumedetect` reported:

```text
00:00-00:30 tone       mean=-20.1 dB  max=-15.7 dB
00:31-00:59 silence    mean=-91.0 dB  max=-91.0 dB
01:00-02:00 tone       mean=-20.1 dB  max=-15.7 dB
```

This confirms that a packetless quiet interval remains on the canonical
timeline instead of being compressed.

## Root causes covered by regression tests

1. Silent Windows loopback endpoints may deliver no WASAPI packet. The mixer
   now advances against a monotonic session-duration clock, trails live input
   by a bounded 100 ms, and catches up to the exact elapsed limit on stop.
2. The AAC timestamp numerator previously overflowed in a 32-bit constant
   expression. It is now explicitly 64-bit and guarded by a compile-time
   assertion; the Media Foundation test reopens a one-second M4A and verifies
   its presentation duration.

## Remaining hardware gate

This machine did not expose a separately validated physical microphone path
for this run. Optional physical-microphone mixing, unplug handling, and input
level evidence remain a hardware release gate and must not be claimed as
completed by this document.
