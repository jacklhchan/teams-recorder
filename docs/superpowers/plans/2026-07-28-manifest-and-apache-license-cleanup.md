# Manifest and Apache License Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the abandoned BlackHole/oMLX/model installer manifest from active code and package the owner-approved Apache-2.0 license with accurate third-party notices.

**Architecture:** Delete the unused manifest type, JSON resource, and tests as one atomic change so SwiftPM and staging packaging cannot reference missing data. Add repository and bundle licensing separately, preserving the Apple sample license for the virtual microphone driver and clearly distinguishing external systems that are not distributed with the app.

**Tech Stack:** Swift Package Manager, Bash, Python 3 `unittest`, Apache License 2.0, Apple sample-code license.

## Global Constraints

- Complete the provider-neutral helper naming from
  `2026-07-28-openai-compatible-asr-provider.md` before updating README.
- Remove the active `ReleaseManifest` model entirely; do not replace it with a
  provider or model manifest.
- Remove BlackHole, oMLX, and model downloads from active release metadata.
- Keep native ScreenCaptureKit capture and the regression test proving
  BlackHole is unnecessary.
- Keep `scripts/install-app.sh`; it is a developer install command, not the
  abandoned self-service dependency installer.
- Retain historical installer documents but mark them superseded and unsafe to
  execute.
- Repository license is Apache-2.0.
- Apple-derived driver code remains subject to
  `Driver/LocalRecorderVirtualMic/LICENSE-Apple-Sample.txt`.
- Do not claim Apache-2.0 ownership over Apple sample code or external
  providers, models, FFmpeg, oMLX, or BlackHole.
- Package `LICENSE` and `THIRD_PARTY_NOTICES.md` inside the app.
- Package the Apple sample license inside the driver bundle.
- Do not touch the dirty main-checkout manifest drafts; make deletions only in
  the isolated branch.

---

## File Structure

- Delete `Sources/RecorderApp/Setup/ReleaseManifest.swift`.
- Delete `Sources/RecorderApp/Resources/release-manifest.json`.
- Delete `Tests/RecorderAppTests/ReleaseManifestTests.swift`.
- Modify `Package.swift` to remove the obsolete resource.
- Modify `scripts/build-app.sh` to remove manifest packaging and add licenses.
- Modify `scripts/build-virtual-mic.sh` to package the Apple sample license.
- Create `LICENSE`.
- Create `THIRD_PARTY_NOTICES.md`.
- Create `Tests/ScriptTests/test_packaging_contract.py`.
- Modify `README.md`.
- Modify the 2026-07-20 self-service installer spec and plan with superseded
  banners.

### Task 1: Remove the Abandoned Installer Manifest

**Files:**
- Create: `Tests/ScriptTests/test_packaging_contract.py`
- Delete: `Sources/RecorderApp/Setup/ReleaseManifest.swift`
- Delete: `Sources/RecorderApp/Resources/release-manifest.json`
- Delete: `Tests/RecorderAppTests/ReleaseManifestTests.swift`
- Modify: `Package.swift`
- Modify: `scripts/build-app.sh`
- Modify: `docs/superpowers/specs/2026-07-20-self-service-installer-design.md`
- Modify: `docs/superpowers/plans/2026-07-20-self-service-installer.md`

**Interfaces:**
- Removes: `ReleaseManifest`
- Removes: SwiftPM `Bundle.module` resource accessor generated solely for the
  manifest
- Produces: static packaging-policy tests

- [ ] **Step 1: Write a failing active-manifest policy test**

