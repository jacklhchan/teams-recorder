# Local Meeting Recorder

macOS SwiftUI MVP for recording meeting audio locally:

- Capture all system audio or one selected app with ScreenCaptureKit.
- Capture a selected physical microphone in the same native capture session.
- Show live RMS/peak meters, rolling waveform, silence warnings, and clipping warnings.
- Write one combined `recording.m4a` file per session.
- Run a 10-second test recording and play it back immediately.
- Review recent recordings from inside the app.
- Transcribe recordings with an OpenAI-compatible provider.
- Publish microphone PCM to `Local Recorder Virtual Mic` for Teams.
- Follow Microsoft Teams' absolute mute state after local API pairing.
- Let the recorder app keep an independent local mic mute when needed.
- Toggle recorder mic mute with `Option + Shift + M`.

## Run

Open `Package.swift` in Xcode, select the `LocalMeetingRecorder` executable scheme, then Run.

From Terminal, prefer launching the packaged app bundle:

```bash
./scripts/run-app.sh
```

This creates and opens:

```text
build/Local Meeting Recorder Staging.app
```

To install it into `/Applications`:

```bash
./scripts/install-app.sh
```

This installs:

```text
/Applications/Local Meeting Recorder.app
```

If your global `xcode-select` points to Command Line Tools but Xcode is installed:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run-app.sh
```

## Build and Release

The commands in this section are build-only checks. They create local `.build`
or `build` artifacts but do not install or launch the app. Use the commands in
`Run` to launch or install a staging bundle.

Local staging build:

```bash
./scripts/build-app.sh
```

Repeatable release-configuration staging build:

```bash
./scripts/build-app.sh \
  --configuration release \
  --version 0.2.0 \
  --build-number 2 \
  --sign ad-hoc
```

Validate a staging bundle:

```bash
./Tests/PackagingTests/run-tests.sh
```

An ad-hoc staging build is never a production release.

Preview a signed release candidate without building:

```bash
./scripts/build-release.sh \
  --version 1.0.0 \
  --build-number 100 \
  --signing-identity "Developer ID Application: Name (TEAMID)" \
  --signed-only \
  --dry-run
```

This dry-run previews the signed-release-candidate plan only. It performs no
identity preflight, build, signing, output creation, deletion, notarization, or
network activity.

Production release requires a real Developer ID Application identity and a
configured `notarytool` Keychain profile:

```bash
./scripts/build-release.sh \
  --version 1.0.0 \
  --build-number 100 \
  --signing-identity "Developer ID Application: Name (TEAMID)" \
  --notary-profile lmr-production \
  --notary-keychain "/absolute/path/to/release.keychain-db"
```

The protected manual production workflow requires a GitHub `production`
environment with required reviewers and a main-only deployment. Configure these
six repository secrets before dispatching it:

```text
MACOS_CERTIFICATE_P12_BASE64
MACOS_CERTIFICATE_PASSWORD
MACOS_SIGNING_IDENTITY
MACOS_NOTARY_KEY_ID
MACOS_NOTARY_ISSUER_ID
MACOS_NOTARY_PRIVATE_KEY_BASE64
```

The workflow uploads a verified notarized workflow artifact only. It does not
create a GitHub Release. This repository documents local YAML and contract
validation only; the protected workflow has not been remotely dispatched or
accepted here.

Before creating a public GitHub Release, an authorized QA user must pass the
signed microphone acceptance gate with the exact notarized workflow artifact:

```text
1. Download the workflow artifact and verify its SHA-256 with:
   /usr/bin/shasum -a 256 -c <checksum-file>
2. Expand the ZIP into a temporary QA folder, not /Applications.
3. Run codesign --verify --deep --strict and spctl --assess --type execute.
4. Launch that exact candidate, grant Microphone permission when macOS asks,
   choose Mic Only mode, and record 10 seconds of speech.
5. Confirm the in-app mic waveform moves and the saved M4A is non-empty and
   audible, then quit and remove the temporary QA copy.
