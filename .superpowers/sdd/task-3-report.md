# Task 3: Same-User Unix Socket Transport and App Server

## Scope

Implemented only the bounded, one-request/one-response local Unix socket
transport and the app-owned control-server lifecycle. No streaming,
subscriptions, daemon, TCP listener, CLI parser, background launch,
Accessibility integration, packaging, or UI was added.

## TDD evidence

### RED — transport

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter UnixSocketTransportTests
```

Before implementation, compilation failed as expected because
`RecorderControlSocketServer` and `RecorderControlSocketClient` were not in
scope.

### GREEN — transport

The same focused suite passed after implementation: 4 tests, 0 failures.

### RED — app runtime

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter RecorderControlServerRuntimeTests
```

Before implementation, compilation failed as expected because
`RecorderControlServerRuntime` did not exist and `AppRuntime` did not accept a
control-server runtime factory.

### GREEN — app runtime

The same focused suite passed after implementation: 1 test, 0 failures. The
test sends one real `status` request and confirms the response projects the
injected model's output folder.

## Behaviour implemented

- Darwin `AF_UNIX` / `SOCK_STREAM` client and server using `connect`, `bind`,
  `listen`, `accept`, `poll`, `read`, and `write`.
- One newline-delimited JSON request and one newline-delimited JSON response
  per connection.
- A 65,536-byte maximum for both frames, including the terminating newline.
- The public server path is resolved only through the Task 1 validated
  `RecorderControlEndpoint`; the raw short path initializer is internal for
  deterministic tests.
- Existing paths are unlinked only when they are sockets owned by the injected
  current UID.
- Accepted peers are validated with `getpeereid`; wrong-user peers are closed
  before request decoding or model dispatch.
- Accepted clients are handled away from the main actor. The app handler hops
  to `MainActor` to call `AppModelControlAdapter`.
- Listener and client descriptors are closed on their terminal paths. Stop
  shuts down accepted clients, stops the accept loop, and removes only the
  exact socket identity created by that server.
- `AppRuntime` constructs and starts one control runtime, and stops it before
  controller/model shutdown.

## Files changed

- `Sources/RecorderControl/UnixSocketTransport.swift`
- `Sources/RecorderApp/Control/RecorderControlServerRuntime.swift`
- `Sources/RecorderApp/AppRuntime.swift`
- `Tests/RecorderControlTests/UnixSocketTransportTests.swift`
- `Tests/RecorderAppTests/RecorderControlServerRuntimeTests.swift`
- `.superpowers/sdd/task-3-report.md`

## Focused verification

Executed sequentially with the required Xcode/module-cache environment:

```text
UnixSocketTransportTests: 4 tests, 0 failures
RecorderControlServerRuntimeTests: 1 test, 0 failures
AppRuntimeTests: 4 tests, 0 failures
```

The transport and runtime tests had to run outside the workspace's outer
restricted sandbox because that layer rejects `AF_UNIX bind` with `EPERM` even
when SwiftPM receives `--disable-sandbox`.

## Full-suite verification

Executed once outside the outer sandbox with the exact required command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox
```

Result: 1,332 tests executed, 5 skipped, 0 failures in 49.2 seconds.
AVFoundation/CoreAudio tests passed; there were no media-framework failures to
exclude.

## Cleanup and peer-validation evidence

- `testStopRemovesSocket` passes and asserts the transport socket is absent
  immediately after `stop()`.
- `testAppRuntimeServesOneStatusRequestAndRemovesSocketOnShutdown` passes and
  asserts the injected app socket is absent after `AppRuntime.shutdown()`.
- A post-suite filesystem check confirmed
  `/tmp/lmr-<uid>/production.sock` was absent.
- `testPeerUIDMismatchRejectsRequest` passes with injected differing current
  and peer UIDs; the request receives no response and never reaches the
  handler.
- Production peer lookup uses Darwin `getpeereid` on each accepted descriptor.

## Self-review

- The implementation remains one request/one response and adds no persistent
  connection or retry machinery.
- The client uses one monotonic deadline across connect, write, and read.
- `SO_NOSIGPIPE` prevents a closed peer from terminating the process during a
  write.
- Shutdown signals active clients while their descriptor set is locked,
  avoiding stale-descriptor reuse during cleanup.
- Socket cleanup checks device/inode identity so shutdown cannot unlink a
  replacement socket at the same path.
- `git diff --check` passed, and unrelated untracked documentation/brainstorm
  files were not staged or modified.

## Concerns

- `AppRuntime` preserves its existing nonthrowing initializer, so a control
  server startup error is nonfatal (`try?`) and the GUI can continue without a
  control endpoint. The explicit `RecorderControlServerRuntime.start()` API
  remains throwing for callers and tests that need the failure.
- The outer execution sandbox blocks Unix socket binding; socket verification
  therefore requires the same approved out-of-sandbox test context used for
  this report.

---

## Review-fix pass (2026-08-05)

### Findings closed

- Accepted client descriptors are nonblocking. Each client receives one
  injectable finite timeout (5 seconds by default), represented by one
  monotonic `SocketDeadline` shared by request read and response write.
- Accepted descriptors now have close-once ownership. `stop()` removes and
  closes the complete active-client snapshot before returning; concurrent
  handler cleanup is idempotent and cannot operate on a reused descriptor.
- The server checks client activity before dispatch. The app runtime also
  deactivates a MainActor request gate before stopping the server, so a handler
  queued behind shutdown is rejected without touching `AppModel`. `stop()`
  waits only for the non-MainActor accept loop, not for MainActor work.
- One lifecycle lock serializes the complete `start()` and `stop()` operations,
  while a listener generation prevents accept work from being mistaken for a
  later listener generation.
- Failed-start and normal-stop cleanup require an exact device/inode identity.
  If identity acquisition fails, cleanup leaves the path alone rather than
  treating `nil` as a wildcard. Identity is acquired immediately after bind.

### RED evidence

All commands used the required Xcode and module-cache environment:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter UnixSocketTransportTests
```

