# Teams Auto Meeting Mode Design

**Date:** 2026-07-28
**Status:** Approved
**Target branch:** `codex/teams-auto-meeting-mode`

## Context

Local Meeting Recorder already connects to the Microsoft Teams desktop
Third-party App API and receives absolute `isInMeeting` and `isMuted` state.
Meeting state currently drives microphone mute synchronization and Teams window
resolution. Recording still starts and stops only through explicit user actions.

Teams Auto Meeting Mode adds an opt-in workflow that notices a Teams meeting,
shows a cancellable five-second countdown, and then starts recording. It stops
only recordings that it owns after Teams conclusively reports that the meeting
ended.

## Decisions

- Auto Meeting Mode is opt-in and disabled by default.
- A Teams meeting starts a visible, non-activating five-second countdown.
- The countdown can be cancelled without leaving or muting the Teams meeting.
- An automatically started recording stops after Teams reports
  `isInMeeting == false` continuously for ten seconds.
- Teams API connection loss is never treated as a meeting end.
- Manual and automatic recordings have explicit, separate ownership.
- A manual recording is never stopped by Auto Meeting Mode.
- Manually stopping an automatic recording suppresses another automatic start
  until the current Teams meeting ends.
- The current capture source, microphone, output folder, and storage policy are
  used unchanged.
- Screen capture remains off at the start of every recording and can still be
  enabled manually during recording.
- Automatic actions do not open macOS permission prompts or System Settings.
- Disabling Auto Meeting Mode cancels pending automation but leaves an active
  recording running under manual ownership.

## Goals

1. Start recording reliably after a user-visible five-second warning when a
   paired Teams client enters a meeting.
2. Stop only an automatically owned recording after a stable meeting-end
   signal.
3. Preserve all current manual recording, mute synchronization, Teams screen
   selection, storage, playback, and transcription behavior.
4. Keep Teams API connection ownership independent from Teams mute sync so
   either feature can be used alone.
5. Make all timing and ownership behavior deterministic under unit tests.

## Non-Goals

- Automatically enabling Teams screen capture.
- Automatically granting macOS permissions or opening permission dialogs.
- Starting from window-title, process, audio-level, or calendar heuristics when
  the Teams API is unavailable.
- Automatically retrying a failed start repeatedly during one meeting.
- Muting or unmuting Teams.
- Adding pre-roll audio, automatic transcription, or meeting summaries in this
  release.

## User Experience

### Configuration

A `Teams Auto Recording` row appears beside the existing Teams integration
controls. It contains a persistent switch and a compact state indicator.

The switch defaults to off. Enabling it keeps the Teams API client connected
even when Teams Mute Sync is disabled. Disabling it cancels any pending start
countdown or meeting-end debounce.

### Meeting Start

After an authoritative paired Teams event reports `isInMeeting == true`, the
app presents a compact non-activating countdown panel:

```text
Teams meeting detected
Recording starts in 5 seconds
[Cancel]
```

The panel does not play a sound and does not take keyboard focus away from
Teams. Its countdown is also reflected in the main-window status row.

The user may cancel. Cancellation suppresses automatic recording for that
meeting epoch. A new automatic countdown becomes possible only after Teams
conclusively leaves the meeting and later enters another one.

If the user manually starts recording during the countdown, the countdown
closes and the recording is manual-owned.

### Automatic Start

When the countdown completes, Auto Meeting Mode starts a normal recording with
the current capture source, microphone, output folder, and storage safeguards.
It does not silently change capture settings.

Automatic start requires permissions and capture readiness to be prepared
already. If readiness, storage, or writer setup fails:

- no permission dialog is opened;
- no automatic retry loop starts during that meeting;
- the Auto Meeting row and main status show an actionable failure;
- the manual Start Recording control remains available.

Teams screen capture remains off after automatic start.

### Meeting End

When an automatically owned recording receives `isInMeeting == false`, the UI
shows that recording will stop in ten seconds. A true meeting state arriving
during that interval cancels the stop and recording continues uninterrupted.

After ten continuous seconds of false state, the existing recording stop path
finalizes and saves the session once.

The following never trigger an automatic stop:

- `connecting`;
- `waitingForTeamsAPI`;
- pairing or token refresh;
- heartbeat timeout;
- socket failure;
- a meeting update that omits meeting state.

### Manual Overrides

- Manual recording before or during a Teams meeting has manual ownership and
  is never auto-stopped.
- Pressing Stop on an automatically owned recording stops it normally and
  suppresses re-entry for the current meeting.
- Disabling Auto Meeting Mode while it owns a recording transfers ownership to
  manual and leaves the recording running.
- Closing the countdown panel is equivalent to pressing Cancel.

## Architecture

### TeamsAutoMeetingCoordinator

`TeamsAutoMeetingCoordinator` is a deterministic state machine separate from
`RecordingEngine` and `TeamsMuteRelay`. It consumes authoritative Teams state,
connection status, user actions, and recording lifecycle results. It emits
commands that `AppModel` executes.

Core states:

