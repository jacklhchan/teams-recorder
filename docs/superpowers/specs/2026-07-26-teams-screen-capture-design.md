# Teams Meeting Window Capture Design

**Date:** 2026-07-26
**Status:** Awaiting written-spec review
**Target branch:** `codex/native-audio-capture`

## Context

Local Meeting Recorder currently uses one ScreenCaptureKit stream to capture
selected-application audio and microphone audio. It registers only `.audio` and
`.microphone` outputs, normalizes both sources to 48 kHz stereo, aligns them by
timestamp, and writes one `recording.m4a`.

The next feature records the complete Microsoft Teams meeting window, including
screen sharing, participant video, and Teams controls. It must preserve the
existing native audio capture, virtual microphone, AirPods/Teams mute sync,
recording library, playback controls, and oMLX transcription workflow.

## Decisions

- Capture the complete Teams meeting window, not the full display and not a
  cropped approximation of only the shared content.
- Automatically select the active Teams meeting window. Show the selected
  window and retain a manual correction control.
- All new sessions use one `recording.mp4`, including sessions that never enable
  screen capture.
- Screen capture starts off for every new recording and can be enabled or
  disabled at any point without interrupting audio.
- Use a custom AVAssetWriter pipeline rather than `SCRecordingOutput`.
- Use HEVC video and AAC audio with a storage-oriented fixed profile.
- Preserve old M4A sessions and manual audio imports.
- Keep a temporary audio-only safety copy while recording. A successful stop
  deletes it, leaving one final media file.

## Goals

1. Record Teams application audio, the selected physical microphone, and the
   Teams meeting window into one synchronized MP4.
2. Allow screen capture to begin or end in the middle of a recording.
3. Keep the final file near 600 MB per hour when video is enabled continuously.
4. Continue recording useful audio when the Teams window disappears or video
   capture fails.
5. Preserve AirPods/Teams mute behavior for both the recording microphone track
   and `Local Recorder Virtual Mic`.
6. Keep old recordings playable, seekable, and transcribable.

## Non-Goals

- Capturing the entire Mac display.
- Automatically cropping only the remote shared-content rectangle.
- Recording separate participant, camera, or presentation tracks.
- Automatically enabling video when Teams reports that someone is presenting.
- Adding webcam overlays, annotations, OCR, or live video transcription.
- Adding H.264 export in the first release.
- Changing the virtual microphone driver or Teams third-party API protocol.

## User Experience

### Before Recording

- The existing audio-source and microphone controls remain unchanged.
- The screen-capture control is available only when Microsoft Teams is the
  selected application source. All System Audio and other applications remain
  valid for audio-only recording, but cannot be combined with Teams-window
  video in this release.
- A screen-capture control appears beside the recording controls.
- Its initial state is off for every new session.
- The app resolves a Teams meeting window in the background and shows one of:
  - `Teams window ready`
  - `Waiting for Teams window`
- The selected window title is visible with a manual change control.
- No persistent video preview is shown.

### During Recording

- Pressing the screen-capture control begins writing Teams frames at the current
  recording time.
- Pressing it again stops writing Teams frames while audio continues.
- The status changes among:
  - `Screen off`
  - `Capturing Teams window`
  - `Waiting for Teams window`
  - `Screen capture unavailable`
- Turning screen capture on while no suitable meeting window exists records
  black video and preserves the user's intent. Capture begins automatically when
  a high-confidence Teams meeting window becomes available.

### Playback

- Sessions that contain captured screen intervals open an AVPlayer-based video
  player.
- Sessions whose screen capture was never enabled keep the compact audio-player
  presentation even though their container is MP4.
- Play, pause, stop, timeline seeking, and duration display remain available.
- Legacy M4A recordings use the same AVPlayer-based playback coordinator.

## Architecture

### 1. TeamsMeetingWindowResolver

`TeamsMeetingWindowResolver` consumes `SCShareableContent.windows` and only
considers windows owned by the Teams bundle identifier
`com.microsoft.teams2`.

Candidate ranking is deterministic:

1. Keep the current window while its `CGWindowID` remains available.
2. Prefer a user-selected override.
3. Prefer a substantial, normal-layer Teams window created or surfaced after
   the Teams API enters a meeting.
4. Reject small dialogs, menus, notifications, settings panels, and utility
   windows.
5. Prefer the largest remaining on-screen meeting candidate.

The resolver does not request macOS Accessibility permission. If multiple
candidates have similar confidence, it does not start video automatically and
asks for manual correction. This fail-closed behavior prevents accidentally
recording a Teams chat or settings window.

The resolver refreshes once per second while recording or while the user has
requested screen capture. It emits stable descriptors containing window ID,
owner process identity, title, frame, and confidence.

### 2. ScreenCaptureSource

The primary design keeps one ScreenCaptureKit stream and registers:

- `.audio` for filtered Teams application audio;
- `.microphone` for the selected physical microphone;
- `.screen` for Teams meeting-window frames.

While screen capture is off or no meeting window is available, the stream keeps
the existing Teams application filter so audio remains independent of any one
window. Enabling screen capture updates the running stream to a
desktop-independent meeting-window filter. Disabling it returns to the Teams
application filter. `excludesCurrentProcessAudio` remains enabled throughout.
Filter transitions must be tested for audio gaps and must not recreate the
stream or writer.

Before production implementation, a focused viability test must prove on the
target Mac and installed Teams build that this window filter:

- returns the complete meeting-window video;
- continues returning Teams application audio;
- keeps microphone output working;
- remains stable while the window is occluded, moved, resized, or placed on a
  different display.

If window-scoped filtering does not preserve Teams audio, implementation stops
at that gate and the design is revisited. The existing accepted audio path must
not be replaced with an unverified two-stream clock design.

The screen configuration is:

- fixed output canvas: 1600 x 900;
- preserve source aspect ratio with black letterboxing;
- do not stretch the Teams window;
- 10 frames per second maximum;
- queue depth 3;
- preferred pixel format: NV12 for hardware HEVC encoding;
- BGRA conversion only as a compatibility fallback;
- local cursor hidden; any presenter cursor rendered by Teams remains visible.

### 3. Teams Window Changes

When Teams creates a replacement meeting window or switches to a pop-out:

1. The resolver identifies the replacement.
2. The source applies `updateContentFilter` to the active stream.
3. The video compositor fits the new source into the existing 1600 x 900 canvas.
4. The MP4 writer and audio path remain active.

If the window disappears, the source emits black frames and a warning while
audio continues. The app never restores, raises, or unminimizes Teams
automatically.

### 4. RecordingTimeline

`RecordingTimeline` maps all accepted sample timestamps onto one session-relative
timeline.

- The first valid media sample establishes the session anchor.
- Existing mixed-audio `startFrame` values remain authoritative at 48 kHz.
- Video presentation timestamps are normalized to the same anchor.
- Early samples are held in a small bounded queue until the anchor exists.
- Repeated, backward, or far-future video timestamps are rejected and counted.
- Audio gaps retain the existing mixer discontinuity semantics and are not
  silently compressed.

This component is independent of encoding and can be tested with synthetic
audio and video timestamps.

### 5. VideoGate

The video input is configured before AVAssetWriter starts. This is required so
the user can enable screen capture after audio samples have already been
written.

- At recording start, append one black frame at time zero.
- While screen capture is off, discard captured Teams frames.
- When enabled, append valid Teams frames with their normalized timestamps.
- When disabled, append one black frame at the transition timestamp.
- At stop, append a final black frame if needed so the video track reaches the
  audio duration.

The held black frame represents screen-off periods without writing repeated
full-rate frames, so storage use is negligible.

### 6. MuxedMediaWriter

`MuxedMediaWriter` wraps one AVAssetWriter with inputs configured before writing:

