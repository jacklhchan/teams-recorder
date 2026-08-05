# Recorder CLI and Teams Mute Control Design

**Date:** 2026-08-05

## Goal

Add a small, machine-readable CLI that can control and monitor the running
Recorder app without GUI automation, add an explicit microphone-device refresh
button, and optionally show and control Microsoft Teams mute state from the
floating recording panel through macOS Accessibility.

The Recorder-owned microphone gate remains the authoritative audio-safety
control. Teams mute state is an optional, best-effort observation because the
retired Teams API no longer provides a supported mute-state contract.

## Scope

The first CLI release provides exactly these commands:

```text
recorderctl status [--json]
recorderctl watch [--json]
recorderctl start
recorderctl stop
recorderctl auto on
recorderctl auto off
recorderctl mic mute
recorderctl mic unmute
```

The UI work adds:

- A microphone-device refresh button beside the existing microphone picker.
- A Recorder microphone state and a distinct Teams microphone state on the
  floating recording panel.
- One fail-safe floating microphone action that attempts to align Recorder and
  Teams mute state when Teams Accessibility control is available.
- An actionable `Teams status unknown` state when Teams cannot be inspected.

The work does not add a daemon, remote network API, Teams web integration,
Accessibility-based meeting detection, device selection through the CLI, or an
Accessibility requirement for recording and auto-recording.

## Architecture

### CLI process

`recorderctl` is a separate Swift executable packaged inside the app bundle at
`Contents/Helpers/recorderctl`. The installed development bundle exposes it as
`/usr/local/bin/recorderctl` through a symlink created by a narrowly scoped CLI
installation script. The embedded binary remains directly executable if the
symlink is not installed.

The CLI contains argument parsing, human and JSON rendering, app launch, and a
Unix-domain-socket client. It does not construct `AppModel`, access capture
devices, or read application state files directly.

### App control server

The app owns one Unix-domain-socket server for its lifetime. The endpoint is in
a per-user directory under `/tmp`, with the directory mode set to `0700` and the
socket mode set to `0600`. Staging and production use different endpoint names
derived from their bundle roles so they cannot control one another. The server
rejects peers whose effective UID differs from the app user's UID.

Each connection sends one newline-delimited JSON request and receives one
newline-delimited JSON response. The protocol contains a fixed version, request
ID, command, and optional argument. Responses contain the matching request ID,
success or structured error information, and a fresh status snapshot. No API
keys, transcript text, or other credentials are exposed.

The socket listener performs framing and validation off the main thread, then
dispatches accepted commands to a small `@MainActor` adapter over the existing
`AppModel` actions. Malformed, oversized, unsupported-version, and
wrong-user requests are rejected without changing app state.

### Background launch

If the socket is absent, `recorderctl` resolves the app bundle containing its
real executable and launches that bundle with `--background-control`. The app
starts its normal runtime and control server but does not activate, steal focus,
or order the main window onscreen. The CLI waits for a bounded startup period
and then executes the requested command. Startup timeout returns a nonzero exit
status and a useful error.

A normal user launch continues to show and activate the main window. A later
normal reopen shows the existing hidden window without constructing a second
runtime.

## Command Semantics

Commands are explicit and idempotent rather than toggles:

- `start` begins a manual recording only when no recording or start operation
  is active. When already recording it succeeds without restarting.
- `stop` stops and finalizes an active recording. When an automatic start is
  pending, it cancels the pending start. When nothing is active it succeeds as
  a no-op.
- A user-requested `stop` during a Teams automatic recording suppresses another
  start for the same detected meeting. Auto Mode re-arms only after the current
  meeting has been confirmed ended.
- `auto on` and `auto off` reuse the existing persisted Teams Auto Mode action.
- `mic mute` and `mic unmute` set the Recorder-owned local microphone gate to
  the requested value; repeated commands do not invert it.

Commands that cannot proceed because of missing macOS permissions, unavailable
capture sources, an operation already in progress, or finalization return a
structured rejection. The CLI never bypasses or silently grants a macOS
permission.

## Status Contract

The status snapshot contains only control and health information:

- App running state and app version.
- Recording state, lifecycle operation, manual or Teams-automatic ownership,
  elapsed time, and active recording folder when available.
- Current app status message.
- Auto Mode enabled state, coordinator state, local meeting-detection state,
  and active countdown.
- Selected microphone name and UID.
- Recorder local mute, native/AirPods input mute, observed Teams mute, and
  combined effective mute.
- Virtual Mic installation and publisher readiness.
- Screen/System Audio and microphone permission states.
- Output folder.

Human output is concise and labelled. `--json` emits one complete JSON object.
`watch` requests a snapshot once per second and prints only changed snapshots;
`watch --json` emits newline-delimited JSON objects. `watch` reconnects after a
short transient disconnect but exits with an error if the app cannot be
relaunched within the bounded startup period.

## Microphone Device Refresh

The microphone settings row gains an `arrow.clockwise` button with a stable
Accessibility identifier and help text. It calls the existing
`AppModel.refreshDevices()` action.

Refresh remains available during recording so newly connected or disconnected
devices become visible. The microphone picker remains disabled during an active
recording or capture lifecycle operation. Refresh does not switch the capture
device used by an active recording, restart capture, or stop recording.

## Teams Mute Observation and Control

### Optional Accessibility adapter

A focused `TeamsMuteControlling` boundary owns all Accessibility interaction.
It identifies the running Teams process, searches only its meeting UI for an
exposed microphone control, and reports one of:

