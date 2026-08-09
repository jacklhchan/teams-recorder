# Task 2: Idempotent AppModel Control Adapter

## Scope

Implemented the in-process, main-actor control adapter only. No socket server,
CLI parsing, launch behavior, Accessibility integration, Teams mute polling, or
UI was added.

## TDD evidence

### RED

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter AppModelControlAdapterTests
```

The command failed as expected before implementation: `cannot find
'AppModelControlAdapter' in scope` and `AppModel has no member
'setRecorderMicMuted'`.

### GREEN

The same focused command passed after implementation: 7 adapter tests, 0
failures.

## Behaviour covered

- Exact `on`/`off` Auto Mode commands are idempotent.
- `start` does not invoke a second capture start when already recording.
- `stop` with no active or pending work is a successful no-op.
- Exact `mute`/`unmute` commands set, rather than toggle, the recorder-local
  mute source.
- Unsupported protocol versions and invalid arguments return stable error
  codes without mutation.
- Status projects selected microphone, permissions, Auto Mode, ownership,
  active recording folder, local/native/effective mute values, and uses
  `unknown` for the not-yet-implemented Teams mute source. It contains no
  provider credentials.

## Files changed

- `Sources/RecorderApp/AppModel.swift`
- `Sources/RecorderApp/Control/AppModelControlAdapter.swift`
- `Tests/RecorderAppTests/AppModelControlAdapterTests.swift`
- `Tests/RecorderAppTests/AppModelMuteTests.swift`

## Focused verification

- `AppModelControlAdapterTests`: 7 tests passed.
- `AppModelMuteTests`: 14 tests passed.
- `TeamsAutoMeetingCoordinatorTests`: 31 tests passed.

## Full-suite verification

Executed the full Swift suite with the required Xcode/module-cache environment.
The suite did not complete cleanly because three pre-existing
`AVFoundationTranscriptionChunkerTests` failed while opening/exporting audio
with `com.apple.coreaudio.avfaudio` error `1718449215`:

- `testLongAudioExportsReopenableBoundedM4AChunks`
- `testShortAudioPassesThroughWithoutWorkspaceArtifact`
- `testShortOversizedInputIsCompressedInsteadOfPassedThrough`

The failure occurs in the unrelated AVFoundation fixture setup. The full run
continued far enough to execute all 7 `AppModelControlAdapterTests`, which
passed. Focused adapter, mute, and auto-coordinator suites all passed.

## Self-review

- Commands are dispatched on `@MainActor` and retain no model ownership cycle.
- Operation rejection is represented separately from transport success.
- All status enum conversions use exhaustive `switch` statements; no
  `String(describing:)` serialization is used.
- Control start intentionally bypasses the GUI permission-request workflow,
  while preserving its readiness and lifecycle guards.
- Existing GUI mute wording remains unchanged for the native-input-remains-
  muted case.

## Concerns

- The Teams mute source is intentionally reported as `unknown` until the later
  Accessibility/synchronization task supplies it.
- SwiftPM emits pre-existing cache-access and weak-variable warnings in this
  sandbox; they do not originate from this task.

---

## Review-fix follow-up (Task 2)

### RED

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter AppModelControlAdapterTests
```

Result: 8 tests executed, 5 expected assertion failures. The newly added
active Teams-automatic stop case passed, proving the existing lifecycle path
suppresses the current meeting. The new table-driven argument case failed:
`status` and `stop` accepted an argument, while `start` returned `not_ready`
instead of `invalid_argument`.

### GREEN

Ran the same command after adding nil-argument validation for `status`,
`start`, and `stop`.

Result: `AppModelControlAdapterTests` — 8 tests executed, 0 failures.

### Files changed

- `Sources/RecorderApp/Control/AppModelControlAdapter.swift`
- `Tests/RecorderAppTests/AppModelControlAdapterTests.swift`

### Self-review

- `status`, `start`, and `stop` now reject every non-nil argument before they
  can inspect or mutate model state, returning the stable `invalid_argument`
  error.
- The one new active-auto regression test verifies control stop completes and
  leaves the app coordinator status at `suppressedUntilMeetingEnd`; it does
  not duplicate a pending-start matrix.
- The injected coordinator and deterministic ticker exist only in the adapter
  test helper, avoiding production changes and unrelated surface area.

### Concerns

- SwiftPM still prints sandbox cache-access warnings. The specified focused
  suite itself passes with no test failures.

## Controller follow-up verification

The three AVFoundation failures were reproduced only inside the restricted
sandbox. The controller reran the affected suite outside that sandbox:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AVFoundationTranscriptionChunkerTests
```

Result: 4 tests executed, 0 failures. This confirms the reported full-suite
failures were a sandbox/CoreAudio restriction rather than a Task 2 regression.
