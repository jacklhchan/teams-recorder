# Local Meeting Recorder Self-Service Distribution Design

> **Superseded on 2026-07-28. Do not execute this plan.**
> Local Meeting Recorder now uses native ScreenCaptureKit capture and a
> user-configured OpenAI-compatible provider. The application does not install
> BlackHole, oMLX, provider binaries, or models.

Date: 2026-07-20
Status: Approved for implementation planning

## Summary

Local Meeting Recorder will be distributed to internal Apple Silicon users as a
single ad-hoc-signed DMG. The recorder app will contain a first-run Setup
Assistant that guides a non-technical user through installing BlackHole,
installing and configuring oMLX, downloading the Qwen ASR model, configuring
audio routing, granting microphone permission, and running an end-to-end test.

The first target is an M1 MacBook running macOS 15 or newer. The user has local
administrator rights, normal access to GitHub and Hugging Face, and must be able
to complete setup without Terminal.

## Goals

- Deliver one `Local Meeting Recorder.app` inside one DMG.
- Make first-time setup and repair possible through GUI actions only.
- Detect actual dependency health instead of trusting stored completion flags.
- Keep recordings in the current user's Downloads folder by default.
- Preserve the existing recording, playback, manual upload, and transcription
  features.
- Provide actionable progress, errors, retries, and privacy-safe diagnostics.
- Keep oMLX, Qwen model data, recordings, and user settings across recorder app
  upgrades.

## Non-Goals

- Mac App Store distribution.
- Apple notarization or Developer ID signing in the first release.
- Bundling or redistributing BlackHole inside the recorder DMG.
- Silent installation of privileged audio drivers.
- Fully automatic creation of a Multi-Output Device using private macOS APIs.
- Automatic background updates in the first release.
- Intel Mac or macOS 14 support.

## Distribution Model

The release pipeline produces:

```text
Local-Meeting-Recorder-<version>-arm64.dmg
SHA256SUMS.txt
release-manifest.json
```

The app uses the stable bundle identifier `local.meeting.recorder` and an
ad-hoc code signature. The DMG presents the app and an Applications shortcut.
The user drags the app into Applications and uses Finder's `Open` command on
first launch to acknowledge the unidentified-developer warning.

The app does not create or expose a staging app in the release artifact. Build
and test bundles keep a different bundle identifier and are never launched as
part of the end-user workflow.

Because the first release has no Developer ID signature, macOS may request
microphone permission again after some binary updates. The Setup Assistant must
detect this state and explain how to restore permission through System
Settings.

## Setup Assistant Architecture

The recorder remains a single app. Its root view selects between the Setup
Assistant and the existing recorder UI. A completed setup can be reopened from
Settings using `Run Full Check` or `Repair Setup`.

The Setup Assistant is coordinated by a `SetupCoordinator`. Each dependency is
represented by an independently testable checker and action provider:

1. `SystemCompatibilityChecker`
   - Confirms Apple Silicon and macOS 15 or newer.
   - Confirms network reachability for required hosts.
   - Confirms enough free disk space before model download.

2. `BlackHoleSetupService`
   - Detects an available Core Audio device named `BlackHole 2ch`.
   - Opens the official BlackHole installer source when missing.
   - Never receives or stores the administrator password.
   - Rechecks Core Audio after installation and reports when restart or logout
     is required.

3. `OMLXSetupService`
   - Detects `/Applications/oMLX.app` and validates a supported version.
   - Opens a pinned official oMLX release when installation is required.
   - Starts oMLX and probes `http://127.0.0.1:8000`.
   - Detects a port conflict separately from an unhealthy oMLX process.
   - Generates a per-Mac API key, stores it in Keychain, and synchronizes the
     expected oMLX setting without embedding the developer's key in the app.

4. `QwenModelSetupService`
   - Targets `mlx-community/Qwen3-ASR-1.7B-4bit` at a pinned revision.
   - Uses the supported oMLX model-management path where available.
   - Falls back to opening the oMLX model UI with exact instructions if the
     installed oMLX version does not provide a stable management API.
   - Reports download size, progress, transfer rate, cancellation, and retry.
   - Treats the model as ready only after the authenticated oMLX `/v1/models`
     response contains the expected model identifier.

5. `AudioRoutingSetupService`
   - Detects BlackHole, the selected physical output, and a valid Multi-Output
     Device.
   - Opens Audio MIDI Setup and provides in-app, step-by-step GUI guidance.
   - Continuously rechecks configuration while Audio MIDI Setup is open.
   - Enables automatic creation only if a supported public Core Audio API is
     proven reliable on the target macOS version; guided setup remains the
     fallback.

6. `SetupVerificationService`
   - Requests microphone permission only after the app is in Applications.
   - Runs the existing 10-second recording test.
   - Verifies system audio, microphone audio, file output, playback, oMLX API,
     and a short Qwen transcription.

Checker protocols expose values rather than owning SwiftUI state. This keeps
the coordinator, UI, and dependency probes independently testable.

## Setup Flow

The ordered first-run flow is:

```text
System Check
  -> BlackHole
  -> oMLX
  -> Qwen Model
  -> Audio Routing
  -> Microphone Permission
  -> Recording and ASR Test
  -> Recorder
```

The user can leave and resume setup. On resume, every completed step is probed
again. Stored state may preserve download resume data and the last viewed step,
but it cannot independently mark a dependency as ready.

Each step uses one of these user-visible states:

```text
notInstalled
checking
downloading(progress)
waitingForUser
restartRequired
startingService
loadingModel
ready
failed(recoverableError)
```

Only one privileged or long-running setup action may execute at a time.
Recording and transcription controls remain disabled while setup is incomplete
or a repair action affects their dependency.

## Data Locations

