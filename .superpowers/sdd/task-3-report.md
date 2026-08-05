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
