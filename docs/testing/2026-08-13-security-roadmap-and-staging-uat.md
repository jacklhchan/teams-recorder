# Security roadmap and staging UAT — 2026-08-13

## Candidate under test

- Repository HEAD at the latest product fix: `d325604`
  (`fix: autoplay verified test recordings`)
- Candidate: `Local Meeting Recorder Staging` `0.2.0 (350)`, built from
  `d325604`.
- Bundle ID: `local.meeting.recorder.staging`
- Signature: ad-hoc staging signature
- Bundle verification: Info.plist, PrivacyInfo.xcprivacy, and
  `codesign --verify --deep --strict` passed.
- Installed staging app remains build 347. Build 350 has **not** been installed
  pending explicit approval for the recoverable `/Applications` replacement.
- The separate build 348 live-microphone experiment is retained only under
  `/private/tmp/recorder-live-mic-uat-348/`; it is not the release candidate.

Production Developer ID signing, Hardened Runtime, and notarization are
explicitly outside this roadmap change. This document does not claim that an
ad-hoc build is a production distribution artifact.

## Automated evidence

| Gate | Result | Notes |
| --- | --- | --- |
| Named reliable-storage release gate | PASS — 18/18 | Re-run after the unique pending-session-name fix. |
| Accessibility API production-tree audit | PASS | The script scanned the current production tree; CI and release workflows call the same gate. |
| Python script discovery | PASS — 131/131 | Run once outside the managed sandbox. |
| Focused rapid-restart regressions | PASS — 4/4 | Covers a same-timestamp sequential start, the original ScreenCapture rapid restart, Teams automatic metadata admission, and disabled Provider Test behavior. |
| RecordingEngine state suite | PASS — 83/83 | Reported by the focused implementation run. |
| Teams auto-meeting suite | PASS — 31/31 | Uses isolated AppPaths and validates admitted pending metadata rather than the destination before publication. |
| Provider Settings render suite | PASS — 5/5 | Disabled rendered controls no longer bypass SwiftUI disabled semantics in the test harness. |
| Verified test-recording autoplay + double-stop gate | PASS — 14/14 | Autoplay waits for a matching verified publication completion; stale completion consumes the one-shot intent and cannot play later. Double-stop still performs one source stop and one writer close. |
| Installed-347 OneDrive bookmark | PASS | Selected the exact `Meeting Recording` folder through NSOpenPanel. After Quit and GUI relaunch, the app still showed the full path and `Ready to save recordings here`; no Downloads fallback occurred. |
| Full Swift package suite | NOT PASS | The initial run exposed three independently reproducible regressions and hung later. A post-fix run exposed the autoplay and stale double-stop expectation, then also hung later in the Engine suite; both are now focused-green. No clean full-suite completion is claimed. |

The session-name production fix retains no-overwrite admission: each readable
timestamp now has a UUID suffix, while `RecordingPendingStore` continues to
reject an existing direct child.

## Security and privacy controls verified by focused review

- Local CLI control is persisted, user-visible, and default-off; disabled
  control does not start the server.
- CLI status and errors use finite safe projections and omit paths, device
  UIDs, provider endpoints, raw status/errors, prompts, transcripts,
  credentials, and bookmark bytes.
- Privacy Mode gates new third-party ASR/meeting-intelligence work and
  invalidates in-flight provider results without deleting editable local
  artifacts.
- Transcription diagnostics and Meeting Intelligence recovery messages use the
  same dynamic lifecycle policy. Redaction-off recovery persists an empty
  compatibility message rather than diagnostic content.
- Safe support bundles are typed allowlists, bounded, owner-only, and write
  through an opened and `fstat`-validated root descriptor.
- Recovery Center exposes safe aggregate/item states without filesystem paths,
  identities, health payloads, metadata, or raw failure categories.
- The release-manifest verifier binds version, build, commit, ZIP basename and
  digest, provenance, key ID, and rollback floor. The committed keyring remains
  deliberately empty, so production release authenticity is not operationally
  ready until a release owner completes key custody and channel handoff.
- The current non-sandboxed product tree contains no Accessibility API usage.
  The isolated App Sandbox spike still shows AF_UNIX/public CLI incompatibility.

## Runtime gates still required

The following are deliberately not marked as passed:

1. Recoverably install build 350 over build 347, then re-verify the installed
   bundle and embedded CLI target.
2. Re-authorize macOS capture/microphone access if the new ad-hoc signature
   causes TCC to require it.
3. Run bounded staging checks for: Recording Health; Re-arm Now after manual
   suppression; Privacy Mode local-only/zero-provider-work; Recovery Center;
   CLI default-off then explicit opt-in; rapid Meet now end/restart; floating
   local microphone mute then unmute; and publication while OneDrive is
   available/unavailable.
4. The live microphone switch remains fail-closed in production source
   (`supportsLiveMicrophoneSwitch == false`). It may be enabled only after a
   physical A→B→A switch preserves one recording and passes source/generation
   fences.
5. The sandbox bookmark spike still needs a visible, user-confirmed NSOpenPanel
   selection and a second-process verification. Automation did not expose the
   panel, and no coordinate guess or automatic folder selection was used.
6. Retention needs the product-owner choice already identified by the design:
   keep it disabled/unavailable (recommended for the current architecture), or
   add a new app-owned diagnostic storage class. Scanning/deleting the selected
   OneDrive destination is not acceptable.
7. Production release-manifest operation needs a named release owner, active
   key ID/public key, private-key custody and rotation/revocation procedure,
   authoritative distribution channel, and rollback floor. No production key
   material is generated or inferred by this UAT.

## Acceptance status

**In progress.** The code/security review gates, build 350 verification, and
installed-347 OneDrive bookmark persistence check are complete. The app still
reported 30 retained local recordings and 13 items needing attention after the
destination change, so publication is not claimed complete. Installation of
350, bounded runtime UAT, retention choice, sandbox bookmark, and release-key
operational handoff remain open.
