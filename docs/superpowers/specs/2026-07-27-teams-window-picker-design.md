# Teams Window Picker Filtering and Naming Design

## Goal

Make the standalone Teams same-stream viability probe's window picker useful to
a person who does not know ScreenCaptureKit internals. By default, the picker
shows likely meeting or shared-content windows with understandable names while
retaining an explicit escape hatch for unusual Teams window layouts.

This change is limited to discovery, presentation, and selection. It does not
change the active `SCStream`, content-filter transitions, audio capture,
evidence generation, or the live viability gate.

## Current Behavior

The probe requests all windows from `SCShareableContent` with
`onScreenWindowsOnly: false`, keeps every window owned by
`com.microsoft.teams2`, and sorts their display strings alphabetically.

Teams creates user-facing windows as well as renderer, notification, utility,
off-screen, and untitled windows. The current picker therefore exposes entries
such as `Teams NRC (1622)` and `Teams window 1641`. The number is a transient
`CGWindowID`, but the UI gives it the visual prominence of a useful name.

## Chosen Approach

Use a hybrid picker:

1. Recommended mode is the default and presents only plausible user-facing
   meeting or shared-content windows.
2. A `Show all Teams windows` toggle exposes every Teams-owned window for
   manual recovery.
3. Labels describe a window's likely role and dimensions. Transient window IDs
   are included only in all-windows mode.
4. If recommended mode has no candidates, the picker automatically exposes all
   windows and reports that fallback without changing the user's stored toggle.

This avoids normal-case clutter without making filtering a new failure mode.

## Window Descriptor

ScreenCaptureKit objects are adapted into a testable value descriptor before
classification:

- `windowID`
- normalized title
- frame width and height
- `isOnScreen`
- window layer

Ownership remains enforced at the discovery boundary with the existing
`com.microsoft.teams2` bundle-identifier check.

## Recommended-Mode Rules

A window is hidden from recommended mode when any of these conditions is true:

- its normalized title is exactly `Teams NRC`;
- its window layer is not the normal application layer;
- it is not currently on screen;
- its width is less than 320 points or its height is less than 180 points.

An untitled window is not rejected solely because its title is empty. A
substantial, normal-layer, on-screen untitled window can be a meeting pop-out or
shared-content surface and remains selectable.

The thresholds are presentation heuristics, not capture invariants. All hidden
windows remain available immediately through all-windows mode.

## Display Names

Recommended mode uses these labels:

- exact title `Microsoft Teams`:
  `Main Teams window - <width>x<height>`
- empty title:
  `Possible meeting or shared-content window - <width>x<height>`
- any other retained title:
  `<title> - <width>x<height>`

All-windows mode appends `- Window ID <id>` to the same understandable label.
Known internal windows are named explicitly, for example:
`Teams internal window (NRC) - <width>x<height> - Window ID <id>`.

Dimensions are rounded to whole points. Labels remain ASCII to match the
project's source conventions and stay readable in the compact native picker.

## Ordering and Selection

Ordering is deterministic:

1. exact `Microsoft Teams` title;
2. other titled windows;
3. untitled windows;
4. larger frame area before smaller frame area;
5. window ID as the final tie-breaker.

Refreshing preserves the selected `windowID` when it remains present in the
active mode. Otherwise, the first ranked candidate is selected. Toggling
all-windows mode also preserves the selected window when possible.

Changing picker visibility or labels never changes an active capture filter.
The mode toggle is disabled while the probe is capturing so the candidate set
cannot change underneath a live dwell. The picker itself remains enabled
because the viability procedure must select different windows before applying
successive window filters.

## UI

The probe view adds one native toggle beside the existing picker:

- `Show all Teams windows`

The existing status line reports candidate counts after refresh:

- recommended mode: `3 likely Teams windows; 5 internal or inactive windows hidden.`
- automatic fallback: `No likely meeting windows found; showing all 8 Teams windows.`
- all-windows mode: `Showing all 8 Teams windows.`

No additional card, dialog, or setup flow is introduced.

## Error Handling

- ScreenCaptureKit enumeration errors retain the existing error status.
- An empty Teams result leaves the picker empty and keeps Start disabled.
- If a selected recommended window disappears on refresh, selection moves to
  the next ranked candidate.
- Refreshing or changing the picker selection does not alter the running
  stream. As today, only the explicit filter buttons update the content filter.
  The existing picker remains available for filter-switch testing.

## Tests

Classification and naming are covered with pure unit tests independent of
`SCWindow` construction:

- hides exact `Teams NRC` in recommended mode;
- hides small, off-screen, and non-normal-layer windows;
- keeps a substantial untitled window;
- labels main, untitled, titled, and NRC windows understandably;
- omits IDs in recommended mode and includes them in all-windows mode;
- ranks candidates deterministically;
- preserves selection across refresh and mode changes;
- falls back to all windows when no recommended candidates exist;
- leaves the viability report and stream/filter behavior unchanged.

The focused tests run before the full Swift suite and app build.

## Acceptance Criteria

1. The default picker does not show `Teams NRC`, small utility windows,
   off-screen windows, or non-normal-layer windows.
2. A substantial untitled Teams meeting/share window remains available.
3. Default labels communicate role and dimensions without exposing raw IDs.
4. `Show all Teams windows` exposes every enumerated Teams-owned window with
   its window ID.
5. Selection remains stable by `windowID` where possible.
6. The mode toggle cannot change the candidate set during capture, while the
   picker remains available for window-filter dwell testing.
7. Existing same-stream viability tests, the full Swift test suite, and the app
   build pass without changes to capture semantics.
