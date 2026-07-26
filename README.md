# Local Meeting Recorder

macOS SwiftUI MVP for recording meeting audio locally:

- Capture all system audio or one selected app with ScreenCaptureKit.
- Capture a selected physical microphone in the same native capture session.
- Show live RMS/peak meters, rolling waveform, silence warnings, and clipping warnings.
- Write one combined `recording.m4a` file per session.
- Run a 10-second test recording and play it back immediately.
- Review recent recordings from inside the app.
- Trigger local Qwen ASR transcription from each recording row.
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
build/LocalMeetingRecorder.app
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

The Recordings section scans the selected output folder for `meeting-*` and `test-*` folders with a `recording.m4a` file. You can play recent recordings, drag the playback slider to seek, stop playback, transcribe with Qwen ASR, or open their folder directly from the app.

## Qwen ASR Transcription

The transcript button opens oMLX and runs the local MLX Qwen ASR pipeline against the selected `recording.m4a`.

Current local defaults:

```text
ASR workspace: /Users/apple/Documents/AIA ASR
Model: aufklarer/Qwen3-ASR-1.7B-MLX-8bit
Language: yue
Output: transcript_qwen3_asr_1_7b_8bit_yue_trad.txt
```

The app packages `scripts/transcribe-qwen-asr.sh` into the app bundle and calls it from the recording row. This currently uses direct `mlx_audio.stt.generate` execution, not an OminiX `/v1/audio/transcriptions` server.

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
- The current Teams pairing token is stored in the app's local user defaults;
  Keychain migration is intentionally deferred.
- Transcription is post-call and file based, not streaming.
- Speaker diarization is not yet included.
