# Security roadmap and staging UAT — 2026-08-13

## Candidates under test

- Previous installed candidate: `Local Meeting Recorder Staging` `0.2.0 (351)`,
  built from `3f176a0` (`fix: keep recovery actions visible`).
- Installed candidate: `Local Meeting Recorder Staging` `0.2.0 (352)`, built
  from `c7b6501` (`fix: close timed out publication descriptors`). Build 352
  includes the reviewed bounded destination-open path in addition to the
  diagnostic-retention and Recovery fixed-action work present in build 351.
- Bundle ID: `local.meeting.recorder.staging`
- Signature: ad-hoc staging signature
- Bundle verification: Info.plist, PrivacyInfo.xcprivacy, and
  `codesign --verify --deep --strict` passed.
- Installed staging app is build 352. The previously installed build 351 is
  retained as the verified recoverable backup at
  `/private/tmp/Local Meeting Recorder Staging old-351-before-352.app`; build
  350 also remains recoverable at
  `/private/tmp/Local Meeting Recorder Staging old-350-before-351.app`.
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
| Recoverable 351 installation | PASS | The app was normally quit, build 350 was moved to a verified recoverable backup, and build 351 was installed. Installed Info.plist, PrivacyInfo.xcprivacy, and strict codesign passed; the fixed CLI symlink resolves to the installed embedded helper. |
| Installed-351 CLI default-off | PASS | `/usr/local/bin/recorderctl status --json` returned the finite `control_disabled` error and exit 3 without enabling local control. The installer recognized the existing owned fixed-path link as the correct no-op target; no interactive sudo mutation was required. |
| Installed-351 Recovery layout | PASS | On the target Mac with 30 needs-attention items, fresh Accessibility state simultaneously exposed `Recovery`, `30 recordings retained locally`, the independently scrollable item list, and `Open Local Copies`. No Recovery action was invoked. |
| Build-351 bounded manual recording | PASS with capture-health warning | A 33.3227-second MP4 was finalized locally and remained readable by `ffprobe`; the health projection reported no system or mic signal and 1,598 late frames, so this is retention/finalization evidence, not healthy microphone evidence. The exact pending source remained intact. |
| Build-351 publication hang diagnosis | CONFIRMED | A process sample placed the publication worker in destination component `openat` before staging creation. The queue item remained retained with `attemptCount=2`; restart reset `publishing` to pending but retried the same blocking syscall. |
| Destination-open deadline fix | PASS — 24/24 focused | `publish` and `validatePublished` now run each destination component open on one process-wide serial worker with a two-second deadline. Timeout maps to destination unavailable, writes no staging content, retains the pending source, prevents queued timed-out work from opening later, and closes parent/late descriptors. Independent review found no Critical or Important issue. |
| Recoverable 352 installation | PASS | Build 351 was normally replaced with verified build 352 and retained as the backup above. Installed Info.plist/Privacy manifest and strict deep codesign passed; the installed bundle reports build 352. |
| Installed-352 CLI default-off | PASS | `/usr/local/bin/recorderctl` resolves to build 352's embedded helper. `status --json` returned finite `control_disabled` and exit 3, without enabling local control or starting a control transport. |
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

1. Re-authorize macOS capture/microphone access if build 352's new ad-hoc
   signature causes TCC to require it.
2. Run bounded staging checks for: Recording Health; Re-arm Now after manual
   suppression; Privacy Mode local-only/zero-provider-work; Recovery Center;
   CLI default-off then explicit opt-in; rapid Meet now end/restart; floating
   local microphone mute then unmute; and publication while OneDrive is
   available/unavailable.
3. The live microphone switch remains fail-closed in production source
   (`supportsLiveMicrophoneSwitch == false`). It may be enabled only after a
   physical A→B→A switch preserves one recording and passes source/generation
   fences.
4. The product owner selected the documented non-sandbox baseline. The
   sandbox bookmark spike remains useful feasibility evidence but is not a
   production-migration acceptance gate under that selected architecture.
5. Production release-manifest operation needs a named release owner, active
   key ID/public key, private-key custody and rotation/revocation procedure,
   authoritative distribution channel, and rollback floor. No production key
   material is generated or inferred by this UAT.

## Acceptance status

**In progress.** The code/security review gates, destination-open deadline,
recoverable build 352 installation, installed CLI link/default-off check,
OneDrive bookmark persistence check, opt-in retention review, and Recovery
fixed-actions runtime check are complete. Build 351 reproduced the destination
open hang while retaining the exact pending source; build 352 contains the
reviewed fix. A final unlocked-session check must show that the retained item
leaves `publishing`, either reaches `waitingForDestination` within the deadline
or publishes exactly once when OneDrive responds, and never loses its local
source. Release-key operational activation remains an external governance gate.
