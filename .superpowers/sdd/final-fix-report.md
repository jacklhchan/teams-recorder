# Final review fix report

Date: 2026-08-18

Base: `838bd48`

Scope: final-review findings for per-job transcription and floating-panel collapse

## Result

All requested findings are fixed with the existing transcription request model:

- A canonical imported recording now publishes one shared `TranscriptionRequestDraft` into the Recordings workspace instead of starting ASR with implicit defaults.
- Cancel clears the draft without starting a job. Every new request starts with Cantonese (`yue`) and a blank prompt.
- Confirm clears the draft and enters the existing ID-based transcription path, which revalidates the canonical session before provider/privacy/single-job admission and forwards the confirmed per-job options.
- The compatibility entry point for genuine non-UI callers still supplies explicit default options.
- The language picker accessibility value uses the language display name.
- Recording-panel accessibility observation returns `nil` when the mounted control/value cannot be observed; it never substitutes presenter state.
- The legacy manifest no longer persists prompt-derived character counts. The outgoing request prompt is unchanged.

No second dialog or draft-state model was introduced.

## RED evidence

The first sandboxed Swift invocation was discarded because the sandbox denied writes to the default Clang module cache. All valid Swift evidence below used explicit `/tmp` module caches; AppKit/SwiftUI render tests were run outside the filesystem sandbox because the sandbox blocks required macOS UI services.

### Import to shared request sheet

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/recorder-final-fix-clang-cache \
  SWIFT_MODULECACHE_PATH=/tmp/recorder-final-fix-swift-cache \
  swift test --disable-sandbox \
  --filter 'AppModelTranscriptionTests/testImportedTranscription|RecorderWorkspaceRenderTests/testTranscribeImported|PRBFeatureBridgeTests/testCanonicalImports|AppModelLibraryFeatureIntegrationTests/testIndexedImportedAudioRequests|AppModelLibraryFeatureIntegrationTests/testForgedImportedAudio'
```

After correcting one test-authoring autoclosure mistake, the valid RED rerun exited 1 with only expected compile errors: `AppModel` lacked the request/cancel/submit draft API, and `PRBFeatureBridge.Routes` lacked the request-options route while tests rejected the former direct-start route.

### Picker accessibility display name

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/recorder-final-fix-clang-cache \
  SWIFT_MODULECACHE_PATH=/tmp/recorder-final-fix-swift-cache \
  swift test --disable-sandbox \
  --filter 'AppModelTranscriptionTests/testImportedTranscriptionRequestDefaultsAndCancelDoesNotStart'
```

Result: exit 1, expected compile failure because `TranscriptionRequestDraft.languageAccessibilityValue` did not exist.

### Recording-panel AX fail-closed observation

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/recorder-final-fix-clang-cache \
  SWIFT_MODULECACHE_PATH=/tmp/recorder-final-fix-swift-cache \
  swift test --disable-sandbox \
  --filter 'RecordingControllerPanelTests/testPanelToggleAccessibilityObservationFailsClosedWhenControlIsUnmounted'
```

Result: exit 1, one test with 3 expected assertion failures: the observer returned presenter-derived `Expanded`/`Collapsed` values rather than `nil` when no actual control value was observable. The final test name was clarified to `...WhenControlCannotBeObserved` without changing the contract.

### Legacy manifest prompt metadata

```sh
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_openai_asr_longform.CoordinatorTests.test_manifest_records_acceptance_immediately_after_chunk
```

Result: 1 test, 1 expected failure because `prompt_character_count` was present.

## GREEN evidence

All Swift commands used the same explicit module-cache environment shown above.

```sh
swift test --disable-sandbox \
  --filter 'RecorderWorkspaceRenderTests/testTranscribeImportedCanonicalSessionOpensSharedSheetWithoutStarting'
```

Result: 1 test, 0 failures.

```sh
swift test --disable-sandbox \
  --filter 'AppModelTranscriptionTests/testImportedTranscriptionRequestDefaultsAndCancelDoesNotStart'
```

Result: 1 test, 0 failures.

```sh
swift test --disable-sandbox \
  --filter 'RecordingControllerPanelTests/testPanelToggleAccessibilityObservationFailsClosed|RecordingControllerPanelTests/testRecordingControllerCollapseRoundTrip'
