# Local Meeting Recorder

macOS 26.0 or newer SwiftUI app for recording meeting audio locally:

- Capture all system audio or one selected app with ScreenCaptureKit.
- Capture a selected physical microphone in the same native capture session.
- Show live RMS/peak meters, rolling waveform, silence warnings, and clipping warnings.
- Write a validated `recording.mp4` file, with an audio-only recovery fallback.
- Run a 10-second test recording and play it back immediately.
- Browse and search the complete recording library from inside the app.
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

## Local Control Status

`recorderctl status` and `recorderctl watch` provide a deliberately limited
local-control snapshot. Their human and JSON output include typed recorder,
Auto Mode, mute, virtual-microphone, permission, and selected microphone display
name state. Absolute recording/output paths, microphone UIDs, provider settings,
prompts, transcripts, credentials, bookmark data, and arbitrary app status text
are intentionally omitted. Storage is reported only as a finite state and
operation status uses a fixed code.

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
seven repository secrets before dispatching it:

```text
MACOS_CERTIFICATE_P12_BASE64
MACOS_CERTIFICATE_PASSWORD
MACOS_SIGNING_IDENTITY
MACOS_NOTARY_KEY_ID
MACOS_NOTARY_ISSUER_ID
MACOS_NOTARY_PRIVATE_KEY_BASE64
RELEASE_MANIFEST_ED25519_PRIVATE_KEY_BASE64
```

The workflow uploads a verified notarized workflow artifact only. It does not
create a GitHub Release. This repository documents local YAML and contract
validation only; the protected workflow has not been remotely dispatched or
accepted here.

Release-manifest operational handoff remains required: a release owner must
provide the real public key/key ID in the pinned keyring, authorize custody of
the production private seed, and define the authoritative channel, key
rotation/revocation, and rollback-floor policy.  The committed keyring is
intentionally empty; production manifest verification fails closed and this is
not production-ready.

Before creating a public GitHub Release, an authorized QA user must pass the
signed microphone acceptance gate with the exact notarized workflow artifact.
Use the repository-pinned keyring and a release-owner supplied rollback floor:

```text
1. Download the workflow artifact and verify its signed manifest with:
   scripts/verify-release-manifest.sh --manifest <manifest-file> --signature <signature-file> --zip <zip-file> --minimum-build <approved-floor>
2. Verify its portable SHA-256 with:
   /usr/bin/shasum -a 256 -c <checksum-file>
3. Expand the ZIP into a temporary QA folder, not /Applications.
4. Run codesign --verify --deep --strict and spctl --assess --type execute.
5. Launch that exact candidate, grant Microphone permission when macOS asks,
   choose All System Audio or Selected App, select the test microphone, and
   record 10 seconds of speech.
6. Confirm the in-app mic waveform moves and the saved MP4 is non-empty and
   audible. If media recovery was required, validate the M4A fallback instead,
   then quit and remove the temporary QA copy.
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
├── recording.mp4
├── recording.m4a             # audio-only recovery fallback, when required
└── recording-info.json
```

`recording.mp4` is the primary completed media file. `recording.m4a` is the
`recording.m4a` audio-only recovery fallback and is not created for every
successful recording.

`recording-info.json` follows
`contracts/recording-session.schema.json`. It includes a `schemaVersion`,
recording source (`manual`, `teamsAutomatic`, or `imported`), media and recovery
details, and optional meeting metadata. Unknown metadata fields are preserved
when an older app edits and saves a newer or cross-platform file.

## Test Recording

Use `Test 10s` before joining or recording an important meeting. The app records 10 seconds, stops automatically, plays the file back, and shows a quick health summary:

- system audio detected / missing
- mic detected / missing
- clipping events
- dropped buffers

## Session List

The Recordings section scans the selected output folder for `meeting-*`,
`test-*`, and imported session folders containing supported completed media.
There is no fixed 12-session display cap. Search covers title, tags, transcript,
date, meeting type, participants, and recording source; transcript matches show
a bounded snippet. You can filter favorites, play recordings, drag the playback
slider to seek, stop playback, transcribe with the configured provider, or open
their folder directly from the app.

## OpenAI-Compatible Transcription and Meeting Intelligence

Choose one saved provider preset in Settings. Each preset retains its own ASR
Model, LLM Model, meeting language, prompt, and Keychain credential. Switching
presets reloads its saved values and does not overwrite the other preset.