```

Record the tested commit SHA, artifact SHA-256, macOS version, input device,
and pass/fail in the release notes. This gate is not satisfied and cannot
currently be claimed without a real Developer ID identity and an authorized QA
run.

## Native Audio Capture

The default capture path does not require BlackHole or a system-output change.
Choose `All System Audio` or `Selected App`, then choose the microphone that
should feed both the recording and `Local Recorder Virtual Mic`.

## Recording Output

Each session creates a folder under the selected output folder:

```text
meeting-YYYY-MM-DD-HHMMSS/
└── recording.m4a
```

## Test Recording

Use `Test 10s` before joining or recording an important meeting. The app records 10 seconds, stops automatically, plays the file back, and shows a quick health summary:

- system audio detected / missing
- mic detected / missing
- clipping events
- dropped buffers

## Session List

The Recordings section scans the selected output folder for `meeting-*` and `test-*` folders with a `recording.m4a` file. You can play recent recordings, drag the playback slider to seek, stop playback, transcribe with the configured provider, or open their folder directly from the app.

## OpenAI-Compatible Transcription

Configure an OpenAI-compatible provider in the app:

1. Enter the API Base URL ending in `/v1`.
2. Enter the ASR Model identifier accepted by that provider.
3. Enter the LLM Model identifier to reserve for future meeting intelligence.
4. Enter an optional API key, language, and transcription prompt.
5. Save, then use Test to check connectivity. Model discovery is optional;
   manually entered model identifiers remain available when `/v1/models` is
   unsupported.

The app sends post-call audio chunks to:

```text
POST <API Base URL>/audio/transcriptions
```

Long recordings use silence-aware bounded chunks, rolling context, validation,
and retry. New output files are:

```text
transcript.txt
transcript.raw.txt
transcription.json
transcription.log
```

The optional provider API key and Teams pairing token are stored in macOS Keychain.
Existing local oMLX settings are read only for a one-time migration; oMLX is
not required, launched, installed, or managed by the recorder.

## Teams Auto Recording

Teams Auto Recording uses the Microsoft Teams desktop Third-party app API to
observe authoritative meeting state:

1. Enable `Settings > Privacy > Third-party app API` in Teams and complete the
   `Local Meeting Recorder` pairing request.
2. Grant macOS Screen & System Audio Recording and microphone permission before
   enabling automatic recording.
3. Enable `Teams Auto Recording` in the recorder.
4. Joining a meeting shows a silent, cancellable five-second countdown.
   `Cancel` suppresses automatic recording only for the current meeting, until
   that meeting ends.
5. Leaving stops only a recording that was started automatically, and only
   after Teams reports that the meeting has ended continuously for ten seconds.
   Rejoining during that debounce keeps the recording running.
6. A Teams API disconnect never stops an active recording.
7. Screen capture starts off and remains a manual control. It can be enabled
   during an active recording.
8. `Teams Mute Sync` is independent of Teams Auto Recording and may remain
   disabled.
9. Manual recordings are never auto-stopped. Manually stopping an
   automatically started recording suppresses automatic restart for the rest of
   the same meeting.

## Mic Mute

The recorder always applies mute to both its local microphone track and
`Local Recorder Virtual Mic`.

Use either:

```text
Option + Shift + M
```

or the `Mute Recorder Mic` button.

To make an AirPods mute press affect both Teams and the recorder:

1. Select `Local Recorder Virtual Mic` as the Teams microphone.
2. Enable `Settings > Privacy > Third-party app API` in Teams.
3. Join a Teams call and allow the `Local Meeting Recorder` pairing request.
4. Keep `Teams Mute Sync` enabled in the recorder.

The integration reads Teams' absolute mute state and never sends
`toggle-mute`, so duplicate updates cannot flip the state twice.
While a call is active, a lost or half-open Teams API connection fails closed:
the recorder microphone track and virtual microphone stay muted until a fresh
absolute Teams state arrives.

If Teams reports that the recorder is already paired but the local token is
missing, open `Manage API`, block and forget the old Local Meeting Recorder
entry, then use the retry button in the recorder.

## Current MVP Limits

- Teams mute sync depends on the desktop Third-party app API being present and
  allowed by the signed-in tenant policy.
- Transcription is post-call and file based, not streaming.
- Speaker diarization is not yet included.

## License

Local Meeting Recorder is available under the Apache License 2.0. See
`LICENSE` and `THIRD_PARTY_NOTICES.md`.

The Apple-derived virtual microphone sample material retains the separate
license in `Driver/LocalRecorderVirtualMic/LICENSE-Apple-Sample.txt`.