```

Result: 2 tests, 0 failures.

```sh
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_openai_asr_longform.CoordinatorTests.test_manifest_records_acceptance_immediately_after_chunk
```

Result: 1 test, OK.

Directly affected aggregate:

```sh
swift test --disable-sandbox \
  --filter 'PRBFeatureBridgeTests|AppModelLibraryFeatureIntegrationTests/(testIndexedImportedAudioRequestsOptionsAndNeverStartsASRImmediately|testForgedImportedAudioEventsRequireCurrentCanonicalLibraryAdmission)|AppModelTranscriptionTests/testImportedTranscription|RecorderWorkspaceRenderTests/testTranscrib|RecordingControllerPanelTests/(testPanelToggleAccessibilityObservationFailsClosedWhenControlCannotBeObserved|testRecordingControllerCollapseRoundTrip)'
```

Result: 31 tests, 0 failures.

Existing UI confirmation regression after the shared binding change:

```sh
swift test --disable-sandbox \
  --filter 'RecorderWorkspaceRenderTests/testTranscriptionSheetSubmitsSelectedLanguageAndPrompt'
```

Result: 1 test, 0 failures.

## Bounded feature verification

The existing bounded filter was run exactly once; no full suite was run.

```sh
swift test --disable-sandbox \
  --filter 'OpenAICompatibleProviderRepositoryTests|TranscriptionJobCoordinatorTests|AppModelTranscriptionTests|AIProviderSettingsModelTests|AIProviderSettingsRenderTests|RecorderWorkspaceRenderTests/testTranscrib|FloatingPanelCollapseTests|RecordingControllerPanelTests|TeamsAutoMeetingCountdownRenderTests|TeamsAutoMeetingPresentationTests'
```

Result: **146 tests, 0 failures** (exit 0). The historical 138-style total increased because the branch now contains additional focused tests.

## Release build

Run exactly once:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/recorder-final-fix-clang-cache \
  SWIFT_MODULECACHE_PATH=/tmp/recorder-final-fix-swift-cache \
  swift build --disable-sandbox -c release
```

Result: **Build complete**, exit 0.

Observed warnings are pre-existing: read-only SwiftPM user caches, AVFoundation deprecations, and the Swift 6 actor-isolation warning for `AlwaysAllowThirdPartyProcessing.shared`.

## Files

- `Sources/RecorderApp/AppModel.swift`
- `Sources/RecorderApp/PRBFeatureBridge.swift`
- `Sources/RecorderApp/UI/RecordingsLibraryView.swift`
- `Sources/RecorderApp/Views/TranscriptionRequestSheet.swift`
- `Sources/RecorderApp/Views/RecordingControllerPanel.swift`
- `scripts/openai_asr_longform.py`
- `Tests/RecorderAppTests/AppModelLibraryFeatureIntegrationTests.swift`
- `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`
- `Tests/RecorderAppTests/PRBFeatureBridgeTests.swift`
- `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`
- `Tests/RecorderAppTests/RecordingControllerPanelTests.swift`
- `Tests/ScriptTests/test_openai_asr_longform.py`
- `.superpowers/sdd/final-fix-report.md`

The pre-existing edits to `.superpowers/sdd/task-2-report.md` and `.superpowers/sdd/task-3-report.md` are unrelated and intentionally excluded from staging.

## Self-review

- Import ownership remains in `PRBFeatureBridge`: only a current, canonical, deduplicated imported event may request options.
- Confirmation delegates to the existing ID-based `AppModel.transcribe(sessionID:options:)`, retaining canonical revalidation, privacy/provider checks, single active-job ownership, and the existing publication path.
- No provider profile, privacy policy, job coordinator, transcript publication, or import storage behavior was changed.
- `AppModel.transcribe(session:)` remains the explicit-default compatibility path for non-UI callers.
- Draft prompt data is limited to the existing request sheet flow and is not added to persisted manifests.
- Panel AX inspection follows the approved nullable-observation route: missing control/value produces `nil`, and tests assert that fail-closed result rather than inferred presenter state.
- `git diff --check` was clean before final staging; staged-only diffcheck is recorded by the commit workflow.

## Concerns

No functional blocker or known regression remains. The presenter's native hierarchy does not expose the SwiftUI toggle value in this test host, so the allowed nullable fail-closed assertion is used; separate mounted render tests continue to exercise the actual toggle, collapse geometry, and labels. Existing build warnings listed above remain outside this fix scope.