Before production changes, compilation failed with the expected missing
focused-test seams: `requestTimeout`, `beforeBind`, `beforeOwnedCleanup`, and
`socketIdentityProvider` were extra arguments.

After transport compilation was restored, the runtime regression was also
verified independently by temporarily removing the gate and running:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox \
  --filter RecorderControlServerRuntimeTests/testStoppedRuntimeRejectsCapturedHandlerWithoutTouchingModel
```

Result: 1 test executed, 2 expected assertion failures. The stopped handler
returned no `server_stopped` error and changed the model's auto-mode setting.
The gate implementation was then restored before GREEN verification.

### GREEN evidence

Fresh covering-suite commands, run sequentially outside the outer sandbox:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter UnixSocketTransportTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter RecorderControlServerRuntimeTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
swift test --disable-sandbox --filter AppRuntimeTests
```

Exact results:

- `UnixSocketTransportTests`: 9 tests, 0 failures.
- `RecorderControlServerRuntimeTests`: 2 tests, 0 failures.
- `AppRuntimeTests`: 4 tests, 0 failures.
- Total covering tests: 15 tests, 0 failures.

No full suite was rerun for this focused review fix, as requested. The prior
full-suite result at `1643311` remains 1,332 executed, 5 skipped, 0 failures.

### Focused regression coverage

- A partial-frame client is closed at the injected 50 ms server deadline.
- `stop()` is proven to leave the accepted descriptor at `EBADF` before it
  returns.
- A captured runtime handler is rejected after stop and cannot mutate the
  model.
- Deterministic one-shot synchronization proves concurrent start/start and
  stop/start operations serialize without race loops.
- Injected identity acquisition failure replaces the bound path with a live
  socket and proves failed-start cleanup does not unlink that replacement.

### Files changed in the review-fix pass

- `Sources/RecorderControl/UnixSocketTransport.swift`
- `Sources/RecorderApp/Control/RecorderControlServerRuntime.swift`
- `Tests/RecorderControlTests/UnixSocketTransportTests.swift`
- `Tests/RecorderAppTests/RecorderControlServerRuntimeTests.swift`
- `.superpowers/sdd/task-3-report.md`

`Sources/RecorderApp/AppRuntime.swift` required no edit: it already calls
`controlServerRuntime.stop()` before `recordingController.shutdown()` and
`model.shutdown()`; the runtime's strengthened `stop()` now supplies the
required deactivation semantics.

### Self-review

- Deadline construction occurs once per accepted connection after same-user
  validation and before request reading; the identical value is passed to both
  read and write loops.
- Descriptor ownership serializes each nonblocking syscall with close, while
  poll snapshots are revalidated before any later syscall. Both `stop()` and
  async terminal cleanup call the same idempotent close operation.
- The lifecycle lock is never held while waiting for MainActor work. It only
  covers socket setup/teardown and the accept-loop join.
- The exact-identity guard runs before the cleanup test hook and before
  `lstat`, so a missing identity cannot remove any path.
- Tests use one-shot synchronization only; no load, fuzz, repeated race loop,
  daemon, actor redesign, or unrelated behavior was added.
- `git diff --check` passed. Existing unrelated untracked documentation and
  brainstorm files were not modified or staged.

### Remaining concerns

- The production server timeout is a fixed finite 5 seconds. Only the internal
  test initializer injects a shorter value because there is no current product
  requirement for a public timeout setting.
- AF_UNIX binding remains blocked by the outer workspace sandbox, so these
  focused socket suites require the approved out-of-sandbox command above.
