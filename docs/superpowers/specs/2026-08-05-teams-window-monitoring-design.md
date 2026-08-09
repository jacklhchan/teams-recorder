# Teams Window Monitoring Design

## Goal

Restore reliable Teams automatic recording after retirement of the Teams
third-party API. With Auto Mode enabled, the recorder must notice a real Teams
meeting within about three seconds, ignore the Teams shell and pre-join UI, and
re-arm after the meeting ends so a later Meet now session can trigger again.

## Confirmed User Decision

- Detection may take up to about three seconds: one window scan per second and
  three consecutive matching observations.
- Continuous local window monitoring is acceptable while Auto Mode is enabled.
- The fix must remain small and must not add a broad test matrix.
- No new Accessibility permission is required for this fix.

## Current Failure

The installed 0.2.0 (335) staging build was tested end to end:

1. Teams had returned to Calendar and no meeting window was open.
2. Recorder remained in `Cancelled for this meeting` instead of re-arming.
3. A new Meet now meeting was created and joined.
4. No five-second countdown appeared and no recording started.

There are two contributing defects:

1. Local detection treats any sufficiently large Teams window as a meeting.
   Calendar therefore prevents the detector from confirming that the previous
   meeting ended.
2. When Auto Mode is restored as enabled and the Teams capture source changes,
   `handleTeamsScreenSourceChange()` performs one immediate refresh but does not
   start the existing periodic refresh loop.

## Chosen Architecture

Use a hybrid monitor with two narrow responsibilities:

1. `NSWorkspace` process notifications notice Teams launch, termination, and
   replacement so the selected Teams process identity can be refreshed.
2. The existing ScreenCaptureKit loop enumerates Teams window metadata once per
   second while Auto Mode is enabled. It reads only window identity, title,
   frame, layer, and on-screen state; it does not capture visual content.

Window observations continue to pass through the existing
`TeamsLocalMeetingDetector`. Three consecutive positive observations confirm a
meeting. Thirty consecutive missing observations confirm meeting end. Existing
five-second start countdown, automatic recording ownership, stop behavior, and
manual-recording protection remain unchanged.

## Why Accessibility Is Not the Primary Mechanism

macOS Accessibility can observe notifications such as a new or focused window,
so it is a possible future optimization. It is not the primary mechanism here
because it would:

- require a new user-facing Accessibility permission;
- depend on how consistently the Electron-based Teams client publishes AX
  window lifecycle events;
- still require a reconciliation scan after missed, coalesced, or reordered
  events; and
- introduce a second permission and monitoring lifecycle for a problem already
  served by ScreenCaptureKit.

An event-only Accessibility implementation is therefore less reliable than the
accepted one-second polling design. Accessibility is deliberately left outside
this change rather than maintained as a fallback path.

## Components and Responsibilities

### TeamsMeetingWindowResolver

The resolver will classify each candidate before size and preference ranking.
It must distinguish:

- Teams shell pages such as Calendar, Activity, Chat, Teams, Calls, OneDrive,
  Copilot, Settings, and Notification;
- the pre-join page, whose first title segment is `Meeting join`; and
- a joined meeting window, whose first title segment is the meeting name.

Classification uses the normalized first title segment before ` | `. Matching
is exact against known shell segments, not a broad substring search. For
example, a meeting named `Calendar migration review` remains eligible, while a
window whose first segment is exactly `Calendar` is not.

The classification is part of the resolver rejection path. This is important
because Teams may reuse the same macOS window ID while changing its title from
Calendar to pre-join, joined meeting, and back to Calendar. A previously chosen
identity must therefore be revalidated on every observation.

### AppModel Monitoring Lifecycle

`AppModel` continues to own the monitoring task.

- Auto Mode off: no periodic Teams window scan unless recording or manual
  screen-capture behavior already requires one.
- Auto Mode on with a selected Teams process: perform an immediate refresh and
  keep the existing one-second refresh loop running.
