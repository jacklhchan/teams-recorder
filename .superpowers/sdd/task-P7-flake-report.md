# P7 Screen Resolver Timing Flake

## RED / reproduction reasoning

P7 full pass 1 completed with 735 passed, 1 skipped, and 0 failures. P7 full
pass 2 failed only
`testResolverRefreshesEverySecondWhileRecordingOrRequested` at line 83 after
the two-second `waitUntil` deadline. A focused rerun then passed in 0.103s.
The same exact-count flake had also occurred in earlier runs.

The test took `teamsRefreshCount` as its baseline after `engine.isRecording`
became true, but before the recording-start lifecycle had necessarily finished.
That lifecycle performs `refreshTeamsScreenCaptureNow()` after the engine starts
and then starts the manual ticker loop. If the lifecycle refresh and the fired
ticker refresh both completed after the baseline, the count could advance from
`baseline` to `baseline + 2`; the deliberately strict `== baseline + 1`
condition could never become true.

## GREEN

The test now waits for the recording-start lifecycle to finish before taking its
baseline. `TeamsScreenTestTicker.fireAndWaitForConsumption()` also acknowledges
that the particular manually fired tick has been received by the ticker loop
before the test waits for its one resolver refresh. The assertion remains exact,
so an unrelated refresh cannot satisfy it.

- Focused test: 25 consecutive passes (about 0.085s to 0.144s each).
- `AppModelScreenCaptureTests`: 37 passed, 0 failed, 0.689s.
- `git diff --check`: passed before commit.

Implementation commit: `4306772c6bcf792db418cbdf971986548c802881`

## Review correction

Review found that `fireAndWaitForConsumption()` did not bind its acknowledgement
to the tick it fired: an older pending tick could satisfy it, and its
continuation had no cancellation exit. The helper and acknowledgement state were
removed. The deterministic barrier is solely waiting for the recording-start
lifecycle to complete before capturing the baseline; the existing exact
`teamsRefreshCount == baseline + 1` wait remains both the tick completion signal
and assertion.

Review-fix validation: the focused test passed 20 consecutive times (about
0.083s to 0.144s); `AppModelScreenCaptureTests` passed 37 tests with 0 failures
in 0.572s.
