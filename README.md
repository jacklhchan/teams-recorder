# Local Meeting Recorder

macOS SwiftUI MVP for recording meeting audio locally:

- Capture system audio routed through BlackHole or another loopback input.
- Capture a physical microphone at the same time.
- Show live RMS/peak meters, rolling waveform, silence warnings, and clipping warnings.
- Write one combined `recording.m4a` file per session.
- Run a 10-second test recording and play it back immediately.
- Review recent recordings from inside the app.
- Trigger local Qwen ASR transcription from each recording row.
- Check BlackHole, Multi-Output Device, and save-folder readiness.
- Let the recorder app own the mic-track mute state.
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

## BlackHole Setup

1. Install BlackHole 2ch.
2. Open macOS Audio MIDI Setup.
3. Create a Multi-Output Device.
4. Add your real output device and BlackHole 2ch.
5. Route macOS or Teams speaker output to that Multi-Output Device.
6. In this app, select BlackHole 2ch as System audio.
7. Select your physical microphone as Microphone.

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

## Routing Assistant

The Routing Assistant checks:

- BlackHole is installed and visible
- System audio source is BlackHole
- macOS default output is a Multi-Output Device
- system alerts output is a Multi-Output Device
- save folder is writable

Use the `Audio MIDI` button to open macOS Audio MIDI Setup.

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

Teams mute state is not treated as a reliable local API. The recorder app uses its own mic-track mute as source of truth.

Use either:

```text
Option + Shift + M
```

or the `Mute Recorder Mic` button.

This mutes the mic track in the local recording. It does not control Microsoft Teams' own mute button.

## Current MVP Limits

- Combined audio pairs recent system and mic buffers. Long-session drift correction is not implemented yet.
- There is no virtual microphone proxy.
- There is no transcription, diarization, cloud upload, or meeting summary.
- Recorder mic mute does not mute your microphone inside Teams.
