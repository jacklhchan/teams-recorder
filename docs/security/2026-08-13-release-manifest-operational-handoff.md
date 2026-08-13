# Release Manifest Operational Trust Handoff

## Current, verified repository state

- Schema-v1 canonical manifests, detached Ed25519 verification, digest binding,
  explicit key-ring lookup, and three rollback floors are implemented.
- `Config/release-manifest-keyring-v1.json` is intentionally empty. Therefore
  `scripts/verify-release-manifest.sh` fails closed for a production manifest.
- The protected `production` workflow requires a manifest signing secret and a
  key ID, verifies the generated assets, and uploads an **Actions artifact**.
  It does not create a GitHub Release or designate an end-user distribution
  channel.
- The workflow has not been remotely dispatched or accepted in this repository.

This file is a decision record template, not a source of trust. Do not fill an
unknown value with a placeholder and do not commit, paste, log, or attach an
Ed25519 private seed.

## Required decisions and exact inputs

An authorized release owner must provide every item below before production
manifest verification can be described as operational.

| Decision | Required input | Repository action after approval |
| --- | --- | --- |
| Release authority | Named individual or accountable group; deputy/approver; emergency contact | Record the approved owner and protect the release path accordingly. |
| Canonical public channel | One concrete channel and URL pattern. State whether GitHub Release assets are authoritative; Actions artifacts are candidate/QA only unless explicitly selected. | Align the documented publication and QA procedure. A GitHub Release choice requires a separately approved workflow publication change. |
| Active trust anchor | `keyID`, 32-byte Ed25519 public key in base64, and its initial minimum accepted build | Add only this public entry to the versioned keyring and verify it with a test artifact. |
| Private-key custody | Custodian(s), approved secret store/location, allowed writers/readers, dual-control or break-glass procedure | Provision only `RELEASE_MANIFEST_ED25519_PRIVATE_KEY_BASE64` to the protected `production` environment; never to the repository, logs, cache, artifacts, or command line. |
| Signing selector | Value of protected `RELEASE_MANIFEST_KEY_ID` variable, matching the active keyring entry exactly | Configure the protected environment and run a controlled candidate release. |
| Rollback authority | Named policy owner; current global floor; when and how it advances; signed/controlled location of the current floor | Supply the operator/QA `--minimum-build` value. The manifest itself cannot globally revoke already downloaded old policy. |
| Rotation and compromise | Rotation cadence; successor-key approval; compromise decision maker; revocation/advisory channel; maximum response time | Rotate by adding the successor public entry and raising/not lowering floors, move CI to it, then retire the old key. For compromise, stop the secret, retire/remove its public entry, publish the replacement keyring/advisory, and raise the floor only under the named policy. |
| QA release record | QA owner; tested commit; exact ZIP SHA-256; manifest/keyring revisions; macOS/device; pass/fail; approval record location | Verify the exact bytes before promotion; do not repackage between QA and the selected public channel. |

## Sign-off template

Copy this block into the organization’s approved change/approval system. The
values are deliberately blank: repository evidence cannot establish them.

```text
Release owner / accountable group:
Deputy and emergency contact:
Canonical public channel and URL pattern:
Actions artifact role (candidate/QA or authoritative by explicit exception):
Active key ID:
Public-key base64 (32-byte Ed25519 public key):
Initial minimum accepted build:
Private-key custodian and protected secret-store location:
Who may change the production secret / key-ID variable:
Break-glass approval and audit procedure:
Rollback-floor owner, value, update trigger, and controlled policy location:
Rotation cadence and next review date:
Compromise/revocation decision maker, advisory channel, and response target:
QA evidence record location and required approvers:
Approval reference and date:
```

## Controlled activation sequence

1. Obtain the completed sign-off above. Independently validate the public key
   length/base64 and ensure the new `keyID` is unique.
2. Commit the public keyring entry with `status: active` and the approved floor;
   review that diff as public trust-policy data only.
3. An authorized custodian provisions the private seed solely as
   `RELEASE_MANIFEST_ED25519_PRIVATE_KEY_BASE64` in the protected GitHub
   `production` environment, and sets `RELEASE_MANIFEST_KEY_ID` to the exact
   committed ID. The seed is never handled by repository tooling.
4. Dispatch a controlled production candidate through the protected workflow.
   The current workflow is a candidate artifact workflow, not public release
   publication.
5. On a clean QA Mac, use the committed keyring and an owner-supplied floor:

   ```text
   scripts/verify-release-manifest.sh --manifest <manifest-file> --signature <signature-file> --zip <zip-file> --minimum-build <approved-floor>
   /usr/bin/shasum -a 256 -c <checksum-file>
   ```

   Then complete the existing code-signing and microphone acceptance checks.
6. Preserve the QA record and promote the *same bytes* only through the
   approved canonical channel. If that channel is GitHub Release assets, first
   obtain explicit approval for the workflow change that creates the release.

## Invariants

- A manifest verifies only against the verifier’s pinned keyring revision and
  explicit minimum build. It cannot, by itself, withdraw old keyrings or set a
  fleet-wide rollback policy.
- A retired or absent key, schema mismatch, non-canonical manifest, digest
  mismatch, bad signature, or insufficient build must fail closed.
- This layer is additive to Apple signing. It does not alter Developer ID,
  Hardened Runtime, notarization, or the ad-hoc staging flow.