```text
muted
unmuted
unknown(reason)
```

The adapter prefers stable Accessibility roles, identifiers, values, and
enabled state. Localized title matching is a bounded fallback, not the source
of truth. A missing permission, missing meeting control, stale element, Teams
update, minimized or absent window, ambiguous controls, or failed action yields
`unknown`; the app never guesses.

Accessibility is polled at most once per second only while Teams is running and
the floating recording panel needs the state. This feature does not participate
in Teams meeting detection and cannot prevent recording when Accessibility is
unavailable.

### Three-source mute gate

The existing microphone gate expands from local and native-input sources to:

- Recorder local mute intent.
- macOS native/AirPods input mute.
- Known Teams mute observation.

Effective mute is true when any known source is muted. An unknown Teams state
does not silently change the audio gate. A later Teams unmute observation clears
only the Teams source and never overrides an explicit Recorder-local or native
mute.

### Floating-panel presentation

The floating panel shows Recorder output state and a separate compact Teams
state: `Teams muted`, `Teams live`, or `Teams status unknown`. Mismatches remain
visible instead of being collapsed into a misleading single icon.

The combined user action is ordered for safety:

- **Mute:** set Recorder local mute first, then request Teams mute. Recorder
  output remains silent even if Teams control fails.
- **Unmute:** request Teams unmute first and confirm the observed state, then
  clear Recorder local mute. If Teams is still muted, becomes unknown, or the
  action fails, Recorder local mute remains set and the panel explains why.

If Accessibility is unavailable, the existing CLI `mic` commands remain an
explicit local-only escape hatch. They never claim that Teams changed. The UI
offers the macOS Accessibility permission action only when the user chooses to
enable Teams status/control; the app does not prompt at startup.

When an AirPods action changes Teams UI state and the Accessibility adapter can
observe it, the Teams badge updates on the next poll and the Teams source in the
effective Recorder mute gate follows it. This restores best-effort synchronization
without depending on a Teams private or retired API.

## Error Handling and Safety

- Socket creation refuses unsafe pre-existing filesystem objects and validates
  ownership before replacement.
- App shutdown closes the listener and removes only its exact owned socket.
- Requests have strict size and time limits; one slow client cannot block the
  app's main actor.
- CLI commands return nonzero for invalid usage, unavailable app/startup timeout,
  transport failure, or rejected operation. Human errors are concise; JSON
  errors have stable codes and messages.
- Manual and CLI stop share the existing same-meeting suppression behavior.
- Teams Accessibility failure degrades to `unknown`; it never unmutes Recorder.
- Refreshing devices never mutates the active recording's selected input.
- CLI status never exposes provider API keys or Keychain contents.

## Testing Strategy

Testing is intentionally narrow and behaviour-focused:

1. Protocol tests cover request/response encoding, version rejection, bounded
   framing, and snapshot JSON stability.
2. Control-adapter tests cover idempotent start, stop, Auto Mode, local mute,
   and suppression of a repeated start in the same meeting.
3. Socket tests use a temporary per-user endpoint and cover request/reply,
   wrong framing, cleanup, and peer validation where injectable.
4. CLI tests cover parsing, human/JSON rendering, exit codes, socket-unavailable
   launch handoff, and bounded startup timeout with fakes.
5. Microphone-gate tests cover local, native, and Teams source combinations and
   confirm that no source can accidentally clear another source's mute.
6. Teams mute coordinator tests use a fake Accessibility adapter to prove mute
   and unmute ordering, unknown-state degradation, mismatch presentation, and
   AirPods/Teams observation updates. Tests do not reproduce the entire Teams
   Accessibility tree.
7. One settings-view contract test covers the device Refresh action and stable
   Accessibility identifier.
8. Packaging tests confirm the helper is bundled, signed, and the CLI install
   link targets the current installed app.

Manual acceptance uses the final installed staging build:

- Run `status`, `watch --json`, start, stop, Auto Mode, and mic commands without
  opening the app window.
- Quit the app, run `status`, and confirm background launch does not steal focus
  or show the main window.
- Connect or disconnect a microphone and confirm Refresh updates the picker
  without affecting an active recording.
- In one live Teams meeting, verify Teams `muted`, `live`, and `unknown` states,
  fail-safe floating mute/unmute ordering, and AirPods-triggered best-effort
  status synchronization.
- Stop an automatic recording while the meeting remains active and confirm no
  second countdown appears for that meeting.

## Acceptance Criteria

- All documented CLI commands work against the installed staging app and return
  deterministic human and JSON output.
- A CLI command can start the app in background-control mode without GUI focus
  or window activation.
- CLI retries cannot toggle or duplicate start, stop, Auto Mode, or local mute
  actions.
- CLI stop during an active auto-recorded meeting does not cause another popup
  or recording until that meeting ends.
- The microphone Refresh button shows the latest device list while preventing
  input switching during recording.
- The floating panel distinguishes Recorder output from Teams mute state and
  never presents `unknown` as muted or live.
- Mute is local-first; unmute is Teams-confirmed-first. Accessibility failure
  cannot accidentally unmute Recorder output.
- AirPods/Teams synchronization is explicitly best-effort, and core recording,
  Auto Mode, Virtual Mic control, and CLI operation remain usable without
  Accessibility permission.
- The focused automated tests and final existing test suite pass, and the
  staging app bundle plus embedded helper pass signing and packaging checks.