All current `/Users/apple/...` assumptions must be removed.

```text
Recorder settings and setup state:
~/Library/Application Support/Local Meeting Recorder/

Recorder secrets:
macOS Keychain

oMLX settings and model cache:
oMLX-managed locations under the current user's home directory

Default recordings and manual imports:
~/Downloads/
```

The transcription scripts must use the current user's home directory and the
packaged app resources. They must not require `/Users/apple/Documents/AIA ASR`,
a developer checkout, or a developer-created Python virtual environment.

## Download Integrity and Security

The app ships a release manifest containing supported dependency versions,
official HTTPS origins, pinned model revision, expected file sizes, and
available cryptographic hashes. It must not resolve an unpinned `latest` URL at
installation time.

- Preserve macOS quarantine metadata for third-party installers.
- Verify downloaded artifacts before opening them.
- Fail closed when an expected hash does not match.
- Never request, capture, or log the macOS administrator password.
- Never ship the current development API key (`1234`) or any other shared key.
- Store the generated oMLX API key in Keychain.
- Redact authorization headers, API keys, and sensitive paths from exported
  logs where practical.
- Do not include recordings or transcripts in diagnostic exports.

BlackHole remains an external official install because its project documents
separate licensing requirements for integration into non-GPL applications.

## Error Recovery

Errors must name the failing component and offer a concrete next action. The
following cases require dedicated handling:

- Network unavailable: preserve partial download and offer retry.
- Insufficient disk space: show required and available space before download.
- Checksum mismatch: discard only the invalid temporary artifact and redownload.
- BlackHole installed but unavailable: offer restart guidance and recheck.
- oMLX missing: reopen the pinned official installer source.
- oMLX not running: launch it and display startup progress.
- Port 8000 occupied by another process: identify the port conflict without
  sending the API key to that process.
- API key mismatch: repair the local recorder and oMLX settings, then reprobe.
- Model partially downloaded: resume rather than restart where supported.
- Model present but not loadable: preserve files, show oMLX error, and offer a
  model verification or redownload action.
- Microphone denied: deep-link to the correct System Settings privacy pane and
  recheck when the app becomes active.
- Test recording has no system or microphone level: route the user back to the
  specific audio setup step.

Repair actions must be idempotent. A retry must not delete a healthy model,
recording, transcript, or unrelated oMLX configuration.

## Updates

The first release does not include automatic updates. A new DMG replaces the
app in Applications while preserving data outside the bundle.

- Recorder updates must not modify oMLX or model data automatically.
- oMLX and model updates must not run during recording or transcription.
- Dependency updates require compatibility validation and explicit user action.
- BlackHole updates are presented as official external updates.
- An app update must rerun health probes and show only the steps requiring
  repair.

## Diagnostics

Settings provides:

- `Run Full Check`
- `Repair Setup`
- `Export Diagnostics`

The diagnostic export includes app version, macOS version, CPU architecture,
audio device names, selected routing, dependency versions, sanitized setup
events, oMLX reachability, expected model identifier, and recent sanitized
errors. It excludes recordings, imported audio, transcripts, API keys,
authorization headers, and passwords.

## UI Requirements

- The Setup Assistant is a compact operational workflow, not a marketing page.
- A persistent step list shows current, completed, failed, and blocked steps.
- Each step has one primary action and an optional secondary help action.
- Long downloads display determinate progress whenever total size is known.
- Closing the window does not silently cancel a model download.
- Restart-required state survives app relaunch.
- Error details are selectable and can be included in the diagnostic export.
- The recorder UI clearly links back to setup when a required dependency later
  becomes unhealthy.

## Verification Strategy

Unit tests cover checker state mapping, setup state transitions, manifest
validation, user-path resolution, secret redaction, retry behavior, and
diagnostic filtering. Network and oMLX interactions use protocol-backed test
doubles.

Integration tests cover:

- Missing, healthy, and incompatible oMLX installations.
- oMLX startup, authentication failure, port conflict, and model readiness.
- Model download interruption, resume, checksum failure, and low disk space.
- BlackHole and Multi-Output Device detection from mocked Core Audio inventory.
- Microphone permission states.
- Existing recording, playback, upload, and transcription behavior after setup
  integration.

A clean-account acceptance pass on an M1 MacBook running macOS 15 or newer must
verify:

1. The DMG opens and the app can be copied to Applications.
2. Finder `Open` is sufficient to pass the first-run Gatekeeper warning.
3. BlackHole installation completes through the official macOS installer.
4. oMLX installs, starts, authenticates, and survives app relaunch.
5. The pinned Qwen model downloads and becomes visible through `/v1/models`.
6. The user can complete Multi-Output routing without Terminal.
7. The 10-second test detects system and microphone audio.
8. A recording can be played, manually imported, and transcribed.
9. Replacing the recorder app from a newer DMG preserves recordings, setup
   data, oMLX, and model files.
10. Exported diagnostics contain no recording, transcript, password, or API key.

## Acceptance Criteria

The self-service distribution is complete when:

- A non-technical administrator user completes clean-Mac setup without Terminal.
- The release contains only one end-user recorder app.
- No runtime path contains the developer username or checkout location.
- BlackHole and oMLX are obtained from pinned official sources.
- The per-Mac oMLX API key is generated locally and never included in the DMG.
- Setup progress and failures remain visible and recoverable after relaunch.
- Model readiness is proven through the authenticated oMLX API.
- The end-to-end 10-second recording and ASR test passes.
- The existing Swift test suite and new setup tests pass.
- The DMG checksum is generated and verified as part of the release process.

## Reference Sources

- BlackHole: https://github.com/ExistentialAudio/BlackHole
- oMLX: https://github.com/jundot/omlx
- Qwen ASR model: https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit
