# Floating Dual-Input Waveforms Design

## Goal

Make the existing floating recording controller prove that the recorder is
receiving both system/Teams audio and the user's microphone by showing two
live, source-labelled waveforms.

## Approved Visual Direction

- Keep the panel width at 390 points and increase its height from 112 to 180.
- Keep the Recording/finalizing header, elapsed timer, Stop button, Teams
  screen status, and screen-capture toggle unchanged in behavior.
- Insert two compact rows between the header and Teams screen row:
  - `System / Teams`: blue-cyan `WaveformView` fed by
    `RecordingEngine.systemLevel.samples`.
  - `Microphone`: green-teal `WaveformView` fed by
    `RecordingEngine.micLevel.samples`.
- Each row exposes one restrained status: `Signal`, `Quiet`, `Muted`, or
  `Disconnected`.
- Finalizing uses the same real levels. If capture has settled, the waveform
  is flat and its status is `Quiet`; the UI must not fabricate activity.

## Data and State

The floating view already observes the shared `RecordingEngine`. Reuse its
published `systemLevel`, `micLevel`, `micMuted`,
`isSystemCaptureConnected`, and `isMicrophoneCaptureConnected` properties.
Do not add a new timer, audio tap, buffer, recorder instance, or AppModel
relay.

Status precedence is exact:

1. A disconnected source is `Disconnected`.
2. A connected muted microphone is `Muted`.
3. A connected source whose `LevelSnapshot.isSilent` is true is `Quiet`.
4. Otherwise it is `Signal`.

## Accessibility

- `recording-controller-system-waveform` labels the System / Teams waveform.
- `recording-controller-microphone-waveform` labels the microphone waveform.
- Each waveform exposes its current status as its accessibility value.
- Existing status, timer, screen-toggle, and Stop identifiers remain stable.
- The waveforms remain live under Reduce Motion because they represent input
  data, not decorative travelling motion.

## Scope

Modify only the floating recording controller and its focused tests. Reuse
the existing `WaveformView` and `LevelSnapshot`. Do not change
`RecordingEngine`, audio capture, recording ownership, screen capture,
storage, or the main Record dashboard.

## Verification

- TDD RED then GREEN for status precedence and both waveform render paths.
- Run only `RecordingControllerPanelTests` and
  `RecordingControllerRenderTests`.
- Run `scripts/build-app.sh` and `git diff --check`.
- Do not gate this slice on the full legacy suite.
