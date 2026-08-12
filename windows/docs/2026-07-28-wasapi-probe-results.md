# WASAPI technical spike results

**Date:** 2026-07-28
**Environment:** Windows 10.0.26200.8894 x64, Windows SDK 10.0.26100,
MSVC 19.44

## Scope and result

This is engineering evidence for the first Windows audio slice, not a claim
that the Windows application or A/V recorder is complete.

| Probe | Result | Evidence |
| --- | --- | --- |
| Active endpoint enumeration | Pass | 3 render endpoints and 1 capture endpoint returned with IDs, friendly names, and default-role flags |
| Default render system loopback | Pass | Event-driven, 48 kHz stereo float, 301 packets / 144,480 frames over 3.01 seconds |
| WAV publication | Pass | `.partial` promotion produced `pcm_f32le`; FFprobe reopened it as 48 kHz stereo with a 3.01-second duration |
| Process-tree loopback activation | Pass | `ActivateAudioInterfaceAsync` returned an `IAudioClient` for a live PowerShell PID |
| Native bridge system capture | Pass | Public C ABI captured 3.00 seconds: 300 packets, 144,000 input/output frames, 48 kHz stereo float |
| Process packet capture and 48 kHz normalization | Pass | Public C ABI captured 4.00 seconds: 400 packets, 176,400 frames at 44.1 kHz decoded and resampled to exactly 192,000 frames at 48 kHz stereo |
| Process-only audio isolation | Pass | With independent 440 Hz target and 1000 Hz interferer processes playing together, narrow-band mean levels were -24.2 dB and -63.5 dB respectively: 39.3 dB target separation |
| Physical microphone capture | Blocked by test environment | The only active capture endpoint is `Steam Streaming Microphone`; both event-driven and bounded-polling shared initialization return `E_INVALIDARG` for its reported 44.1 kHz mono float mix format |

The system-loopback run reported one initial discontinuity, no silent packets,
and a peak of `0.985045`. The generated WAV files live under ignored
`windows/out/probes/` and are not source artifacts.

The formal process-loopback path requests 44.1 kHz, 16-bit stereo PCM with
Windows audio-engine conversion, because the process virtual client's
`IAudioClient::GetMixFormat` returns `E_NOTIMPL`. Packet decoding and the
stateful resampler then publish canonical 48 kHz stereo IEEE-float WAV.

## Reproduction

```powershell
Push-Location windows/native
cmake --preset windows-x64
cmake --build --preset windows-x64-debug
Pop-Location

.\windows\out\native\Debug\Recorder.AudioProbe.exe list
.\windows\out\native\Debug\Recorder.AudioProbe.exe capture-system 3 `
  .\windows\out\probes\system-default.wav
.\windows\out\native\Debug\Recorder.AudioProbe.exe capture-mic 3 `
  .\windows\out\probes\mic-default.wav
.\windows\out\native\Debug\Recorder.ProcessLoopbackProbe.exe activate $PID 10000
.\windows\out\native\Debug\Recorder.BridgeProbe.exe system 3 `
  .\windows\out\probes\bridge-system.wav
.\windows\out\native\Debug\Recorder.BridgeProbe.exe process $PID 4 `
  .\windows\out\probes\bridge-process.wav
```

## Remaining Phase 0 gates

1. Test microphone capture on a machine with an active physical USB, headset,
   or built-in capture endpoint. The Steam virtual endpoint is not acceptable
   evidence for physical microphone support.
2. Run 30- and 60-minute system/process/microphone stability tests and record memory,
   discontinuity, device-loss, and dropped-packet counters.
3. Connect the public native bridge to the managed application coordinator and
   expose endpoint selection without allowing PCM to cross the C ABI.
4. Add Windows Graphics Capture and prove audio/video QPC alignment.
