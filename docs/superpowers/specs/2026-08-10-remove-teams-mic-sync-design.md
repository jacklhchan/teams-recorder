# Remove Teams Microphone Sync Design

## Goal

Remove the unreliable Microsoft Teams microphone status and control integration. The floating recording panel microphone button becomes a Recorder-only mute toggle, so a second click always clears Recorder's local mute unless the physical/native input device is independently muted.

## Root cause

The floating panel currently routes through `toggleTeamsAndRecorderMicMute()`. Its unmute path waits for the Teams Accessibility adapter to confirm `.unmuted` before clearing Recorder's local mute. When Teams returns an unknown state, the fail-safe deliberately retains local mute. In the current Teams desktop UI that unknown result is persistent, so the user cannot unmute Recorder from the same button.

## Scope

Remove:

- Teams microphone Accessibility classification, reading, and control.
- Teams microphone polling and synchronization lifecycle.
- The Teams mute authority from Recorder's effective microphone mute calculation.
- Teams microphone status, mismatch, and Accessibility-enable controls from the floating panel.
- Human-readable CLI output for Teams microphone state.

Keep unchanged:

- Teams meeting-window detection and automatic recording.
- Meeting start/end confirmation and suppression behavior.
- Teams screen capture and its controls.
- Recorder local mute and native input/AirPods mute handling.
- Windows implementation and branches.

## Runtime design

The microphone mute gate has two independent sources only:

1. Recorder local mute, controlled by the dashboard, hotkey, CLI, and floating panel.
2. Native input-device mute, observed through the existing input mute controller.

Effective mute is `localMuted || nativeInputMuted`. The floating panel calls the same Recorder-local toggle used by the main dashboard. It does not resolve a Teams process, request Accessibility permission, wait for Teams confirmation, or start a polling task.

If the user clears local mute while the native device remains muted, Recorder remains effectively muted and continues to show the existing input-device explanation. Otherwise the second click immediately returns Recorder to active.

## UI and CLI

The floating microphone row shows Recorder state only. It contains no Teams microphone badge, mismatch warning, unknown state, or Accessibility action.

For protocol-v1 compatibility, JSON status keeps the existing `teamsMicState` field and returns the stable value `notMonitored`. This avoids breaking scripts that decode the current response shape while making it explicit that no observation occurs. Human-readable CLI status omits the Teams microphone line.

## Code removal

Delete the Teams mute Accessibility adapter and sync coordinator, their production wiring, and their dedicated tests. Remove obsolete Teams-mute state from `AppModel`, the microphone gate, floating-panel presentation, and control adapter projection. Retain only the compatibility projection that emits `notMonitored` on the wire.

No replacement abstraction, feature flag, retry mechanism, or dormant background implementation will be added.

## Error handling

There is no Teams microphone operation that can fail after this change. Recorder-local mute remains synchronous. Native input mute continues to use its existing availability and error reporting.

## Focused acceptance tests

- From the floating-panel action path, the first click locally mutes Recorder and the second click locally unmutes it.
- Native input mute still prevents effective unmute without changing the local toggle state.
- App startup and recording lifecycle create no Teams microphone polling or Accessibility requests.
- Floating-panel rendering exposes Recorder mute state but no Teams microphone status or Enable Accessibility action.
- CLI JSON returns `teamsMicState: "notMonitored"`; human output has no Teams microphone status line.
- Existing Teams meeting detection, auto-recording, and screen-capture focused tests remain green.

Testing stays focused on the removed seam and the two retained Teams features; no expanded Accessibility matrix or GUI automation is required.
