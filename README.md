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

For build-only checks:

```bash
swift build
```

If your global `xcode-select` points to Command Line Tools but Xcode is installed:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run-app.sh
```

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
