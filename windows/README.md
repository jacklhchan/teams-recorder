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
  packet-owned callbacks, 48 kHz stereo normalization (including the added
  four-channel-to-stereo downmix core), and no-replace WAV output;
- a WinUI 3 desktop shell in `src/Recorder.WinUI` for **system render-loopback
  recording, optionally mixed with one explicitly selected microphone**. It
  lists render and capture devices, starts/stops a recording, provides a
  10-second test, displays aggregate peak/packet/discontinuity health, and
  stops native capture on window close;
- an AAC-in-M4A mixed-capture path. The native writer produces an M4A output;
  the application storage services define a separately test-covered session
  layout with a backup M4A, no-replace promotion, library discovery, capacity
  decisions, and conservative interrupted-session recovery;
- local M4A library discovery and playback controls in the WinUI shell.
- deterministic native and managed tests, JSON contract fixtures, and real
  process-audio diagnostic tools.

This is an audio-first MVP, not a generally available Teams integration. In one
Windows validation environment, Teams Third-party App API pairing completed,
authoritative meeting-presence updates were received, and the automatic-recording
flow finalized an M4A file. This is limited single-environment evidence only; it
does not establish general Teams API availability, Teams-only process recording,
or cross-tenant support. Teams UI mute/unmute actions did not deliver reliable
mute-state updates in that validation. Teams Mute Sync therefore remains an
unverified Preview and must not be presented as working, reliable, or capable of
controlling Teams mute. The integration relies on supported pushed events and
does not retain `query-state` polling as a workaround. Video capture,
transcription, and a virtual microphone driver are not available. Aggregate
health is available, but source-specific health statistics are not yet exposed.

The WinUI recording command allocates managed `manual-*` or `test-*` session
folders through the storage service, writes native capture to
`recording.audio-backup.m4a`, then promotes it without replacement to
`recording.m4a` and writes metadata. At startup it conservatively attempts
recovery before refreshing the local library, and it blocks recording when the
selected storage root is unavailable or has less than 256 MiB free. This flow
is covered by managed tests; it still needs end-to-end real-device validation.

The technical probe record is in
[`docs/2026-07-28-wasapi-probe-results.md`](docs/2026-07-28-wasapi-probe-results.md).
It includes successful system-loopback AAC-in-M4A evidence, plus synthetic
process-loopback evidence, but no successful physical-microphone or
optional-mic-mix run. The development machine's Intel four-channel microphone
fails WASAPI/Media Foundation RAW initialization with `E_INVALIDARG`; the
four-channel downmix core is present, but cannot bypass that endpoint-level
blocker. A real Windows device with an actual microphone must still complete a
record, stop, reopen, playback, and optional-mic-mix release validation before
shipping.

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

The verifier configures the native projects, completes both Debug and Release
native builds and CTest suites, builds the distributable x64 Release
`Recorder.NativeBridge.dll`, builds the .NET solution and WinUI executable,
publishes an unpackaged x64 Release output, then runs managed and contract
tests. It does not exercise a real audio endpoint, microphone, or speaker,
and is not a substitute for the release validation above.

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

To produce an **unsigned developer-only** MSIX without installing it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Package-Windows.ps1
```

That creates a package under `windows\out\packages\`. It is intentionally
not an end-user installer: the script never imports or trusts a certificate,
enables Developer Mode, or installs a package.

## Signed MSIX and safe installation

The manifest publisher is `CN=Teams Recorder`. A release certificate must be a
valid code-signing certificate with that exact subject and an accessible private
key. Obtain and trust the certificate through the organisation's normal PKI or
release process; do not use the package script to add a certificate to Trusted
People or Trusted Root Certification Authorities.

For a certificate already available in the personal certificate store:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Package-Windows.ps1 `
  -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567'
```

For a PFX that must not be imported, prompt for its password rather than placing
it in shell history:

```powershell
$password = Read-Host 'PFX password' -AsSecureString
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Package-Windows.ps1 `
  -CertificatePfxPath 'C:\secure\teams-recorder-signing.pfx' `
  -CertificatePfxPassword $password
```

To create an App Installer feed, add an HTTPS URL where the signed MSIX and the
generated `.appinstaller` file will be published together:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Package-Windows.ps1 `
  -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567' `
  -AppInstallerUri 'https://releases.example.com/teams-recorder/Recorder.WinUI.appinstaller'
```

Only after the release team has published the artifacts and confirmed that the
signing chain is trusted should users open that HTTPS `.appinstaller` link in
App Installer. For a managed deployment, administrators may use
`Add-AppxPackage` with the signed package and its dependencies according to
their policy. Neither workflow requires weakening Windows security settings.

## Layout

```text
windows/
|-- contracts/                  Cross-platform JSON contracts and fixtures
|-- docs/                       Historical design/probe records and MVP scope
|-- native/                     Native media boundary and lifecycle tests
|-- scripts/                    Local validation entry points
|-- src/Recorder.Core/          Portable policy and state machines
|-- src/Recorder.Application/   Managed native-bridge adapter and lifecycle gate
|-- src/Recorder.WinUI/         WinUI 3 audio-first capture, library, playback shell
`-- tests/Recorder.Core.Tests/  Deterministic core tests
```