- `HKT GenAI Platform` takes a numeric Group ID (1–32 ASCII digits) and derives
  the fixed, read-only endpoint
  `https://api.uat.bot-builder.pccw.com/v1/groups/{groupID}/openai`. Its
  credential is sent only as `X-API-KEY: <key>`.
- `OpenAI-compatible API` takes an API Base URL ending in `/v1` (validated HTTPS
  or loopback). Its credential is sent only as `Authorization: Bearer <key>`.

Do not enter a real Group ID or API key in source files, fixtures, diagnostics,
or screenshots. The app stores each optional provider API key in macOS Keychain.

Enter the ASR Model identifier and LLM Model identifier accepted by the selected
provider, plus an optional API key, language, and transcription prompt. ASR
Model transcribes audio. LLM Model generates meeting summaries and contextual
titles; the models may be the same or different identifiers. Meeting Language
offers Cantonese (`yue`), English (`en`), and Mandarin (`zh`). A saved language
change applies to future ASR jobs only; an active job retains its immutable
snapshot.

Use Save, then Test to check connectivity and model discovery. Model discovery
is optional: manually entered model identifiers remain available when
`/v1/models` is unsupported. An exact `/models` match for the selected LLM
Model is required only for automatic meeting intelligence. Unknown, unavailable,
or unsupported
discovery sends zero automatic chat requests. Generate and Regenerate are
explicit and may still be attempted when discovery is unavailable.

The app sends post-call audio chunks to:

```text
POST <API Base URL>/audio/transcriptions
```

Production transcription is implemented in Swift. Native `AVFoundation`
performs duration probing and bounded M4A chunk export, while `URLSession`
performs multipart upload with response-size limits, redirect validation, and
typed cancellation. The packaged app does not require Python, FFmpeg, or FFprobe.

Long recordings use bounded fixed-duration chunks, rolling context, validation,
and retry. HTTP 408, 429, 5xx responses and selected transient network failures
use the same bounded retry budget; HTTP responses honor `Retry-After`. Other 4xx
configuration errors and permanent transport failures stop immediately.
Providers that reject `verbose_json` are retried once with `json`. New output
files are:

```text
transcript.txt
transcript.raw.txt
transcription.json
transcription.log
```

Native audio chunks use an isolated system temporary workspace that is removed
after the job completes or is cancelled. `.transcription-runs` is a legacy
workspace only: retention cleanup removes expired legacy run directories.
Successful native jobs keep only the four canonical artifacts above plus
bounded previous transcript backups. `transcription.log` is a fixed,
structured diagnostic record; it does not contain paths, prompts, transcript
text, provider URLs, credentials, or raw errors. Failure diagnostics use the
same typed allowlist. New app-owned transcription artifacts request owner-only
permissions where supported. Logs and provider responses are capped, and
credentials are not written to transcript artifacts.

Existing local oMLX settings are read only for a one-time migration; oMLX is
not required, launched, installed, or managed by the recorder.

The optional provider API key and Teams pairing token are stored in macOS Keychain.

## Meeting Intelligence Results

After a canonical transcript is published, an advertised LLM can automatically
generate a bounded summary and contextual title. A transcript edit marks an
existing result stale; it never triggers a new automatic request. Use Generate
or Regenerate from the transcript detail when you want a later or replacement
attempt, and Cancel to stop an active availability or generation attempt.

Successful output is stored as `meeting-intelligence.json`; bounded lifecycle
presentation is stored separately as `meeting-intelligence-state.json`. These
artifacts contain the summary, suggested title, transcript digest and byte
count, model, timestamp, and the exact initiating intent: `automatic`,
`generate`, `regenerate`, or `retryGeneration`. They never contain a
credential, provider base URL, prompt, raw transcript, raw response, or local
path. There is no generic `manual` artifact intent. The schema advertises a
512-character model identifier ceiling; the runtime's stricter 512 UTF-8 byte
limit is authoritative.

Generated titles are applied only when title ownership permits it. Existing
manual titles are preserved, including a deliberate manual blank; a new result
is shown as a suggestion until the user chooses Apply Suggested Title. A later
manual title edit remains manual. The packaged app contains no Python, FFmpeg,
FFprobe, or development-only synthetic provider runtime helper.

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