#### Video

- container: MPEG-4;
- codec: HEVC;
- canvas: 1600 x 900;
- frame rate: 10 fps maximum;
- average bitrate: 1.2 Mbps;
- hardware encoder preferred;
- fixed dimensions for the life of the file.

#### Audio

- codec: AAC;
- sample rate: 48 kHz;
- channels: stereo;
- average bitrate: 128 kbps;
- source: the existing timestamp-aligned system/microphone mix.

The writer receives mixed audio blocks rather than raw ScreenCaptureKit audio,
so the current microphone mute and health semantics remain authoritative.

The output is first written as `recording.partial.mp4`. Successful finalization
atomically promotes it to `recording.mp4`.

### 7. AudioSafetyWriter

Every active recording also sends the same mixed audio blocks to the existing
AAC writer at:

`recording.audio-backup.m4a`

The existing AAC writer becomes bitrate-configurable. New safety files use
128 kbps AAC so their size and recovered-audio quality match the MP4 audio
track; legacy recordings remain unchanged.

Normal completion:

1. Finalize and validate `recording.partial.mp4`.
2. Rename it to `recording.mp4`.
3. Delete `recording.audio-backup.m4a`.

MP4 or video failure:

1. Stop accepting video.
2. Continue writing the audio backup where possible.
3. Finalize the backup as `recording.m4a`.
4. Report that video was lost but audio was preserved.

Unexpected termination:

- On next launch, an incomplete-session recovery pass validates the backup.
- A valid backup becomes `recording.m4a`.
- The partial MP4 is ignored by the library and retained as a recovery artifact
  rather than silently deleted.

Normal sessions still contain one final media file. The temporary safety cost is
about 60 MB per recording hour.

## Mute and Virtual Microphone Behavior

Mute behavior remains synchronous and fail-closed:

- Teams/AirPods mute changes the effective recorder microphone gate.
- Muted microphone samples become silence in the mixed audio track.
- `VirtualMicPublisher` emits silence to Teams while muted.
- Teams participant audio and meeting-window video continue recording.
- Unmute restores both recording microphone audio and virtual-mic output.
- Screen capture state never changes microphone mute state.

## File and Library Model

`RecordingSession` gains media information without breaking its existing ID or
folder layout:

- primary media URL;
- media kind: audio or video;
- whether any real screen interval was recorded;
- captured screen intervals;
- recovery state when applicable.

`RecordingSessionStore` recognizes:

- new `recording.mp4`;
- legacy and recovered `recording.m4a`;
- existing manually imported audio formats.

Partial and backup files are never shown as normal sessions.

Session metadata records screen intervals and selected Teams window identity.
The metadata remains optional so old folders load with safe defaults.

## Transcription

The oMLX transcription flow continues to receive an audio file.

For MP4 sessions:

1. Extract the MP4 audio track to a temporary M4A using AVFoundation.
2. Send that M4A through the existing transcription request.
3. Delete the temporary file on success, failure, or cancellation.

Legacy M4A and manually imported audio continue through the current path without
extraction. No second long-term audio file is stored.

## Storage Profile

Expected upper-bound usage:

| Screen-capture use | Approximate size |
| --- | ---: |
| Never enabled | 60 MB/hour |
| Enabled for 30 minutes of a one-hour meeting | 330 MB |
| Enabled for the full meeting | 600 MB/hour |
| Enabled for a two-hour meeting | 1.2 GB |

Actual HEVC size varies with screen activity. Static slides typically use less
space than rapidly changing video.

Before recording:

- below 5 GB available: show a storage warning;
- below 1 GB available: disable screen capture but allow audio-only recording.

During recording:

- recheck available capacity periodically;
- if capacity falls below the video safety threshold, turn screen capture off
  and continue audio;
- if capacity reaches the audio safety threshold, finalize the recording and
  report why it stopped.

The thresholds are evaluated against the selected recording volume, not an
assumed system disk.

