# Local Meeting Recorder

macOS SwiftUI MVP for recording meeting audio locally:

- Capture system audio routed through BlackHole or another loopback input.
- Capture a physical microphone at the same time.
- Show live RMS/peak meters, rolling waveform, silence warnings, and clipping warnings.
- Write one combined `recording.m4a` file per session.
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
