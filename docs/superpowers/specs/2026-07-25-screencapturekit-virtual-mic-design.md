# ScreenCaptureKit Capture and Virtual Microphone Design

Date: 2026-07-25

## Objective

Replace the recorder's BlackHole and Multi-Output Device workflow with native
macOS audio capture that does not change the user's speakers or headphones.
Add a local virtual microphone so an AirPods mute gesture can silence both the
recorded microphone and audio sent to Microsoft Teams while Teams remains
unmuted.

This work targets the existing macOS 15+ SwiftUI application and preserves its
single-file recording, waveform, playback, library, health, and transcription
features.

## Scope

The work is delivered in two independently testable milestones:

1. Native system and application audio capture with ScreenCaptureKit.
2. A local Core Audio virtual microphone and AirPods-controlled mute path.

The first delivery is for local development use on the user's Mac. Developer ID
distribution, notarization, automatic updates, public packaging, and broader
installer hardening are deferred. Normal permission handling, failure-safe
silence, bounded buffers, and realtime-thread safety remain required.

The abandoned self-service distribution work is not resumed. The one-time
virtual microphone setup is a separate runtime dependency required by this
feature.

## Capture Modes

The recorder provides two mutually exclusive modes:

- **All System Audio** captures audio from all applications while excluding the
  recorder's own process.
- **Selected App** captures one running application chosen from a searchable
  list.

All System Audio is the default. The system output device is never changed.
Audio continues playing through the user's current speakers, wired headphones,
or AirPods.

Selected App stores the chosen bundle identifier. On a later launch, the app
may resolve that identifier to a current `SCRunningApplication`, but it does not
silently reconnect during an active recording. If the selected process exits,
system audio becomes silence, microphone capture and file recording continue,
and the UI reports `App audio disconnected`. The user explicitly invokes
`Reconnect` after the application relaunches.

## Phase 1 Architecture

`SCShareableContent` supplies displays and running applications. A display is
used as the ScreenCaptureKit filter boundary even though the recorder does not
consume video:

- All System Audio uses a display filter that excludes the recorder process.
- Selected App uses a display filter that includes one
  `SCRunningApplication`.

One `SCStream` has `capturesAudio` and `captureMicrophone` enabled. It registers
only `.audio` and `.microphone` outputs; it does not register a `.screen` output.
The system stream is configured for 48 kHz stereo and excludes current-process
audio. The selected Core Audio microphone UID is passed through
`microphoneCaptureDeviceID`.

Each valid `CMSampleBuffer` is converted to non-interleaved Float32 PCM. System
audio and microphone audio are normalized to 48 kHz stereo and retained with
their presentation timestamps. A timestamp-aware mixer:

- aligns the two sources by presentation time;
- inserts silence for missing intervals;
- avoids pairing unrelated buffers merely by arrival order;
- applies microphone mute before mixing;
- applies the existing source gains and soft limiter;
- writes one 48 kHz, stereo, 192 kbps AAC `recording.m4a`.

Waveform and health analysis consume the normalized source buffers before the
final mix. Health records missing signals, clipping, conversion failures,
underruns, overruns, dropped samples, source disconnects, and stream failures.

## Phase 1 User Interface

The BlackHole input picker, Multi-Output guidance, Routing Assistant, and Audio
MIDI Setup action are removed from the application runtime UI.

They are replaced with:

- an `All System Audio` / `Selected App` segmented control;
- a single-application picker and refresh action in Selected App mode;
- a microphone picker;
- permission status for Screen & System Audio Recording and microphone access;
- live connection and signal status for system/application audio and microphone;
- a `Reconnect` action when the selected application exits.

The app does not begin capture when required permission is denied or no valid
source exists. It explains the exact missing permission and provides an action
to open the relevant System Settings pane. If macOS requires the app to restart
after permission is granted, the UI states this directly.

## Phase 2 Architecture

Phase 2 adds a 48 kHz mono Core Audio input device named
`Local Recorder Virtual Mic`. Microsoft Teams selects this device once as its
microphone and may keep its own mute state unmuted.

Only physical microphone audio is sent to the virtual device. Captured system
or Teams audio is never routed into the virtual microphone, preventing an echo
or feedback path.

The recorder publishes normalized microphone PCM into a bounded, lock-free
shared-memory ring buffer. The Core Audio driver's realtime read callback:

- performs no file, network, allocation, logging, or blocking work;
- reads only complete available frames;
- emits silence on underrun, missing producer, mute, disconnect, or app crash;
- never repeats stale frames;
- advances its clock continuously even while outputting silence.

When the producer outruns the driver, the bridge drops the oldest unread frames
and increments an overrun counter. Driver and app expose connection, underrun,
and overrun health without doing UI or logging work on the realtime callback.

