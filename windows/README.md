# Teams Recorder for Windows

This directory is the beginning of the Windows-native re-platform of Local
Meeting Recorder. The existing macOS application remains the behaviour
baseline; the Windows implementation is intentionally being delivered in
small, testable slices.

## Current migration slice

The repository currently contains:

- a portable .NET domain core for recording ownership and Teams automatic
  recording policy;
- a versioned native C ABI with synchronized start/stop/state/stats lifecycle
  for system loopback, microphone, and process-tree loopback capture;
- Windows-only capture modules with endpoint enumeration, packet-owned WASAPI
  callbacks, QPC/device positions, format decoding, streaming normalization to
  48 kHz stereo, and no-replace float WAV output;
- deterministic bridge and dual-tone tools used to prove real process-audio
  isolation on this machine;
- versioned JSON contracts and compatibility fixtures for recording metadata
  and transcription state;
- parity and architecture documents in `docs/`.

The native bridge now captures and finalizes audio through its public C ABI.
There is not yet a WinUI application, Windows Graphics Capture video path,
Media Foundation MP4 writer, or virtual microphone driver.

## Supported development baseline

- Windows 11 x64
- .NET 10 SDK
- Visual Studio 2022 Build Tools with the Desktop development with C++ workload
- CMake 3.25 or newer

## Build and test

From a Developer PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Verify-Windows.ps1
```

The individual commands run by that verifier are:

```powershell
Push-Location .\windows
dotnet build .\TeamsRecorder.Windows.sln
dotnet run --project .\tests\Recorder.Core.Tests\Recorder.Core.Tests.csproj
Pop-Location

Push-Location .\windows\native
cmake --preset windows-x64
cmake --build --preset windows-x64-debug
ctest --preset windows-x64-debug
Pop-Location

powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Test-Contracts.ps1
```

The .NET core is OS-independent by design. Raw PCM samples and Direct3D frames
must remain in the native media layer; managed code receives only lifecycle
events, level summaries, errors, and completed-file notifications.

## Layout

```text
windows/
|-- contracts/                  Cross-platform JSON contracts and fixtures
|-- docs/                       Parity baseline and Windows architecture
|-- native/                     Native media boundary and lifecycle tests
|-- scripts/                    Local validation entry points
|-- src/Recorder.Core/          Portable policy and state machines
`-- tests/Recorder.Core.Tests/  Deterministic core tests
```

The next implementation slice is the managed-to-native coordinator, capture
device selection UI, long-duration/device-loss testing, and then the Windows
Graphics Capture + QPC synchronization spike. Physical microphone validation
still requires a usable physical input endpoint; this machine currently exposes
only an incompatible Steam Streaming Microphone virtual endpoint.