```python
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class PackagingContractTests(unittest.TestCase):
    def test_abandoned_release_manifest_is_absent(self):
        self.assertFalse(
            (
                ROOT
                / "Sources/RecorderApp/Setup/ReleaseManifest.swift"
            ).exists()
        )
        self.assertFalse(
            (
                ROOT
                / "Sources/RecorderApp/Resources/release-manifest.json"
            ).exists()
        )
        self.assertFalse(
            (
                ROOT
                / "Tests/RecorderAppTests/ReleaseManifestTests.swift"
            ).exists()
        )

        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        build = (
            ROOT / "scripts/build-app.sh"
        ).read_text(encoding="utf-8")
        self.assertNotIn("release-manifest", package)
        self.assertNotIn("release-manifest", build)
        self.assertNotIn("ReleaseManifest", package)

    def test_active_release_metadata_does_not_model_blackhole(self):
        active_paths = [
            ROOT / "Package.swift",
            ROOT / "Sources/RecorderApp/Setup",
            ROOT / "Sources/RecorderApp/Resources",
            ROOT / "scripts/build-app.sh",
        ]
        text = ""
        for path in active_paths:
            if path.is_file():
                text += path.read_text(encoding="utf-8")
            elif path.is_dir():
                for child in path.rglob("*"):
                    if child.is_file():
                        text += child.read_text(
                            encoding="utf-8",
                            errors="ignore",
                        )
        self.assertNotIn("BlackHole", text)
```

- [ ] **Step 2: Run the policy test to verify RED**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_abandoned_release_manifest_is_absent \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_active_release_metadata_does_not_model_blackhole \
  -v
