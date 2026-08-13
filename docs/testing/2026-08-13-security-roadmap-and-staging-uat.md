# Security roadmap and staging UAT — 2026-08-13

## Candidates under test

- Installed candidate: `Local Meeting Recorder Staging` `0.2.0 (350)`, built
  from `d325604` (`fix: autoplay verified test recordings`).
- Successor candidate: `Local Meeting Recorder Staging` `0.2.0 (351)`, built
  from `3f176a0` (`fix: keep recovery actions visible`). Build 351 includes the
  reviewed opt-in diagnostic-retention work and fixes the Recovery page so its
  title, retained count, and actions remain visible while only the item list
  scrolls. It is verified but is not installed.
- Bundle ID: `local.meeting.recorder.staging`
- Signature: ad-hoc staging signature
- Bundle verification: Info.plist, PrivacyInfo.xcprivacy, and
  `codesign --verify --deep --strict` passed.
- Installed staging app is build 350. The previously installed build 347 is
  retained as the recoverable backup at
  `/private/tmp/Local Meeting Recorder Staging old-347-before-350.app`.
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
| Recoverable 350 installation | PASS | Installed bundle reports build 350; Info/Privacy and strict codesign verification passed. The CLI symlink resolves to its embedded helper, the build folder has no duplicate staging bundle, and build 347 remains recoverable. |
| Installed-350 CLI default-off | PASS | `recorderctl status --json` returned the finite `control_disabled` error and exit 3. Local control was not enabled for this check. |
| Opt-in diagnostic retention | PASS — 16/16 focused | Default-off scanner, current-policy/class/age revalidation before descriptor-bound deletion, persisted count-only aggregate, and truthful Settings scope. The current architecture exposes no safe retained published session, so it has zero candidates and never scans OneDrive or the destination. Independent review found no Critical or Important issue. |
| Recovery fixed-actions layout | PASS — 5/5 focused | With 30 needs-attention items in an 860×680 host, the title, retained count, and `Open Local Copies` remain in the visible viewport; only item groups scroll. Independent review found no findings. |
| Successor 351 bundle | PASS | Release build, Info.plist, PrivacyInfo.xcprivacy, and `codesign --verify --deep --strict` passed. Build 351 has not replaced installed build 350. |
| GitHub main bounded CI | PASS | [Run 31674648708](https://github.com/jacklhchan/teams-recorder/actions/runs/31674648708) completed successfully at `ff96d51`: targeted transcription, the named storage gate, the full Swift package suite, workspace stability, Python scripts, the production-tree Accessibility audit, policy checks, app packaging, and virtual-microphone contracts all passed. |

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

1. Re-authorize macOS capture/microphone access if the new ad-hoc signature
   causes TCC to require it.
2. Run bounded staging checks for: Recording Health; Re-arm Now after manual
   suppression; Privacy Mode local-only/zero-provider-work; Recovery Center;
   CLI default-off then explicit opt-in; rapid Meet now end/restart; floating
   local microphone mute then unmute; and publication while OneDrive is
   available/unavailable.
3. The live microphone switch remains fail-closed in production source
   (`supportsLiveMicrophoneSwitch == false`). It may be enabled only after a
   physical A→B→A switch preserves one recording and passes source/generation
   fences.
4. The sandbox bookmark spike still needs a visible, user-confirmed NSOpenPanel
   selection and a second-process verification. Automation did not expose the
   panel, and no coordinate guess or automatic folder selection was used.
5. Production release-manifest operation needs a named release owner, active
   key ID/public key, private-key custody and rotation/revocation procedure,
   authoritative distribution channel, and rollback floor. No production key
   material is generated or inferred by this UAT.

## Acceptance status

**In progress.** The code/security review gates, green GitHub main CI,
recoverable build 350 installation, installed CLI link/default-off check,
OneDrive bookmark persistence check, opt-in retention review, and Recovery
fixed-actions review are complete. Verified build 351 is ready for a separately
approved recoverable installation. On first launch, build 350 retained the exact
OneDrive destination but macOS required Screen/System Audio permission again;
the microphone also had no selected device. The app reported 30 retained local
recordings needing attention, so publication is not claimed complete. Bounded
runtime UAT, the sandbox bookmark, and release-key operational activation remain
open.
