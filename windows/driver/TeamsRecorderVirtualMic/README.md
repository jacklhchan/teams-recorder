# Teams Recorder Virtual Microphone — test-signed preview scaffold

This folder contains the reviewable kernel producer-ring source and a
reproducible patch over a pinned Microsoft SysVAD commit. It deliberately does
**not** contain a prebuilt or trusted kernel binary. The result remains an
opt-in, test-signed preview only: Release builds compile the application-side
feature gate as disabled, and the normal installer must not include it.

## Identity contract

The driver package uses the exact hardware ID `ROOT\TeamsRecorderVirtualMic`,
service name `TeamsRecorderVirtualMic`, capture flow, and Core Audio friendly
name `Teams Recorder Virtual Microphone`; see
[`endpoint-identity.json`](endpoint-identity.json). The Core Audio endpoint ID
is intentionally not hard-coded: Windows assigns it when it creates the
endpoint. A pairing must record the exact allocated endpoint ID after
installation. The application accepts a preview only when all of these hold:

1. the test-preview compile gate is enabled (Debug only);
2. the caller presents the expected hardware/friendly-name contract;
3. endpoint enumeration contains exactly that paired endpoint ID;
4. it is a capture endpoint with the exact friendly name; and
5. a current-user, bounded PCM broker handshake succeeds.

A display-name match by itself is explicitly insufficient, so a friendly-name
spoof cannot enable audio routing.

## Reproducible driver overlay

The development environment currently has Windows SDK 10.0.26100 but not the
Windows Driver Kit (WDK); in particular,
`WindowsDriver.common.targets` is absent. Microsoft documents that
[SysVAD requires Visual Studio, Windows SDK, and WDK](https://learn.microsoft.com/en-us/samples/microsoft/windows-driver-samples/sysvad-virtual-audio-device-driver-sample/),
and that deployment/testing is normally performed on a separate test machine.
The pinned upstream source and the required patch/verification steps are recorded in
[`sysvad-dependency.lock.json`](sysvad-dependency.lock.json) and
[`SysVadPatchContract.md`](SysVadPatchContract.md).

Run `scripts/Test-DriverPreflight.ps1` before attempting any driver build. It
fails with a specific WDK error instead of falling back to the Windows SDK.

On a WDK-equipped x64 test machine, `scripts/Build-TestSignedPreview.ps1`
bootstraps the locked source, applies the capture-only endpoint/PCM/control
overlay, and creates an unsigned package below `out/package`. Review the
generated SysVAD diff and then use the separate signing script; the build
script never trusts or installs the result.

## Test-signing safety boundary

The scripts are intentionally separate and explicit:

- `New-TestCertificate.ps1` creates a *CurrentUser* code-signing certificate
  and exports a PFX/CER below this folder's ignored `out/test-signing` path.
- `Install-TestCertificate.ps1` can import the exact CER into either
  CurrentUser stores or, only after an explicit acknowledgement and elevation,
  LocalMachine Root and TrustedPublisher on a disposable test computer.
- `Sign-DriverPackage.ps1` accepts only the folder
  `out/package` and signs its catalog and one expected `.sys` file.
- `Install-TestSignedPreview.ps1` requires an explicit acknowledgement,
  elevation, a WDK `devcon.exe`, and the exact hardware ID. It never calls
  `bcdedit`, never enables test-signing, and never changes Secure Boot,
  BitLocker, or any global security setting.
- `Uninstall-TestSignedPreview.ps1` removes only
  `ROOT\TeamsRecorderVirtualMic`; removal of a test certificate is a separate,
  explicitly acknowledged operation.

If test-signing has not already been enabled by the operator on a disposable
test machine, installation stops rather than changing boot configuration.
[Windows only loads test-signed kernel code after test-signing is enabled](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/the-testsigning-boot-configuration-option),
and Microsoft requires a trusted test certificate for a test-signed package.

## Acceptance boundary

The companion app code and its independent tests live under
`windows/src/Recorder.Application/VirtualMic` and
`windows/tests/Recorder.VirtualMicPreview.Tests`. Run
`windows/scripts/Test-VirtualMicPreview.ps1` to verify:

- endpoint/name spoof and absent-endpoint rejection;
- bounded protocol parsing and frame sizing;
- a successful test-only current-user broker round trip;
- Release compilation has the test driver disabled; and
- missing WDK emits the deliberate preflight error.

After a test-signed endpoint has been installed, pair the exact Core Audio
capture endpoint ID for the current user (never copy only the friendly name):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Pair-TestSignedPreview.ps1 `
  -EndpointId '{0.0.1.00000000}.{WINDOWS-ALLOCATED-GUID}'
```

Build the app and its isolated broker only as the explicit Debug preview:

```powershell
dotnet build ..\..\src\Recorder.WinUI\Recorder.WinUI.csproj `
  -c Debug -p:EnableTestSignedVirtualMicPreview=true
```

At runtime the native mixer publishes microphone-only 48 kHz stereo PCM after
recorder-local mute. A bounded app queue sends it over a current-user pipe to
`Recorder.VirtualMicBroker.exe`; only that process opens
`\\.\TeamsRecorderVirtualMicControl`. Virtual-microphone failure never stops or
changes the authoritative local recording.

No result from those tests means a kernel driver was built, signed, trusted, or
installed. Those claims require the WDK build and the hardware/HLK checks in
the patch contract.
