# Teams Recorder for Windows

This directory contains the Windows-native re-platform of Local Meeting
Recorder. The macOS application remains the behavioural baseline; Windows is
being delivered in small, testable slices.

## Current working slice

The repository now contains:

- a portable .NET domain core for recording ownership and Teams automatic
  recording policy;
- a versioned native C ABI and a SafeHandle-backed managed coordinator for
  recording lifecycle, endpoint enumeration, test recordings, and telemetry;
- Windows WASAPI system, microphone, and process-loopback capture modules with
  packet-owned callbacks, 48 kHz stereo normalization, and no-replace WAV
  output;
- a WinUI 3 desktop shell in `src/Recorder.WinUI` for **system-loopback WAV**
  recording. It lists render devices, chooses the Windows default or a specific
  endpoint, starts/stops a recording, provides a 10-second test, displays
  peak/packet/discontinuity health, and stops native capture on window close;
- deterministic native and managed tests, JSON contract fixtures, and real
  process-audio diagnostic tools.

The desktop shell deliberately exposes only the first verified capture path.
It does not yet offer microphone or process selection, Teams meeting detection,
video capture, M4A/MP4 export, a recording browser, transcription, or a
virtual microphone driver.

## Supported development baseline

- Windows 11 x64 (22H2 / build 22621 or newer)
- .NET 10 SDK
- Visual Studio 2022 with the Desktop development with C++ workload
- CMake 3.25 or newer

## Build and test

From a Developer PowerShell at repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Verify-Windows.ps1
```

The verifier configures the native projects, runs the Debug native test suite,
builds the distributable x64 Release `Recorder.NativeBridge.dll`, builds the
.NET solution and WinUI executable, then runs managed and contract tests.

The WinUI Release executable is emitted at:

```text
windows\src\Recorder.WinUI\bin\x64\Release\net10.0-windows10.0.22621.0\win-x64\Recorder.WinUI.exe
```

The matching Release `Recorder.NativeBridge.dll` is copied next to it. Do not
ship the Debug native DLL: it depends on the non-redistributable debug C++
runtime.

## Why the app is not installed yet

Building an `.exe` does not register or install an app in Windows. The project
defaults to an unpackaged, self-contained developer build so the Release EXE
can run directly. It also retains a single-project MSIX manifest, but this
repository intentionally does not create or trust a signing certificate and
does not enable Windows Developer Mode. Both change machine security state.

To produce an unsigned MSIX for a deployment pipeline without installing it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Package-Windows.ps1
```

That creates a package under `windows\out\packages\`. It is intentionally
unsigned and is not installable through the ordinary user workflow.

To make Teams Recorder appear in Start, create a signed MSIX whose certificate
matches `Publisher="CN=Teams Recorder"`, trust that certificate through the
normal organisation or release process, then install it with App Installer or
`Add-AppxPackage`. Until that release-signing decision is made, the supported
developer handoff is the Release executable above rather than a machine-wide
installation.

## Layout

```text
windows/
|-- contracts/                  Cross-platform JSON contracts and fixtures
|-- docs/                       Parity baseline and Windows architecture
|-- native/                     Native media boundary and lifecycle tests
|-- scripts/                    Local validation entry points
|-- src/Recorder.Core/          Portable policy and state machines
|-- src/Recorder.Application/   Managed native-bridge adapter and lifecycle gate
|-- src/Recorder.WinUI/         WinUI 3 system-loopback capture shell
`-- tests/Recorder.Core.Tests/  Deterministic core tests
```