```text
disabled
armed
startCountdown(remainingSeconds)
starting
autoRecording
stopDebounce(remainingSeconds)
suppressedUntilMeetingEnd
startFailed
```

Representative commands:

```text
showCountdown(seconds)
hideCountdown
startAutomaticRecording
stopAutomaticRecording
publishStatus
transferRecordingToManual
```

The coordinator receives injected countdown and debounce ticks so tests do not
wait for wall-clock time. A generation invalidates stale tick tasks when the
mode is disabled, a meeting changes state, or a manual action supersedes
automation.

### Recording Ownership

`AppModel` tracks the active recording ownership:

```swift
enum RecordingOwnership {
    case manual
    case teamsAutomatic
}
```

Ownership is assigned only after the recording start path succeeds. Meeting-end
commands may call stop only when ownership is `teamsAutomatic`. A manual stop
while Teams remains in a meeting sends a suppression event to the coordinator.

The existing `CaptureLifecycleGate` remains the only authority for overlapping
start and stop operations. Auto commands use dedicated AppModel methods that
reuse the same storage, readiness, recorder start, and finalization logic.

### Shared Teams Connection

The Teams client runs whenever either of these settings is enabled:

- Teams Mute Sync;
- Teams Auto Recording.

The single client callback fans each event out independently:

- mute events reach `TeamsMuteRelay` only when mute sync is enabled;
- meeting events reach `TeamsAutoMeetingCoordinator` only when auto mode is
  enabled;
- Teams window resolution continues to receive authoritative meeting state.

Disabling one feature does not stop the Teams client while the other still
needs it. Existing callback generations continue to reject stale events.

### Countdown Presentation

A small `NSPanel` hosts the SwiftUI countdown content. It floats above normal
windows, does not become key, does not activate the app, and exposes one Cancel
button. The controller is driven by published coordinator state and can be
replaced with a test double.

The main Teams integration area mirrors the state with short labels:

- `Off`
- `Waiting for meeting`
- `Recording starts in 5s`
- `Recording automatically`
- `Stopping in 10s`
- `Cancelled for this meeting`
- `Needs permission`
- `Start failed`

## Error Handling

- Repeated identical meeting events are idempotent.
- A false state during the start countdown cancels the countdown.
- A false state arriving while automatic start is in flight invalidates the
  start token; a late start completion cannot establish automatic ownership.
- A manual start or stop supersedes pending automatic commands.
- A failed automatic start is attempted at most once per meeting epoch.
- A Teams connection failure preserves the latest meeting epoch and active
  recording.
- A stale callback after disabling or reconnecting is ignored by generation.
- Repeated stop commands still finalize the writer only once.

## Persistence

`teamsAutoMeetingEnabled` is stored in `UserDefaults`, matching the current
capture and Teams settings pattern. Runtime countdown, ownership, meeting epoch,
and suppression state are not restored after process termination.

No recording starts merely because the app launches with stale persisted
meeting state. A fresh authoritative Teams meeting event is required.

## Tests

### Coordinator Tests

- enabling arms the coordinator without starting;
- the first true state starts one five-second countdown;
- repeated true states do not restart the countdown;
- cancel suppresses the current meeting epoch;
- false during countdown cancels without recording;
- countdown completion emits one start command;
- automatic start success establishes automatic ownership;
- automatic start failure does not retry during the same meeting;
- false begins a ten-second stop debounce;
- true during debounce cancels the stop;
- ten continuous seconds of false emits one stop command;
- connection loss never emits stop;
- disabling cancels timers and transfers an active recording to manual;
- stale ticks and stale Teams events are ignored.

### AppModel Integration Tests

- Auto Mode keeps the Teams client active while Mute Sync is off.
- Turning both Teams features off stops the shared client once.
- Automatic start uses the current capture configuration.
- Automatic start does not request permissions.
- A manual recording is not auto-stopped.
- Manual stop suppresses restart until meeting end.
- Start and stop races remain serialized by `CaptureLifecycleGate`.
- Screen capture is off after automatic start.
- Existing mute fail-closed and Teams window-resolution behavior is unchanged.

### Verification

1. Run focused coordinator and AppModel Teams tests with the Xcode toolchain.
2. Run the complete Swift test suite.
3. Build and install the app candidate.
4. In a real Teams test call, verify countdown, cancel, automatic start,
   transient false recovery, automatic stop, manual ownership, API disconnect,
   and screen-off default.
5. Perform an independent code review before accepting the installed candidate.

## Acceptance Criteria

1. A paired Teams meeting produces a visible, silent, cancellable five-second
   countdown.
2. Countdown completion starts exactly one recording using current settings.
3. A manual recording is never stopped by Teams state.
4. An automatically owned recording stops only after ten continuous seconds of
   authoritative `isInMeeting == false`.
5. Teams API disconnect never stops a recording.
6. Manual stop or countdown cancellation prevents restart during the same
   meeting.
7. Teams Mute Sync and Auto Meeting Mode can be enabled independently.
8. Automatic start never opens a permission prompt.
9. Screen capture remains off at recording start.
10. Focused tests, the full suite, app build, independent review, and live Teams
    acceptance all pass.
