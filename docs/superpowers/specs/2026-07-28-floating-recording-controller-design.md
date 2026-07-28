# Floating Recording Controller Design

## Goal

Show a compact, always-on-top controller whenever a recording has actually
started. The controller lets the user confirm recording state, see elapsed
time, turn Teams window recording on or off, and stop the recording without
returning to the main window.

## Chosen Approach

Use one non-activating AppKit `NSPanel` hosting a SwiftUI view. The panel
shares the existing `AppModel`; it must not create another recorder or copy
screen-capture state.

Alternatives considered:

- A second SwiftUI `Window` scene would require moving model ownership and
  adds ordinary-window activation behavior.
- An overlay inside the main window would disappear behind Teams and would
  not help when the main window is closed or covered.

The `NSPanel` approach matches the existing Teams auto-countdown panel and
can remain above Teams without taking keyboard focus.

## User Experience

- The panel appears only after `RecordingEngine.isRecording` becomes true.
  Permission prompts, storage checks, and capture startup do not show it.
- It is 390 by 112 points, movable by its background, and
  positioned near the top-right of the screen containing the pointer.
- It is floating, visible across Spaces and full-screen apps, does not hide
  when Recorder deactivates, and does not become key or main.
- It has no close button. It disappears automatically after recording
  finalization finishes.
- The first row contains a red recording indicator, `Recording` or
  `Finalizing`, a monospaced `HH:MM:SS` timer, and a red stop icon button.
- The second row contains a screen icon, the projected Teams screen status,
  and a native toggle.
- If the active recording source is not Microsoft Teams, the second row
  remains visible as `Teams screen unavailable` with its toggle disabled.
- Screen recording remains Off at the start of every recording.
- While stopping/finalizing, screen controls and Stop are disabled and the
  panel stays visible until `isRecording` becomes false.
- If a selected Teams window is missing or recreated, the panel shows the
  same Waiting/Reconnecting/Frames unavailable state as the main window.
- If screen capture becomes unavailable after it was requested, the toggle
  remains usable to turn capture Off. Unavailable state must prevent a new
  On request, not trap an existing On request.
- The panel appears for both manual and Teams automatic recordings.

## Architecture

### Shared Runtime

`LocalMeetingRecorderApp` owns one app-lifetime runtime for the normal app
path. The runtime owns:

- the single `AppModel`;
- the recording panel presenter;
- observation that projects model/engine changes into the presenter.

`ContentView` receives the shared model as an `@ObservedObject`. The
`--teams-screen-viability-probe` path remains isolated and must not start the
normal recorder runtime.

### Presentation Projection

Add a pure `RecordingControllerPresentation` value. It projects:

- visibility;
- recording/finalizing title;
- elapsed text from `startedAt` and an injected `now`;
- screen status text and tone;
- requested state;
- screen-toggle availability;
- Stop availability.

The elapsed duration clamps to zero if `now` precedes `startedAt`.

### Panel Presenter

Add a presenter protocol and factory, following
`TeamsAutoMeetingCountdownPresenting`. The production presenter owns one
reusable non-activating `NSPanel` and updates its `NSHostingView` without
ordering a duplicate panel to the front on each one-second timer update.

The panel has no independent recording state. Actions call:

- `AppModel.setTeamsScreenCaptureRequested(_:)`;
- `AppModel.startOrStop()`.

The Stop action must not call `RecordingEngine.stop()` directly because that
would bypass recording ownership, storage monitoring, Teams auto-mode
suppression, and capture lifecycle cleanup.

### Main Window Identity

Assign an identifier to the main window and find it by identifier when the
app activates. Once a floating panel exists, `NSApp.windows.first` is no
longer a safe way to identify the main window.

## Lifecycle

1. Recording starts and `isRecording` becomes true.
2. The runtime presents one controller panel using the current model.
3. Timer and screen-state updates refresh panel content without changing
   window focus or creating another panel.
4. User Screen actions pass through the existing guarded AppModel method.
5. User Stop passes through `startOrStop()`.
6. During writer finalization, the panel says `Finalizing` and disables
   controls.
7. When `isRecording` becomes false, the reusable, non-released panel closes
   programmatically and resets for the next recording.

The main window closing policy remains unchanged. The floating panel is an
auxiliary controller, not a second app instance.

## Error Handling

- A failed or unavailable Teams screen target is status information; audio
  recording continues.
- The toggle permits Off whenever screen capture is currently requested,
  even if the current state otherwise prevents On.
- Async toggle requests use the existing AppModel lifecycle guards.
- Repeated recording notifications are idempotent and cannot create
  duplicate panels.
- App termination dismisses the panel.

## Accessibility

- Recording status exposes `recording-controller-status`.
- Timer exposes `recording-controller-elapsed`.
- Screen status exposes `recording-controller-screen-status`.
- Toggle exposes `recording-controller-screen-toggle`.
- Stop exposes `recording-controller-stop`.
- Icon-only buttons have labels and tooltips.

## Testing

Follow test-driven development:

1. Pure presentation tests for hidden/recording/finalizing states, elapsed
   formatting, every Teams screen status, and toggle availability.
2. Presenter episode tests proving exactly-one presentation, idempotent
   updates, dismissal after finalization, and reappearance next recording.
3. AppModel regression test proving requested-but-unavailable screen capture
   can still be turned Off.
4. Existing manual and Teams automatic recording suites must remain green.
5. Full Swift suite, app build, codesign verification, and a live macOS
   smoke test must pass before installation.

The live smoke test must confirm that the panel appears over another app,
does not steal focus, Screen Off/On updates both panel and main-window state,
Stop finalizes the recording, and the panel disappears.
