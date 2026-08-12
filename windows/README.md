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
  10-second test with automatic in-app playback, displays aggregate
  peak/packet/discontinuity health, and
  stops native capture on window close;
- an AAC-in-M4A mixed-capture path. The native writer produces an M4A output;
  the application storage services define a separately test-covered session
  layout with a backup M4A, no-replace promotion, library discovery, capacity
  decisions, and conservative interrupted-session recovery;
- local MP4/M4A library discovery and in-app audio/video playback controls in
  the WinUI shell;
- an explicit OpenAI-compatible or HKT GenAI ASR workflow, followed by bounded
  automatic Meeting Intelligence after the combined user confirmation. The AI
  workspace can import M4A, MP3, WAV, FLAC, AAC, AIFF/AIF, or CAF audio into an
  owned, non-overwriting session; edit, copy, export, and safely version transcripts; generate,
  regenerate, cancel, and edit summaries and suggested titles; and apply a
  suggested title without overwriting an existing user title. The API key is
  held only in the current Windows user's DPAPI store; Generic and HKT providers
  keep independent profiles, keys, and unsaved editor drafts;
  it is not written to recording metadata, diagnostics, or logs;
- a notification-area icon: closing the main window hides it to the tray;
  use the tray icon's right-click **Exit Teams Recorder** command to close it
  and finalize recording safely. The Windows app, package, installer, and
  tray icon are generated from the macOS `Assets/Generated/app-icon-source.png`;
- deterministic native and managed tests, JSON contract fixtures, and real
  process-audio diagnostic tools.
- crash-safe fragmented MP4 recording with an independent M4A audio safety
  track, exact-HWND Teams window capture, privacy-black gaps, and bounded
  startup recovery;
- an explicit local-only Teams automatic-recording heuristic. It starts only
  after three healthy Teams WASAPI render-session observations; silence and
  probe failure never stop a recording, and only three healthy observations
  with no Teams process can propose a stop;
- a floating recording window that can enable or disable exact Teams-window
  pixels during a recording. The session remains one MP4 and audio continues
  while disabled; disabled intervals contain privacy-black video;
- Windows input-endpoint mute monitoring that combines hardware/device mute
  with Recorder-local mute, so both the recording and virtual-microphone PCM
  publication remain muted; and live low-storage degradation that disables
  video below 1 GiB while preserving the audio recording;
- system-loopback headroom, explicit-discontinuity fades, conservative
  single-frame impulse repair, and device-confirmed QPC jitter handling.

The Windows product no longer connects to the retired Teams Third-party App API,
does not request pairing, and does not consume or persist a Teams WebSocket
token. Automatic recording is an explicit, local-only heuristic opt-in and must
not be presented as authoritative meeting state. Upgrading from a legacy API
setting does not grant consent to local monitoring. A separate, explicit
Preview opt-in can read the exact Teams `microphone-button` and gate only the
Recorder physical-microphone mix; it never invokes or changes Teams mute and
fails closed while an active Teams audio session cannot be confirmed. Exact
Teams-window video capture is available as a Draft
feature, but real Teams hardware acceptance remains a release gate. A virtual
microphone driver remains preview-only.

The AI workflow never starts without an explicit user action. The ASR dialog
describes and confirms both the selected-media upload and the automatic
transcript-only Meeting Intelligence step; manual regeneration asks again.
Managed MP4/M4A media is decoded and exported into bounded chronological ASR
chunks rather than byte-splitting a media container. Recording and upload
behaviour with the intended provider, real credentials, long recordings, and
real meeting content remain manual release gates.

The app also restores non-secret local choices after restart: the output folder,
explicit render and microphone selection, microphone on/off choice, and capture
source mode. An unavailable saved endpoint remains visibly unavailable instead
of silently switching devices. Process selection itself is not persisted: after
restart, selected-app mode requires choosing a current Teams process again.

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

## Per-user Setup.exe for another Windows computer

After the Release native bridge has been verified, create a self-contained x64
installer that does not require the target computer to have .NET installed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Build-Setup.ps1
```

The resulting installer is:

```text
windows\out\installer\TeamsRecorderSetup-1.0.0-win-x64.exe
```

It installs per-user under `%LocalAppData%\Programs\Teams Recorder`, creates a
Start Menu shortcut, and can optionally create a desktop shortcut or start the
app automatically when the installing user signs in to Windows. The startup
option is unchecked by default, creates only that user's `HKCU\...\Run` entry,
and is removed if it is disabled during an update or when the app is uninstalled.
Uninstalling the app deliberately preserves `%LocalAppData%\Teams Recorder\Sessions`,
including M4A sessions and recovery evidence. The installer also deploys the
required Microsoft VC++ runtime DLLs app-local, so it does not need to make a
machine-wide runtime installation on the target computer.

This repository does not yet have a code-signing certificate. The generated
Setup.exe is suitable for controlled internal testing, but Windows may identify
it as an unknown publisher. Do not distribute it broadly until the installer
and executable have been code-signed through the normal release process.

## Why the app is not installed by a normal build

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