- Teams process terminates: invalidate the stale PID and window resolution,
  publish a missing observation, and wait for a replacement Teams process.
- Teams process launches or is replaced: refresh capture applications, restore
  the Teams selection by bundle identifier, reset stale window identities, run
  an immediate scan, and restart the loop.
- App shutdown or Auto Mode off: cancel the task and unregister process
  observations through existing lifecycle cleanup.

Starting the loop must be idempotent. Generation checks remain the authority
for rejecting stale asynchronous refresh results.

### TeamsLocalMeetingDetector and Coordinator

No new state machine is introduced.

- Calendar-only observations resolve to `.waiting`.
- Three consecutive joined-meeting observations produce a meeting-start
  transition.
- Brief window loss does not end an automatic recording.
- Thirty consecutive non-meeting observations produce one confirmed meeting-end
  transition.
- Confirmed end clears `suppressedUntilMeetingEnd`, returns Auto Mode to waiting,
  and allows the next meeting to begin a fresh countdown.

## Data Flow

1. Auto Mode enables monitoring.
2. Once per second, ScreenCaptureKit enumerates Teams window metadata.
3. The resolver rejects shell and pre-join windows, then resolves an eligible
   joined-meeting window or `.waiting`.
4. `TeamsLocalMeetingDetector` debounces the observation.
5. A confirmed start drives the existing five-second countdown and automatic
   recording command.
6. A confirmed end drives the existing automatic stop behavior and re-arms the
   coordinator.
7. A later meeting repeats the same lifecycle without carrying suppression or a
   stale window identity from the earlier meeting.

## Failure Handling

- A failed ScreenCaptureKit enumeration yields an unknown observation and does
  not start or stop a recording.
- Ambiguous eligible windows do not trigger a new automatic recording.
- Teams termination invalidates stale process and window identities rather than
  repeatedly querying the old PID.
- A transient missing window remains covered by the existing 30-observation end
  confirmation.
- No API disconnect state is reintroduced.

## Testing Strategy

Keep automated coverage to two focused groups.

### 1. Resolver and Monitoring Regression

Verify that a Calendar-only Teams window resolves to `.waiting`; the same
window identity changing to a joined-meeting title resolves to `.ready`; and
changing back to Calendar resolves to `.waiting`. Also verify that persisted
Auto Mode starts the periodic refresh loop after Teams selection is restored.

### 2. Two-Meeting Lifecycle

Drive the existing detector and coordinator through:

1. Calendar waiting;
2. three observations of the first meeting;
3. automatic start;
4. thirty non-meeting observations and automatic stop completion; and
5. three observations of a second meeting.

Assert one start for each meeting, one stop for the first meeting, and no stale
suppression or window identity blocking the second start.

Do not add a matrix for tenant, language, window size, pop-out mode, or exact
timer timing in this change.

## Acceptance Test

The acceptance test was independently drafted by the acceptance-test subagent
and intentionally kept narrow:

1. Launch the candidate from `/Applications` with Auto Mode enabled.
2. Leave Teams on Calendar for at least five seconds. Recorder must remain
   waiting and must not show a countdown.
3. Create and join a first Meet now meeting. Recorder must show the five-second
   countdown and start one Teams automatic recording.
4. Leave the meeting. After the existing end-confirmation period, the automatic
   recording must stop and Recorder must return to waiting.
5. Create and join a second Meet now meeting. A new countdown must appear and a
   second automatic recording must start.
6. Confirm the library contains two independent Teams automatic recordings.

A single uninterrupted screen recording of this flow, plus the final library
state, is sufficient acceptance evidence.

## Non-Goals

- Adding or requiring Accessibility permission.
- Inspecting meeting participants, roster, mute state, or Teams private APIs.
- Changing countdown duration, stop debounce, recording ownership, microphone
  mute behavior, or screen-capture UI.
- Building multiple simultaneous meeting-window selection logic beyond the
  existing ambiguity behavior.
- Supporting localized Teams shell titles in this focused fix; localization can
  be added later with observed title evidence rather than speculation.