```

Expected: failure because all three manifest artifacts and two references still
exist.

- [ ] **Step 3: Delete the manifest atomically**

Delete:

```text
Sources/RecorderApp/Setup/ReleaseManifest.swift
Sources/RecorderApp/Resources/release-manifest.json
Tests/RecorderAppTests/ReleaseManifestTests.swift
```

Change the executable target in `Package.swift` from:

```swift
.executableTarget(
    name: "RecorderApp",
    dependencies: ["VirtualMicBridge"],
    resources: [
        .process("Resources/release-manifest.json")
    ],
    linkerSettings: [
```

to:

```swift
.executableTarget(
    name: "RecorderApp",
    dependencies: ["VirtualMicBridge"],
    linkerSettings: [
```

Delete only this build-script line:

```bash
cp "$ROOT_DIR/Sources/RecorderApp/Resources/release-manifest.json" \
  "$RESOURCES_DIR/release-manifest.json"
```

- [ ] **Step 4: Mark historical installer documents as superseded**

Insert immediately after each document title:

```markdown
> **Superseded on 2026-07-28. Do not execute this plan.**
> Local Meeting Recorder now uses native ScreenCaptureKit capture and a
> user-configured OpenAI-compatible provider. The application does not install
> BlackHole, oMLX, provider binaries, or models.
```

Do not rewrite or delete the historical body.

- [ ] **Step 5: Run RED-to-GREEN gates**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_abandoned_release_manifest_is_absent \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_active_release_metadata_does_not_model_blackhole \
  -v
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingEngineStateTests.testStartDoesNotRequireBlackHoleDevice
```

Expected: all pass. `Package.swift` no longer generates a resource bundle for
the dead manifest.

- [ ] **Step 6: Commit Task 1**

```bash
git add -A \
  Package.swift \
  Sources/RecorderApp/Setup/ReleaseManifest.swift \
  Sources/RecorderApp/Resources/release-manifest.json \
  Tests/RecorderAppTests/ReleaseManifestTests.swift \
  Tests/ScriptTests/test_packaging_contract.py \
  scripts/build-app.sh \
  docs/superpowers/specs/2026-07-20-self-service-installer-design.md \
  docs/superpowers/plans/2026-07-20-self-service-installer.md
git commit -m "Remove abandoned installer manifest"
```

### Task 2: Add Apache-2.0 and Accurate Third-Party Notices

**Files:**
- Create: `LICENSE`
- Create: `THIRD_PARTY_NOTICES.md`
- Modify: `Tests/ScriptTests/test_packaging_contract.py`

**Interfaces:**
- Produces: repository license
- Produces: explicit notice boundary for bundled and external components

- [ ] **Step 1: Write failing license-content tests**

```python
def test_repository_declares_apache_2_0(self):
    license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
    self.assertTrue(
        license_text.startswith(
            "Apache License\nVersion 2.0, January 2004"
        )
    )
    self.assertIn(
        "http://www.apache.org/licenses/",
        license_text,
    )
    self.assertIn(
        "END OF TERMS AND CONDITIONS",
        license_text,
    )


def test_notices_preserve_apple_sample_license_boundary(self):
    notices = (
        ROOT / "THIRD_PARTY_NOTICES.md"
    ).read_text(encoding="utf-8")
    self.assertIn("Apple Audio Server Driver Plug-in sample", notices)
    self.assertIn("LICENSE-Apple-Sample.txt", notices)
    self.assertIn("not bundled", notices)
    self.assertIn("FFmpeg", notices)
    self.assertIn("OpenAI-compatible", notices)
```

- [ ] **Step 2: Run the license tests to verify RED**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_repository_declares_apache_2_0 \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_notices_preserve_apple_sample_license_boundary \
  -v
```

Expected: file-not-found failures.

- [ ] **Step 3: Add the complete Apache License 2.0**

Create `LICENSE` with this exact canonical text:

```text
Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

"License" shall mean the terms and conditions for use, reproduction,
and distribution as defined by Sections 1 through 9 of this document.

"Licensor" shall mean the copyright owner or entity authorized by
the copyright owner that is granting the License.

"Legal Entity" shall mean the union of the acting entity and all
other entities that control, are controlled by, or are under common
control with that entity. For the purposes of this definition,
"control" means (i) the power, direct or indirect, to cause the
direction or management of such entity, whether by contract or
otherwise, or (ii) ownership of fifty percent (50%) or more of the
outstanding shares, or (iii) beneficial ownership of such entity.

"You" (or "Your") shall mean an individual or Legal Entity
exercising permissions granted by this License.

"Source" form shall mean the preferred form for making modifications,
including but not limited to software source code, documentation
source, and configuration files.

"Object" form shall mean any form resulting from mechanical
transformation or translation of a Source form, including but
not limited to compiled object code, generated documentation,
and conversions to other media types.

"Work" shall mean the work of authorship, whether in Source or
Object form, made available under the License, as indicated by a
copyright notice that is included in or attached to the work
(an example is provided in the Appendix below).

"Derivative Works" shall mean any work, whether in Source or Object
form, that is based on (or derived from) the Work and for which the
editorial revisions, annotations, elaborations, or other modifications
represent, as a whole, an original work of authorship. For the purposes
of this License, Derivative Works shall not include works that remain
separable from, or merely link (or bind by name) to the interfaces of,
the Work and Derivative Works thereof.

"Contribution" shall mean any work of authorship, including
the original version of the Work and any modifications or additions
to that Work or Derivative Works thereof, that is intentionally
submitted to Licensor for inclusion in the Work by the copyright owner
or by an individual or Legal Entity authorized to submit on behalf of
the copyright owner. For the purposes of this definition, "submitted"
means any form of electronic, verbal, or written communication sent
to the Licensor or its representatives, including but not limited to
communication on electronic mailing lists, source code control systems,
and issue tracking systems that are managed by, or on behalf of, the
Licensor for the purpose of discussing and improving the Work, but
excluding communication that is conspicuously marked or otherwise
designated in writing by the copyright owner as "Not a Contribution."

"Contributor" shall mean Licensor and any individual or Legal Entity
on behalf of whom a Contribution has been received by Licensor and
subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of
this License, each Contributor hereby grants to You a perpetual,
worldwide, non-exclusive, no-charge, royalty-free, irrevocable
copyright license to reproduce, prepare Derivative Works of,
publicly display, publicly perform, sublicense, and distribute the
Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of
this License, each Contributor hereby grants to You a perpetual,
worldwide, non-exclusive, no-charge, royalty-free, irrevocable
(except as stated in this section) patent license to make, have made,
use, offer to sell, sell, import, and otherwise transfer the Work,
where such license applies only to those patent claims licensable
by such Contributor that are necessarily infringed by their
Contribution(s) alone or by combination of their Contribution(s)
with the Work to which such Contribution(s) was submitted. If You
institute patent litigation against any entity (including a
cross-claim or counterclaim in a lawsuit) alleging that the Work
or a Contribution incorporated within the Work constitutes direct
or contributory patent infringement, then any patent licenses
granted to You under this License for that Work shall terminate
as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the
Work or Derivative Works thereof in any medium, with or without
modifications, and in Source or Object form, provided that You
meet the following conditions:

(a) You must give any other recipients of the Work or
Derivative Works a copy of this License; and

(b) You must cause any modified files to carry prominent notices
stating that You changed the files; and

(c) You must retain, in the Source form of any Derivative Works
that You distribute, all copyright, patent, trademark, and
attribution notices from the Source form of the Work,
excluding those notices that do not pertain to any part of
the Derivative Works; and

(d) If the Work includes a "NOTICE" text file as part of its
distribution, then any Derivative Works that You distribute must
include a readable copy of the attribution notices contained
within such NOTICE file, excluding those notices that do not
pertain to any part of the Derivative Works, in at least one
of the following places: within a NOTICE text file distributed
as part of the Derivative Works; within the Source form or
documentation, if provided along with the Derivative Works; or,
within a display generated by the Derivative Works, if and
wherever such third-party notices normally appear. The contents
of the NOTICE file are for informational purposes only and
do not modify the License. You may add Your own attribution
notices within Derivative Works that You distribute, alongside
or as an addendum to the NOTICE text from the Work, provided
that such additional attribution notices cannot be construed
as modifying the License.

You may add Your own copyright statement to Your modifications and
may provide additional or different license terms and conditions
for use, reproduction, or distribution of Your modifications, or
for any such Derivative Works as a whole, provided Your use,
reproduction, and distribution of the Work otherwise complies with
the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise,
any Contribution intentionally submitted for inclusion in the Work
by You to the Licensor shall be under the terms and conditions of
this License, without any additional terms or conditions.
Notwithstanding the above, nothing herein shall supersede or modify
the terms of any separate license agreement you may have executed
with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade
names, trademarks, service marks, or product names of the Licensor,
except as required for reasonable and customary use in describing the
origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or
agreed to in writing, Licensor provides the Work (and each
Contributor provides its Contributions) on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied, including, without limitation, any warranties or conditions
of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
PARTICULAR PURPOSE. You are solely responsible for determining the
appropriateness of using or redistributing the Work and assume any
risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory,
whether in tort (including negligence), contract, or otherwise,
unless required by applicable law (such as deliberate and grossly
negligent acts) or agreed to in writing, shall any Contributor be
liable to You for damages, including any direct, indirect, special,
incidental, or consequential damages of any character arising as a
result of this License or out of the use or inability to use the
Work (including but not limited to damages for loss of goodwill,
work stoppage, computer failure or malfunction, or any and all
other commercial damages or losses), even if such Contributor
has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing
the Work or Derivative Works thereof, You may choose to offer,
and charge a fee for, acceptance of support, warranty, indemnity,
or other liability obligations and/or rights consistent with this
License. However, in accepting such obligations, You may act only
on Your own behalf and on Your sole responsibility, not on behalf
of any other Contributor, and only if You agree to indemnify,
defend, and hold each Contributor harmless for any liability
incurred by, or claims asserted against, such Contributor by reason
of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

APPENDIX: How to apply the Apache License to your work.

To apply the Apache License to your work, attach the following
boilerplate notice, with the fields enclosed by brackets "[]"
replaced with your own identifying information. (Don't include
the brackets!) The text should be enclosed in the appropriate
comment syntax for the file format. We also recommend that a
file or class name and description of purpose be included on the
same "printed page" as the copyright notice for easier
identification within third-party archives.

Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

- [ ] **Step 4: Add exact third-party notices**

Create:

```markdown
# Third-Party Notices

Local Meeting Recorder is licensed under the Apache License, Version 2.0,
except for the separately identified material below.

## Apple Audio Server Driver Plug-in Sample

`Driver/LocalRecorderVirtualMic/LocalRecorderVirtualMic.c` is derived from
Apple's "Creating an Audio Server Driver Plug-in" sample.

Copyright (c) 2024 Apple Inc.

The applicable permission notice is distributed in:

`Driver/LocalRecorderVirtualMic/LICENSE-Apple-Sample.txt`

That notice, rather than Apache-2.0, governs the Apple-derived sample material.

## External Runtime Systems

The following systems may be selected or installed separately by a user but
are not bundled or redistributed with Local Meeting Recorder:

- OpenAI-compatible API providers and their server software
- User-selected ASR and LLM models
- FFmpeg and FFprobe
- oMLX
- BlackHole

Each external system and model remains subject to its own license and terms.
Mentioning compatibility does not change or grant those licenses.
```

- [ ] **Step 5: Run license tests and commit Task 2**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_repository_declares_apache_2_0 \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_notices_preserve_apple_sample_license_boundary \
  -v
git add \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  Tests/ScriptTests/test_packaging_contract.py
git commit -m "Add Apache and third-party license notices"
```

Expected: both license tests pass.

### Task 3: Package License Resources

**Files:**
- Modify: `scripts/build-app.sh`
- Modify: `scripts/build-virtual-mic.sh`
- Modify: `Tests/ScriptTests/test_packaging_contract.py`

**Interfaces:**
- Produces: app-bundle `LICENSE` and `THIRD_PARTY_NOTICES.md`
- Produces: driver-bundle `LICENSE-Apple-Sample.txt`

- [ ] **Step 1: Write failing script-contract tests**

```python
def test_app_build_packages_license_and_notices(self):
    script = (
        ROOT / "scripts/build-app.sh"
    ).read_text(encoding="utf-8")
    self.assertIn(
        'cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"',
        script,
    )
    self.assertIn(
        'cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" '
        '"$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"',
        script,
    )


def test_driver_build_packages_apple_sample_license(self):
    script = (
        ROOT / "scripts/build-virtual-mic.sh"
    ).read_text(encoding="utf-8")
    self.assertIn(
        'cp "$DRIVER_DIR/LICENSE-Apple-Sample.txt" '
        '"$CONTENTS/Resources/LICENSE-Apple-Sample.txt"',
        script,
    )
```

- [ ] **Step 2: Run the contract tests to verify RED**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_app_build_packages_license_and_notices \
  Tests.ScriptTests.test_packaging_contract.PackagingContractTests.test_driver_build_packages_apple_sample_license \
  -v
```

Expected: failures because neither script copies licenses.

- [ ] **Step 3: Add app license packaging**

After creating the app resources directory, add:

```bash
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" \
  "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
```

- [ ] **Step 4: Add driver license packaging**

Change driver directory creation to:

```bash
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
mkdir -p "$OBJECT_DIR"
```

After copying `Info.plist`, add:

```bash
cp "$DRIVER_DIR/LICENSE-Apple-Sample.txt" \
  "$CONTENTS/Resources/LICENSE-Apple-Sample.txt"
```

- [ ] **Step 5: Run script and real-bundle checks**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract -v
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/build-app.sh
test -f \
  "build/Local Meeting Recorder Staging.app/Contents/Resources/LICENSE"
test -f \
  "build/Local Meeting Recorder Staging.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
test ! -e \
  "build/Local Meeting Recorder Staging.app/Contents/Resources/release-manifest.json"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/build-virtual-mic.sh
test -f \
  "build/LocalRecorderVirtualMic.driver/Contents/Resources/LICENSE-Apple-Sample.txt"
```

Expected: all checks pass. These commands build only; they do not install or
reload the driver.

- [ ] **Step 6: Commit Task 3**

```bash
git add \
  scripts/build-app.sh \
  scripts/build-virtual-mic.sh \
  Tests/ScriptTests/test_packaging_contract.py
git commit -m "Package application and driver licenses"
```

### Task 4: Update Product Documentation

**Files:**
- Modify: `README.md`
- Modify: `Tests/ScriptTests/test_packaging_contract.py`

**Interfaces:**
- Documents: native capture, OpenAI-compatible provider setup, Keychain, legacy
  migration, canonical outputs, staging build, licensing

- [ ] **Step 1: Write failing README policy tests**

```python
def test_readme_describes_current_provider_and_license(self):
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    self.assertIn("OpenAI-Compatible Transcription", readme)
    self.assertIn("API Base URL", readme)
    self.assertIn("ASR Model", readme)
    self.assertIn("LLM Model", readme)
    self.assertIn("macOS Keychain", readme)
    self.assertIn("transcript.txt", readme)
    self.assertIn("Apache License 2.0", readme)
    self.assertNotIn(
        "The transcript button opens oMLX",
        readme,
    )
    self.assertNotIn(
        "Keychain migration is intentionally deferred",
        readme,
    )
```

- [ ] **Step 2: Replace stale ASR documentation**

Replace `## Qwen ASR Transcription` with:

```markdown
## OpenAI-Compatible Transcription

Configure an OpenAI-compatible provider in the app:

1. Enter the API Base URL ending in `/v1`.
2. Enter the ASR Model identifier accepted by that provider.
3. Enter the LLM Model identifier to reserve for future meeting intelligence.
4. Enter an optional API key, language, and transcription prompt.
5. Save, then use Test to check connectivity. Model discovery is optional;
   manually entered model identifiers remain available when `/v1/models` is
   unsupported.

The app sends post-call audio chunks to:

```text
POST <API Base URL>/audio/transcriptions
```

Long recordings use silence-aware bounded chunks, rolling context, validation,
and retry. New output files are:

```text
transcript.txt
transcript.raw.txt
transcription.json
transcription.log
```

The optional provider API key and Teams pairing token are stored in macOS
Keychain. Existing local oMLX settings are read only for a one-time migration;
oMLX is not required, launched, installed, or managed by the recorder.
```

Correct the `Run` artifact path to:

```text
build/Local Meeting Recorder Staging.app
```

Remove hard-coded developer paths, Qwen bit-depth claims, direct
`mlx_audio.stt.generate` claims, and the deferred-Keychain limitation.

- [ ] **Step 3: Add licensing section**

```markdown
## License

Local Meeting Recorder is available under the Apache License 2.0. See
`LICENSE` and `THIRD_PARTY_NOTICES.md`.

The Apple-derived virtual microphone sample material retains the separate
license in `Driver/LocalRecorderVirtualMic/LICENSE-Apple-Sample.txt`.
```

- [ ] **Step 4: Run documentation and full script tests**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract -v
/usr/bin/python3 -m unittest discover \
  -s Tests/ScriptTests -p 'test_*.py' -v
```

Expected: zero failures.

- [ ] **Step 5: Commit Task 4**

```bash
git add README.md Tests/ScriptTests/test_packaging_contract.py
git commit -m "Document provider-neutral transcription and licensing"
```

### Task 5: Cleanup Verification and Main-Checkout Guard

**Files:**
- Verify only.

**Interfaces:**
- Verifies: no active manifest, accurate bundle resources, full test suite
- Protects: dirty main-checkout drafts from silent loss

- [ ] **Step 1: Run active-source scans**

```bash
rg -n 'ReleaseManifest|release-manifest' \
  Package.swift Sources scripts/build-app.sh
```

Expected: no matches in active production/build inputs.

```bash
rg -n 'BlackHole' \
  Sources/RecorderApp/Setup \
  Package.swift \
  scripts/build-app.sh
```

Expected: no matches.

- [ ] **Step 2: Run complete test suites**

```bash
/usr/bin/python3 -m unittest discover \
  -s Tests/ScriptTests -p 'test_*.py' -v
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: zero failures and only the existing intentional Swift skip.

- [ ] **Step 3: Verify signed staging bundles**

```bash
codesign --verify --deep --strict \
  "build/Local Meeting Recorder Staging.app"
codesign --verify --deep --strict \
  build/LocalRecorderVirtualMic.driver
```

Expected: both ad-hoc staging artifacts verify.

- [ ] **Step 4: Confirm the main checkout was not modified**

```bash
git -C /Users/apple/Documents/recorder status --short --branch
```

Expected before final integration:

```text
## main...origin/main
 M Sources/RecorderApp/Setup/ReleaseManifest.swift
 M Tests/RecorderAppTests/ReleaseManifestTests.swift
?? .superpowers/
```

Do not merge this branch into that dirty checkout until those drafts have been
preserved on a separate archival branch or the owner explicitly authorizes
their removal. The isolated implementation branch may delete the committed
manifest baseline because the approved product design supersedes it.
