# Teams API Retirement Fallback — Lean Installed-App Acceptance

This draft was produced independently from the implementation work. It tests
only behaviors that deterministic unit/render tests cannot establish against a
real Teams desktop client. Run each case once; repeat only a failed case.

## Preconditions

- Launch the candidate from `/Applications/Local Meeting Recorder Staging.app`
  and record its version/build.
- Use the current shipping Microsoft Teams desktop client.
- Grant Screen & System Audio Recording and Microphone permission to the exact
  candidate bundle.
- Make `Local Recorder Virtual Mic` selectable in QuickTime Player's New Audio
  Recording input menu.

## Seven acceptance cases

### 1. Real meeting window starts the countdown

Enable `Teams Window Auto Mode (Beta)`, then join a real Teams meeting and keep
the meeting window visible.

Pass: the status progresses through waiting/confirming/detected and shows the
five-second `Teams Window Auto Recording` countdown. No pairing, Allow, or
retry prompt appears.

Evidence: one continuous screen recording from meeting-window appearance to
countdown, including the Settings Beta explanation.

### 2. Cancel suppresses only the current meeting

Cancel case 1's countdown, remain in that meeting for about 15 seconds, leave,
wait for end confirmation, then join another meeting.

Pass: the cancelled meeting never auto-records; the next meeting receives a
new countdown.

Evidence: continuous screen recording covering Cancel, no start in the same
meeting, and countdown in the next meeting.

### 3. Short window loss preserves one automatic recording

Allow the countdown to finish. During automatic recording, minimize or switch
the meeting pop-out for about ten seconds, then restore it.

Pass: recording remains active and the library contains one continuous
automatic recording rather than two fragments.

Evidence: screen recording plus the single library entry's source/duration.

### 4. Confirmed leave stops after the grace period

From case 3, choose Leave and close the meeting window.

Pass: the recording remains active during the approximate thirty-second grace
period and then stops automatically. Polling variation is acceptable; exact
single-second timing is not required.

Evidence: a continuous clip with a visible clock covering Leave, grace, and
automatic stop; retain the recording.

### 5. Manual recording is never auto-stopped

Enable auto mode, join a meeting, cancel the countdown, then press manual
Start. Leave and wait at least 35 seconds.

Pass: the manual recording remains active until the user presses Stop.

Evidence: screen recording and the retained manual library entry.

### 6. Floating mic control and native mute silence the actual virtual mic

In QuickTime New Audio Recording, explicitly select `Local Recorder Virtual
Mic`. Record one uncut sequence: speak five seconds; click the microphone icon
on the floating recording window and speak five seconds; click it again and
speak five seconds; then native input/AirPods mute, speak five seconds, and
unmute.

Pass: the icon shows the muted/unmuted transition; both muted sections contain
near-silence/no intelligible speech; and both unmuted sections recover. The
floating icon state must agree with the actual virtual-mic output. Teams
mute-icon agreement is not a pass condition.

Evidence: one unedited QuickTime audio artifact and one synchronized screen
recording showing the selected input, both icon clicks/state changes, and the
native mute state. Do not add another audio artifact.

### 7. The retired local port receives no traffic

Before launch, confirm no unrelated process owns port 8124. Monitor loopback
port 8124 during app quit/relaunch, enabling auto mode, and one join/leave
cycle:

```bash
sudo tcpdump -i lo0 -nn 'tcp port 8124'
```

Pass: stopping the monitor reports `0 packets captured` and Recorder presents
no reconnect behavior.

Evidence: terminal capture summary covering the observed app actions.

## Minimal evidence package

- One candidate version/build screenshot.
- Two or three continuous screen recordings covering cases 1–5.
- One unedited QuickTime virtual-mic audio file.
- One port-8124 capture summary.
- Two retained recordings: one automatic and one manual.

## Deliberately excluded over-testing

- Do not manually enumerate three/30 observations, reset permutations,
  identity replacement, unknown refresh, or ambiguity; deterministic tests
  own those cases.
- Do not build a Teams version, tenant, language, display, or window-size
  matrix.
- Do not test Graph, TeamsJS, Accessibility inspection, or shortcut injection;
  they are non-goals.
- Do not add pixel diffs or a full VoiceOver traversal; focused render and
  accessibility tests own the changed controls.
- Do not repeat every mute combination across recorded mic, virtual mic, and a
  remote Teams participant. The actual virtual-mic artifact proves the privacy
  boundary.
- Do not repeat multiple 30-second absence variants or require one-second stop
  precision.
- Do not reveal or compare old pairing tokens; migration uses a fake secure
  store in automated tests.
