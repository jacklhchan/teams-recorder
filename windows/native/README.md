# Recorder.NativeBridge

`Recorder.NativeBridge` is the Windows native boundary for audio capture.
ABI version 0.5 owns the source lifecycle, normalizes captured packets to
48 kHz stereo float, writes through a `.partial` recovery file, and publishes
the final WAV only after a successful stop. The legacy no-options
`recorder_native_start` remains exported but returns `INVALID_ARGUMENT` because
an output path and capture mode are required.

## Build and test

```powershell
Push-Location windows/native
cmake --preset windows-x64
cmake --build --preset windows-x64-debug
ctest --preset windows-x64-debug
Pop-Location
```

The contract tests use no Windows media API, so they can run with any C++17 compiler supported by CMake. `Recorder.NativeBridge.CAbiSmokeTests` is compiled as C11 and validates that the public header and imports work for C callers, not just C++ callers.

## WASAPI probes

After a Debug build:

```powershell
.\windows\out\native\Debug\Recorder.AudioProbe.exe list
.\windows\out\native\Debug\Recorder.AudioProbe.exe capture-system 3 `
  .\windows\out\probes\system.wav
.\windows\out\native\Debug\Recorder.AudioProbe.exe capture-mic 3 `
  .\windows\out\probes\mic.wav
.\windows\out\native\Debug\Recorder.ProcessLoopbackProbe.exe activate $PID 10000
```

The low-level audio probe writes endpoint-native samples as IEEE float WAV. The
public bridge path additionally decodes PCM/float packets and performs stateful
normalization to 48 kHz stereo. Process-loopback uses a requested 44.1 kHz
16-bit stereo format because the virtual process client does not implement
`GetMixFormat`; the bridge resamples that stream to its canonical output.

For multichannel microphone float PCM, normalization downmixes before
resampling. The capture boundary does not retain a speaker channel mask, so
the rule is deliberately channel-index based: mono duplicates to both outputs,
stereo is unchanged, and 3+ channels average even indices into left and odd
indices into right. A four-channel frame `[0, 1, 2, 3]` becomes
`[(0 + 2) / 2, (1 + 3) / 2]`; non-finite samples become silence. This is a
predictable fallback until channel-mask-aware routing can be carried through
the capture API.

## Bridge and tone probes

`Recorder.BridgeProbe` exercises only the public C ABI, writes a final WAV, and
prints capture statistics plus the bridge diagnostic on failure:

```powershell
.\windows\out\native\Debug\Recorder.BridgeProbe.exe system 5 .\windows\out\probes\system.wav
.\windows\out\native\Debug\Recorder.BridgeProbe.exe mic 5 .\windows\out\probes\mic.wav
.\windows\out\native\Debug\Recorder.BridgeProbe.exe process $PID 5 .\windows\out\probes\process.wav
```

`Recorder.WgcCaptureProbe.Tool` is a deliberately non-recording feasibility
probe for a future window-video pipeline. It validates only a visible,
top-level, non-cloaked, non-protected window at the same integrity level, then
tries to create a `GraphicsCaptureItem`; it never creates a capture session,
receives frames, or writes media. Use `--self-window` for a safe capability
check without targeting another application:

```powershell
.\windows\out\native\Debug\Recorder.WgcCaptureProbe.Tool.exe --self-window
.\windows\out\native\Debug\Recorder.WgcCaptureProbe.Tool.exe --self-window-sta
```

`--self-window-sta` initializes the tool thread as STA first, mirroring a WinUI
UI thread. Its output includes `apartment` and `apartmentInitializedByProbe`;
this mode must report `apartment=sta` or `apartment=main-sta` and
`apartmentInitializedByProbe=false`, showing that the probe preserves an
existing apartment instead of forcing MTA.

The process form does not fall back to system capture. The checked-in probe
report records a dual-tone run where the target 440 Hz signal was 39.3 dB above
the separate process's 1000 Hz interferer after narrow-band measurement.

`Recorder.TonePlayer` loops the specified WAV for exactly the requested
duration. It is useful for creating the interfering or target audio signal:

```powershell
.\windows\out\native\Debug\Recorder.TonePlayer.exe .\fixtures\tone.wav 5
```

## ABI and lifecycle

The public C ABI is in `include/recorder_native_bridge.h`. Handles are opaque and must be destroyed with `recorder_native_destroy`. `recorder_native_destroy` requires caller-provided external synchronization: call it only after ensuring no API call on the same handle is executing or can begin. Internal synchronization serializes bridge state operations, but does not make handle lifetime safe against concurrent destruction. Once destruction returns, the handle is permanently invalid and must not be passed to any bridge API, including diagnostic or query calls. For a non-null handle, `get_last_error` returns bridge-owned memory, valid only until the next call on that handle or destruction; the null-handle diagnostic is implementation-owned. Neither pointer is caller-freeable. A failed start preserves its prior non-recording state; stop drains and joins the capture thread before the format, resampler, and writer pipeline can be released.

Endpoint enumeration uses a separate opaque `RecorderNativeEndpointList`.
`recorder_native_enumerate_endpoints` creates an immutable snapshot of active
render and capture endpoints; its UTF-8 endpoint IDs and friendly names are
owned by that list and remain valid only until
`recorder_native_endpoint_list_destroy`. Callers copy strings before releasing
the list and never free them directly. The managed `Recorder.Application`
adapter does exactly this through SafeHandles and exposes only copied endpoint
records, lifecycle state, scalar health statistics, and copied diagnostics.

## Planned Windows media boundaries

* **WASAPI**: loopback/microphone client activation, format negotiation, capture callbacks, device-loss recovery.
* **Windows Graphics Capture (WGC)**: video frames and capture-item lifetime, kept separate from audio capture.
* **Media Foundation (MF)**: encoding, muxing and file output; it consumes owned audio/video samples rather than owning capture clients.

The audio bridge reports the first and latest WASAPI QPC positions as
100-nanosecond values. A future A/V coordinator will convert these to one
session-relative QPC origin; wall-clock time is metadata only and must not be
used for A/V alignment.

Capture producers will retain ownership of buffers until an explicit hand-off. Any future ABI that exposes samples must specify one of two modes: caller-provided writable buffers, or an opaque sample handle released by a matching bridge release function. Raw borrowed pointers must not outlive their callback/call boundary.