A one-time local setup installs the driver in the macOS Core Audio HAL plug-in
location and reloads Core Audio. The user supplies administrator authentication
directly through macOS or an interactive terminal. The application and scripts
do not receive, embed, store, or log the password.

## AirPods and Mute Semantics

The recorder registers one macOS `AVAudioApplication` input mute state change
handler. Compatible AirPods or Beats mute gestures, the in-app mute button, and
`Option+Shift+M` converge on this application-level mute state.

When muted:

1. microphone samples are zeroed before entering the meeting mixer;
2. microphone samples are zeroed before entering the virtual microphone ring
   buffer;
3. microphone waveform and UI show muted state;
4. ScreenCaptureKit and driver clocks continue running.

Consequently, the recording contains no microphone speech and Teams receives
silence through `Local Recorder Virtual Mic`, even though Teams remains
unmuted. The recorder does not read, write, or claim to synchronize Teams'
internal mute state.

If a connected headset does not generate the macOS input mute callback, the
in-app button and keyboard shortcut remain available. The UI labels the state
`Recorder + Virtual Mic Muted` so it cannot be confused with Teams' own mute
indicator.

## Failure Handling

- **Screen/System Audio permission denied:** capture does not start; the app
  identifies the permission and links to System Settings.
- **Microphone permission denied:** capture does not start when microphone
  recording is enabled.
- **Selected application unavailable at start:** recording does not start until
  a valid application is chosen.
- **Selected application exits during recording:** system audio becomes silence;
  microphone and recording continue; reconnect is explicit.
- **Microphone or AirPods disconnects:** system audio continues; recorded mic and
  virtual mic become silence; the UI reports the disconnect.
- **Virtual driver unavailable:** normal recording remains available; Virtual
  Mic reports unavailable and Teams routing is not claimed ready.
- **Recorder exits or crashes:** the driver emits silence.
- **Buffer conversion or stream failure:** the UI and final health report expose
  the failure; the app never reports successful capture solely because a file
  was created.

## Testing Strategy

Development follows test-driven implementation for deterministic components.

Unit tests cover:

- capture-mode and source-selection policy;
- persisted bundle identifier resolution;
- timestamp alignment, silence insertion, gain, mute, and limiter behavior;
- disconnect and reconnect state transitions;
- mute fan-out to recording and virtual microphone outputs;
- health counters and user-facing status mapping.

Driver and bridge tests cover:

- ring-buffer wraparound;
- concurrent producer/consumer stress;
- underrun silence;
- overrun drop-oldest behavior;
- producer restart without stale-frame replay;
- mute transitions at arbitrary frame boundaries.

Integration tests use generated tones to verify source isolation, conversion,
timestamp alignment, channel mapping, and output duration without requiring a
live meeting.

Live acceptance on the user's Mac covers:

- system audio capture while macOS output remains unchanged;
- Selected App isolation while a second application also plays audio;
- combined system and microphone audio in one `recording.m4a`;
- selected-app exit behavior;
- microphone disconnect behavior;
- AirPods gesture mute and unmute;
- Teams test-call audio through `Local Recorder Virtual Mic`;
- recorder termination causing immediate virtual-mic silence;
- a recording of at least 30 minutes without periodic ticks, material drift, or
  unexplained capture termination.

## Delivery and Parallel Work

Subagents may work in parallel only on isolated ownership boundaries. Planned
workstreams are:

- ScreenCaptureKit source discovery, filtering, and permission state;
- timestamped PCM conversion and mixer tests;
- virtual driver and shared ring buffer;
- SwiftUI integration and state persistence;
- independent review and acceptance-test preparation.

The main agent owns shared interfaces, integration, full test runs, app and
driver installation, live verification, and Git history. Changes are committed
at milestone boundaries:

1. ScreenCaptureKit capture replacing the BlackHole runtime path.
2. Local virtual microphone and AirPods mute fan-out.

Existing unrelated changes in `ReleaseManifest.swift` and
`ReleaseManifestTests.swift` remain excluded unless the user separately resumes
that work.

## Acceptance Criteria

### Phase 1

- All System Audio records without changing the current macOS output.
- Selected App captures only the chosen application.
- System/application and microphone audio produce one playable
  `recording.m4a`.
- Existing waveform, mute, playback, recording library, health, manual upload,
  and transcription features continue to work.
- The runtime UI and capture engine have no BlackHole or Multi-Output Device
  dependency.
- A 30-minute live recording has no periodic tick, material drift, or
  unexplained interruption.

### Phase 2

- Teams can select `Local Recorder Virtual Mic` and receive live microphone
  audio while Teams remains unmuted.
- A compatible AirPods mute gesture silences microphone audio in both the
  recording and Teams virtual input.
- A second gesture restores both paths.
- App exit, microphone disconnect, mute, and driver underrun yield silence
  rather than stale audio or noise.
- At least one real Teams test call validates the complete path; compile and
  unit-test success alone are insufficient.