## Failure Handling

| Failure | Required behavior |
| --- | --- |
| No Teams meeting window | Keep audio; show waiting state; write black video |
| Ambiguous Teams windows | Do not capture a candidate; request manual choice |
| Teams window replaced | Update the content filter without restarting writer |
| Teams window minimized and frames stall | Keep audio; black video; warning |
| ScreenCaptureKit video failure | Disable video; keep audio and safety writer |
| Dropped video frame | Count and continue; never block audio callbacks |
| Video encoder backpressure | Drop video frame; never block capture queue |
| AVAssetWriter global failure | Promote the audio backup |
| Microphone disconnect | Preserve current audio-path disconnect behavior |
| Teams API disconnect while in meeting | Preserve current fail-closed mute |
| Low disk space | Disable video first, then safely stop audio if necessary |
| App termination | Recover valid audio backup on next launch |

Video conversion, encoding, and writing must never execute on the realtime audio
callback path.

## Testing

### Unit Tests

- Teams candidate filtering, scoring, stability, ambiguity, and manual override.
- Meeting-window replacement and resolver lifecycle.
- Fixed-canvas aspect fit and even-dimension calculations.
- Video-gate start, enable, disable, re-enable, and final black frames.
- Timeline anchor, delayed first video, gaps, backward timestamps, and bounded
  pending samples.
- Storage estimates and free-space thresholds.
- New MP4 and legacy M4A session discovery.
- Metadata defaults for old recordings.
- Audio extraction cleanup on success, failure, and cancellation.
- Partial-session audio recovery.

### Integration Tests

Use synthetic audio and pixel buffers to write MP4 files that cover:

- audio beginning before video;
- multiple screen-enabled intervals;
- screen disabled at stop;
- window-size changes;
- video frame drops;
- video failure with valid audio fallback.

For every output, inspect it with AVURLAsset and assert:

- playable container;
- expected audio/video tracks;
- duration alignment;
- seekability;
- monotonic timestamps;
- expected codec, dimensions, frame rate, and bitrate range.

### Regression Tests

- Existing native Teams audio capture.
- Existing timestamp mixer and AAC writer behavior.
- AirPods/Teams mute and unmute.
- Virtual microphone PCM publication and fail-closed silence.
- Audio-only playback, stop, and timeline dragging.
- Recording library metadata, favorites, tags, Trash, and search.
- Manual audio import.
- oMLX transcription and transcript editing/export.

### Live Acceptance

1. Use AirPods as Mac output and selected microphone; do not use BlackHole or a
   Multi-Output Device.
2. Select Microsoft Teams as the application source.
3. Begin recording with screen capture off.
4. Join a Teams call and start a PowerPoint or document share.
5. Enable screen capture in the middle of the recording.
6. Resize, occlude, move, minimize, and pop out the Teams meeting window.
7. Verify automatic window replacement or an explicit waiting state.
8. Mute and unmute with AirPods; verify Teams, virtual mic, and recorded mic
   silence while participant audio and video continue.
9. Disable screen capture and continue recording audio.
10. Stop and validate playback, seeking, duration, file size, and oMLX
    transcription.
11. Run a minimum 30-minute soak test and inspect audiovisual drift.
12. Simulate video writer failure and confirm a playable recovered M4A.

## Delivery and Review Gates

- Develop in the existing isolated `codex/native-audio-capture` worktree.
- Begin with the same-stream Teams window/audio viability test.
- Use test-driven changes for resolver, timeline, writer, recovery, and library
  behavior.
- Keep capture/writer work separate from library/playback UI work where file
  ownership allows parallel implementation.
- Run focused tests after each component and the full suite before installation.
- Perform an independent review of the cumulative diff.
- Install and test one candidate app only after automated checks pass.
- Do not claim completion until live Teams screen-share, AirPods mute, playback,
  transcription, recovery, capacity, and 30-minute synchronization acceptance
  all pass.
