# macOS Release and CI Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current fixed debug/ad-hoc staging script into repeatable,
parameterized staging packaging, add a fail-closed Developer ID/notarization
release command, and enforce the project gates in GitHub Actions.

**Architecture:** Keep one parameterized `build-app.sh` as the unsigned/ad-hoc
bundle assembler for both staging and release. A separate `build-release.sh`
performs identity preflight, calls the shared assembler with production
metadata, signs inside-out with hardened runtime and the microphone
entitlement, optionally notarizes and staples, and creates the final ZIP and
verified SHA-256 only after all gates pass.

**Tech Stack:** Swift Package Manager, Bash, Python 3 `unittest`, codesign, security, spctl, ditto, shasum, xcrun notarytool, GitHub Actions.

## Global Constraints

- Complete the provider-helper rename and license packaging plans first.
- Minimum deployment target is macOS 26.
- Production bundle identifier is `local.meeting.recorder`.
- Staging defaults remain `local.meeting.recorder.staging` and
  `Local Meeting Recorder Staging`.
- Staging may use only `ad-hoc` or `none` signing.
- Production requires an exact Developer ID Application identity.
- Production signing uses hardened runtime and secure timestamp.
- Hardened-runtime signatures carry
  `com.apple.security.device.audio-input = true`; screen capture remains a TCC
  permission rather than an entitlement.
- Sign individual Mach-O code before the outer app; do not use
  `codesign --deep` as a signing strategy.
- `codesign --deep --strict` is a verification gate.
- A notarized build must pass `stapler validate` and `spctl --assess`.
- A `--signed-only` artifact is named and reported as a release candidate, not
  a production release.
- Missing identity, missing notary mode, invalid metadata, signing failure, or
  notarization failure must stop before final publication.
- `--dry-run` performs no build, signature, file deletion, or network call.
- No certificate, password, API key, or notary credential may appear in logs
  or command output.
- "Repeatable packaging" means validated inputs, stable resource inventory,
  and stable metadata fields. It does not claim byte-identical bundles or ZIPs:
  file metadata, secure signing timestamps, and notarization tickets vary.
- CI does not install or launch the app, virtual microphone, Teams, or any
  provider.
- The current machine has no valid Developer ID identity; local verification
  proves dry-run and missing-credential failure paths only.
- Do not modify or replace the installed application.

---

## File Structure

- Rewrite `scripts/build-app.sh`
  - Parameter parsing, deterministic Swift binary lookup, metadata, resources,
    and optional staging signature.
- Create `scripts/verify-app-bundle.sh`
  - Reusable bundle structure, metadata, architecture, helper, license, and
    signature checks.
- Create `Config/LocalMeetingRecorder.entitlements`
  - Hardened-runtime microphone entitlement shared by staging verification and
    production signing.
- Create `Tests/PackagingTests/run-tests.sh`
  - Build and moved-bundle smoke checks.
- Create `Tests/ScriptTests/test_build_app_contract.py`
  - Argument and static policy tests.
- Create `scripts/build-release.sh`
  - Developer ID, hardened runtime, notary, staple, ZIP, and checksum gates.
- Create `scripts/atomic-publish-directory.py`
  - Darwin `renameatx_np(RENAME_EXCL)` publication without replacement races.
- Create `Tests/ScriptTests/test_build_release_contract.py`
  - Dry-run and fail-closed tests that require no signing identity.
- Create `.github/workflows/ci.yml`
  - Swift, Python, packaging, driver, and policy gates.
- Create `.github/workflows/release.yml`
  - Protected manual production release.
- Modify `README.md`
  - Exact staging, validation, and release commands.

### Task 1: Parameterized Repeatable Staging Builder

**Files:**
- Modify: `scripts/build-app.sh`
- Create: `scripts/verify-app-bundle.sh`
- Create: `Config/LocalMeetingRecorder.entitlements`
- Create: `Tests/ScriptTests/test_build_app_contract.py`

**Interfaces:**
- Produces:
  `build-app.sh [--configuration debug|release] [--version X.Y.Z] [--build-number N] [--bundle-id ID] [--bundle-name NAME] [--output PATH] [--sign ad-hoc|none]`
- Produces: one app path on stdout
- Produces: progress and errors on stderr

- [ ] **Step 1: Write failing argument-contract tests**

```python
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD_APP = ROOT / "scripts/build-app.sh"


class BuildAppContractTests(unittest.TestCase):
    def run_build(self, *arguments):
        return subprocess.run(
            ["/bin/bash", str(BUILD_APP), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": str(Path.home()),
                "DEVELOPER_DIR":
                    "/Applications/Xcode.app/Contents/Developer",
            },
        )

    def test_rejects_invalid_configuration_before_build(self):
        result = self.run_build(
            "--configuration", "profile",
            "--sign", "none",
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("debug or release", result.stderr)

    def test_rejects_invalid_version_and_build_number(self):
        self.assertEqual(
            self.run_build("--version", "latest").returncode,
            64,
        )
        self.assertEqual(
            self.run_build("--build-number", "0").returncode,
            64,
        )

    def test_rejects_production_signing_mode(self):
        result = self.run_build("--sign", "Developer ID")
        self.assertEqual(result.returncode, 64)
        self.assertIn("ad-hoc or none", result.stderr)

    def test_script_uses_show_bin_path_not_hard_coded_build_path(self):
        script = BUILD_APP.read_text(encoding="utf-8")
        self.assertIn("--show-bin-path", script)
        self.assertNotIn(
            ".build/arm64-apple-macosx/debug",
            script,
        )

    def test_rejects_unowned_existing_output_before_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "Existing.app"
            output.mkdir()
            result = self.run_build(
                "--output", str(output),
                "--sign", "none",
            )
            self.assertEqual(result.returncode, 73)
            self.assertTrue(output.is_dir())

    def test_rejects_symlink_output_and_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.mkdir()
            output_link = root / "Linked.app"
            output_link.symlink_to(target)
            self.assertEqual(
                self.run_build(
                    "--output", str(output_link),
                    "--sign", "none",
                ).returncode,
                73,
            )

            parent_link = root / "linked-parent"
            parent_link.symlink_to(target)
            self.assertEqual(
                self.run_build(
                    "--output",
                    str(parent_link / "Output.app"),
                    "--sign", "none",
                ).returncode,
                73,
            )

    def test_microphone_entitlement_and_verifier_are_present(self):
        with (
            ROOT / "Config/LocalMeetingRecorder.entitlements"
        ).open("rb") as stream:
            entitlements = plistlib.load(stream)
        self.assertIs(
            entitlements["com.apple.security.device.audio-input"],
            True,
        )
        verifier = ROOT / "scripts/verify-app-bundle.sh"
        self.assertTrue(os.access(verifier, os.X_OK))
```

- [ ] **Step 2: Run contract tests to verify RED**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_build_app_contract -v
```

Expected: failures because the current script ignores arguments and hard-codes
the debug binary path.

- [ ] **Step 3: Implement strict parsing, entitlement, and output ownership**

Start `build-app.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_EXECUTABLE="LocalMeetingRecorder"
CONFIGURATION="debug"
VERSION="0.1.0"
BUILD_NUMBER="1"
BUNDLE_ID="local.meeting.recorder.staging"
BUNDLE_NAME="Local Meeting Recorder Staging"
OUTPUT="$ROOT_DIR/build/Local Meeting Recorder Staging.app"
SIGN_MODE="ad-hoc"

usage() {
  cat >&2 <<'USAGE'
Usage: build-app.sh [options]
  --configuration debug|release
  --version X.Y.Z
  --build-number N
  --bundle-id IDENTIFIER
  --bundle-name NAME
  --output PATH
  --sign ad-hoc|none
USAGE
}

die_usage() {
  echo "$1" >&2
  usage
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) [[ $# -ge 2 ]] || die_usage "Missing configuration"; CONFIGURATION="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die_usage "Missing version"; VERSION="$2"; shift 2 ;;
    --build-number) [[ $# -ge 2 ]] || die_usage "Missing build number"; BUILD_NUMBER="$2"; shift 2 ;;
    --bundle-id) [[ $# -ge 2 ]] || die_usage "Missing bundle identifier"; BUNDLE_ID="$2"; shift 2 ;;
    --bundle-name) [[ $# -ge 2 ]] || die_usage "Missing bundle name"; BUNDLE_NAME="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || die_usage "Missing output path"; OUTPUT="$2"; shift 2 ;;
    --sign) [[ $# -ge 2 ]] || die_usage "Missing sign mode"; SIGN_MODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "Unknown option: $1" ;;
  esac
done

[[ "$CONFIGURATION" == "debug" || "$CONFIGURATION" == "release" ]] \
  || die_usage "Configuration must be debug or release."
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
  || die_usage "Version must contain two or three numeric components."
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || die_usage "Build number must be a positive integer."
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] \
  || die_usage "Bundle identifier is invalid."
[[ -n "$BUNDLE_NAME" ]] || die_usage "Bundle name cannot be empty."
[[ "$SIGN_MODE" == "ad-hoc" || "$SIGN_MODE" == "none" ]] \
  || die_usage "Sign mode must be ad-hoc or none."
[[ "$OUTPUT" == *.app ]] \
  || die_usage "Output path must end in .app."
[[ "$(basename "$OUTPUT")" != ".app" ]] \
  || die_usage "Output app name cannot be empty."
[[ "$OUTPUT" != "/" ]] \
  || die_usage "Output path cannot be the filesystem root."
```

Normalize the output path and reject every existing symbolic-link component
before any build or directory creation:

```bash
OUTPUT="$(
  /usr/bin/python3 - "$OUTPUT" <<'PY'
import os
import sys
from pathlib import Path


candidate = Path(
    os.path.abspath(os.path.expanduser(sys.argv[1]))
)
for component in (candidate, *candidate.parents):
    if component.is_symlink():
        print(
            "Output path cannot contain symbolic links.",
            file=sys.stderr,
        )
        raise SystemExit(73)
print(candidate)
PY
)"

OWNER_MARKER_NAME=".lmr-build-owner"
OWNER_MARKER_VALUE="local.meeting.recorder.build-app.v1"
if [[ -e "$OUTPUT" ]]; then
  MARKER="$OUTPUT/Contents/Resources/$OWNER_MARKER_NAME"
  if [[ ! -d "$OUTPUT" || ! -f "$MARKER" \
        || "$(<"$MARKER")" != "$OWNER_MARKER_VALUE" ]]; then
    echo "Refusing to replace an output not owned by build-app.sh." >&2
    exit 73
  fi
fi
```

Create `Config/LocalMeetingRecorder.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
```

This is the hardened-runtime Audio Input entitlement required for microphone
capture. It adds no App Sandbox or Keychain access group.

- [ ] **Step 4: Build and locate the exact binary**

Use:

```bash
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT_DIR"
echo "Building $CONFIGURATION app binary" >&2
swift build -c "$CONFIGURATION" --arch arm64
BIN_DIR="$(
  swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path
)"
BINARY_PATH="$BIN_DIR/$APP_EXECUTABLE"
[[ -x "$BINARY_PATH" ]] || {
  echo "Built executable not found: $BINARY_PATH" >&2
  exit 70
}
```

Do not infer SwiftPM internal directory names.

- [ ] **Step 5: Assemble metadata and resources**

Create `Contents/MacOS` and `Contents/Resources`, then copy:

```text
LocalMeetingRecorder
AppIcon.icns
transcribe-openai-compatible.sh
transcribe-qwen-asr.sh
openai_asr_longform.py
LICENSE
THIRD_PARTY_NOTICES.md
```

Use a fresh temporary directory under the verified, non-symlinked output
parent:

```bash
mkdir -p "$(dirname "$OUTPUT")"
TEMP_ROOT="$(
  mktemp -d "$(dirname "$OUTPUT")/.lmr-build.XXXXXX"
)"
TEMP_OUTPUT="$TEMP_ROOT/$(basename "$OUTPUT")"
PREVIOUS_OUTPUT=""
cleanup() {
  if [[ -n "$PREVIOUS_OUTPUT" \
        && -e "$PREVIOUS_OUTPUT" \
        && ! -e "$OUTPUT" ]]; then
    mv "$PREVIOUS_OUTPUT" "$OUTPUT"
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT
mkdir -p \
  "$TEMP_OUTPUT/Contents/MacOS" \
  "$TEMP_OUTPUT/Contents/Resources"
printf '%s' "$OWNER_MARKER_VALUE" \
  > "$TEMP_OUTPUT/Contents/Resources/$OWNER_MARKER_NAME"
```

Generate `Info.plist` through Python's structured `plistlib` API, passing
parsed values as positional arguments:

```bash
PLIST="$TEMP_OUTPUT/Contents/Info.plist"
/usr/bin/python3 - \
  "$PLIST" "$BUNDLE_ID" "$BUNDLE_NAME" \
  "$VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib
import sys
from pathlib import Path


path, bundle_id, bundle_name, version, build = sys.argv[1:]
document = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "LocalMeetingRecorder",
    "CFBundleIdentifier": bundle_id,
    "CFBundleIconFile": "AppIcon",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": bundle_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "LSMinimumSystemVersion": "26.0",
    "NSHighResolutionCapable": True,
    "NSMicrophoneUsageDescription":
        "Local Meeting Recorder needs microphone access to "
        "record your selected mic input.",
    "NSDownloadsFolderUsageDescription":
        "Local Meeting Recorder reads and saves recordings "
        "in your Downloads folder.",
    "NSScreenCaptureUsageDescription":
        "Local Meeting Recorder captures system or selected "
        "app audio without changing your Mac output.",
}
with Path(path).open("wb") as stream:
    plistlib.dump(document, stream, sort_keys=True)
PY
plutil -lint "$PLIST"
```

- [ ] **Step 6: Sign only in the selected staging mode**

For ad-hoc:

```bash
ENTITLEMENTS="$ROOT_DIR/Config/LocalMeetingRecorder.entitlements"
codesign --force --sign - --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  "$TEMP_OUTPUT/Contents/MacOS/$APP_EXECUTABLE"
codesign --force --sign - --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  "$TEMP_OUTPUT"
codesign --verify --deep --strict "$TEMP_OUTPUT"
```

For `none`, assert the outer bundle is unsigned:

```bash
if codesign -dv "$TEMP_OUTPUT" >/dev/null 2>&1; then
  echo "Unsigned staging bundle unexpectedly has a signature." >&2
  exit 70
fi
```

Only after all checks:

```bash
if [[ -e "$OUTPUT" ]]; then
  PREVIOUS_OUTPUT="${OUTPUT}.previous-$$"
  [[ ! -e "$PREVIOUS_OUTPUT" \
      && ! -L "$PREVIOUS_OUTPUT" ]] || {
    echo "Temporary backup path already exists." >&2
    exit 73
  }
  mv "$OUTPUT" "$PREVIOUS_OUTPUT"
fi
mv "$TEMP_OUTPUT" "$OUTPUT"
if [[ -n "$PREVIOUS_OUTPUT" ]]; then
  rm -rf "$PREVIOUS_OUTPUT"
  PREVIOUS_OUTPUT=""
fi
printf '%s\n' "$OUTPUT"
```

The trap removes only the `mktemp` directory and restores the marker-verified
prior output if publication fails.

- [ ] **Step 7: Implement reusable bundle verification**

`scripts/verify-app-bundle.sh` accepts:

```text
verify-app-bundle.sh APP_PATH EXPECTED_BUNDLE_ID EXPECTED_VERSION EXPECTED_BUILD SIGN_MODE
```

It must run:

```bash
plutil -lint "$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "$EXPECTED_ID"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$EXPECTED_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$EXPECTED_BUILD"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = "26.0"
file "$APP/Contents/MacOS/LocalMeetingRecorder" | grep -q 'arm64'
test -x "$APP/Contents/Resources/transcribe-openai-compatible.sh"
test -x "$APP/Contents/Resources/openai_asr_longform.py"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test ! -e "$APP/Contents/Resources/release-manifest.json"
test "$(<"$APP/Contents/Resources/.lmr-build-owner")" \
  = "local.meeting.recorder.build-app.v1"
```

For `ad-hoc`, run `codesign --verify --deep --strict`, dump effective
entitlements, and require Audio Input:

```bash
ENTITLEMENT_DUMP="$(mktemp "${TMPDIR:-/tmp}/lmr-entitlements.XXXXXX")"
trap 'rm -f "$ENTITLEMENT_DUMP"' EXIT
codesign -d --entitlements :- "$APP" \
  > "$ENTITLEMENT_DUMP" 2>/dev/null
test "$(
  plutil -extract com.apple.security.device.audio-input \
    raw -o - "$ENTITLEMENT_DUMP"
)" = "true"
```

For `none`, require `codesign -dv` to fail.

- [ ] **Step 8: Run focused tests and staging smoke build**

```bash
chmod +x scripts/verify-app-bundle.sh
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_build_app_contract -v
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/build-app.sh \
  --configuration release \
  --version 0.2.0 \
  --build-number 2 \
  --bundle-id local.meeting.recorder.staging \
  --bundle-name "Local Meeting Recorder Staging" \
  --output "$PWD/build/Local Meeting Recorder Staging.app" \
  --sign ad-hoc
./scripts/verify-app-bundle.sh \
  "$PWD/build/Local Meeting Recorder Staging.app" \
  local.meeting.recorder.staging \
  0.2.0 \
  2 \
  ad-hoc
```

Expected: all pass.

- [ ] **Step 9: Commit Task 1**

```bash
git add \
  Config/LocalMeetingRecorder.entitlements \
  scripts/build-app.sh \
  scripts/verify-app-bundle.sh \
  Tests/ScriptTests/test_build_app_contract.py
git commit -m "Make staging app packaging repeatable"
```

### Task 2: Moved-Bundle Packaging Smoke Tests

**Files:**
- Create: `Tests/PackagingTests/run-tests.sh`
- Modify: `Tests/ScriptTests/test_build_app_contract.py`

**Interfaces:**
- Verifies: app works structurally outside the checkout
- Verifies: no hard-coded developer path or provider-specific production copy

- [ ] **Step 1: Create the packaging smoke test**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lmr-package.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

APP="$ROOT_DIR/build/Local Meeting Recorder Packaging Test.app"
MOVED="$TEMP_ROOT/Local Meeting Recorder.app"

"$ROOT_DIR/scripts/build-app.sh" \
  --configuration release \
  --version 0.2.0 \
  --build-number 2 \
  --bundle-id local.meeting.recorder.staging \
  --bundle-name "Local Meeting Recorder Packaging Test" \
  --output "$APP" \
  --sign ad-hoc >/dev/null

cp -R "$APP" "$MOVED"

"$ROOT_DIR/scripts/verify-app-bundle.sh" \
  "$MOVED" \
  local.meeting.recorder.staging \
  0.2.0 \
  2 \
  ad-hoc

/bin/bash -n "$MOVED/Contents/Resources/transcribe-openai-compatible.sh"
/usr/bin/python3 -m py_compile \
  "$MOVED/Contents/Resources/openai_asr_longform.py"

if LC_ALL=C /usr/bin/grep -R -n -E \
  '/Users/apple|open -a "oMLX"|OMLX_API_KEY|release-manifest.json' \
  "$MOVED/Contents"; then
  echo "Forbidden checkout/provider string found in bundle." >&2
  exit 1
fi

otool -L "$MOVED/Contents/MacOS/LocalMeetingRecorder" \
  | tail -n +2 \
  | awk '{print $1}' \
  | while IFS= read -r dependency; do
      case "$dependency" in
        /System/Library/*|/usr/lib/*|@rpath/libswift*) ;;
        *) echo "Unexpected dependency: $dependency" >&2; exit 1 ;;
      esac
    done
```

The test never opens the app.

- [ ] **Step 2: Add a static CI invocation assertion**

```python
def test_packaging_smoke_script_is_executable_contract(self):
    script = (
        ROOT / "Tests/PackagingTests/run-tests.sh"
    ).read_text(encoding="utf-8")
    self.assertIn("verify-app-bundle.sh", script)
    self.assertIn("moved", script.lower())
    self.assertNotIn("open -n", script)
```

- [ ] **Step 3: Run the smoke test**

```bash
chmod +x Tests/PackagingTests/run-tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./Tests/PackagingTests/run-tests.sh
```

Expected: zero output on success other than underlying build progress on
stderr.

- [ ] **Step 4: Commit Task 2**

```bash
git add \
  Tests/PackagingTests/run-tests.sh \
  Tests/ScriptTests/test_build_app_contract.py
git commit -m "Add moved-bundle packaging smoke tests"
```

### Task 3: Fail-Closed Developer ID Release Builder

**Files:**
- Create: `scripts/build-release.sh`
- Create: `scripts/write-sha256.sh`
- Create: `scripts/atomic-publish-directory.py`
- Create: `Tests/ScriptTests/test_build_release_contract.py`

**Interfaces:**
- Produces:
  `build-release.sh --version X.Y.Z --build-number N --signing-identity ID (--notary-profile PROFILE --notary-keychain PATH | --signed-only) [--output-dir PATH] [--dry-run]`
- Produces: final ZIP path and SHA-256 path on stdout
- Uses exit 64 for usage, 78 for missing configuration/identity, and 70 for
  build/sign/notary verification failure

- [ ] **Step 1: Write failing release preflight tests**

```python
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPT = ROOT / "scripts/build-release.sh"
WRITE_SHA256 = ROOT / "scripts/write-sha256.sh"
ATOMIC_PUBLISH = ROOT / "scripts/atomic-publish-directory.py"
SAFE_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": str(Path.home()),
    "DEVELOPER_DIR":
        "/Applications/Xcode.app/Contents/Developer",
    "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
}


class BuildReleaseContractTests(unittest.TestCase):
    def run_release(self, *arguments):
        return subprocess.run(
            ["/bin/bash", str(RELEASE_SCRIPT), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env=SAFE_ENV,
        )

    def test_requires_exact_version_build_identity_and_mode(self):
        result = self.run_release("--dry-run")
        self.assertEqual(result.returncode, 64)

    def test_rejects_both_notary_modes(self):
        result = self.run_release(
            "--version", "1.0.0",
            "--build-number", "100",
            "--signing-identity", "Developer ID Application: Test",
            "--notary-profile", "profile",
            "--signed-only",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 64)

    def test_notary_profile_requires_explicit_keychain(self):
        result = self.run_release(
            "--version", "1.0.0",
            "--build-number", "100",
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--notary-profile", "profile",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 64)

    def test_dry_run_prints_plan_without_building(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "release"
            result = self.run_release(
                "--version", "1.0.0",
                "--build-number", "100",
                "--signing-identity",
                "Developer ID Application: Test (TEAMID)",
                "--signed-only",
                "--output-dir", str(output),
                "--dry-run",
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("local.meeting.recorder", result.stdout)
            self.assertIn("release-candidate", result.stdout)
            self.assertFalse(output.exists())

    def test_missing_identity_fails_before_build(self):
        result = self.run_release(
            "--version", "1.0.0",
            "--build-number", "100",
            "--signing-identity",
            "Developer ID Application: Definitely Missing",
            "--signed-only",
        )
        self.assertEqual(result.returncode, 78)
        self.assertIn("identity", result.stderr.lower())

    def test_release_and_checksum_scripts_are_executable(self):
        self.assertTrue(os.access(RELEASE_SCRIPT, os.X_OK))
        self.assertTrue(os.access(WRITE_SHA256, os.X_OK))

    def test_atomic_publish_succeeds_only_when_destination_absent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "staged"
            destination = root / "release"
            source.mkdir()
            (source / "artifact.zip").write_bytes(b"release")

            success = subprocess.run(
                [
                    "/usr/bin/python3", str(ATOMIC_PUBLISH),
                    str(source), str(destination),
                ],
                text=True,
                capture_output=True,
                check=False,
                env=SAFE_ENV,
            )
            self.assertEqual(success.returncode, 0)
            self.assertFalse(source.exists())
            self.assertTrue(
                (destination / "artifact.zip").is_file()
            )

    def test_atomic_publish_refuses_competing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "staged"
            destination = root / "release"
            source.mkdir()
            destination.mkdir()
            (source / "artifact.zip").write_bytes(b"release")

            refused = subprocess.run(
                [
                    "/usr/bin/python3", str(ATOMIC_PUBLISH),
                    str(source), str(destination),
                ],
                text=True,
                capture_output=True,
                check=False,
                env=SAFE_ENV,
            )
            self.assertEqual(refused.returncode, 73)
            self.assertTrue(source.is_dir())
            self.assertFalse(
                (destination / "staged").exists()
            )

    def test_checksum_is_portable_and_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "artifact.zip"
            artifact.write_bytes(b"release")
            result = subprocess.run(
                [str(WRITE_SHA256), str(artifact)],
                text=True,
                capture_output=True,
                check=False,
                env=SAFE_ENV,
            )
            self.assertEqual(result.returncode, 0)
            checksum = artifact.with_suffix(".zip.sha256")
            line = checksum.read_text(
                encoding="utf-8"
            ).strip()
            self.assertTrue(line.endswith("  artifact.zip"))
            self.assertNotIn(str(Path(temporary)), line)
            verified = subprocess.run(
                [
                    "/usr/bin/shasum", "-a", "256", "-c",
                    checksum.name,
                ],
                cwd=temporary,
                text=True,
                capture_output=True,
                check=False,
                env=SAFE_ENV,
            )
            self.assertEqual(verified.returncode, 0)

    def test_publication_stages_complete_release_before_rename(self):
        script = RELEASE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(".lmr-release-publish.XXXXXX", script)
        self.assertIn('cp "$ROOT_DIR/LICENSE"', script)
        self.assertIn(
            'cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md"',
            script,
        )
        publish_call = (
            '"$ROOT_DIR/scripts/atomic-publish-directory.py"'
        )
        self.assertIn(publish_call, script)
        self.assertLess(
            script.index('cp "$ROOT_DIR/LICENSE"'),
            script.rindex(publish_call),
        )
```

- [ ] **Step 2: Run release tests to verify RED**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_build_release_contract -v
```

Expected: file-not-found failures.

- [ ] **Step 3: Implement argument validation and dry-run**

Use the same version/build regex as `build-app.sh`. Require exactly one mode:

```text
--signed-only
--notary-profile PROFILE --notary-keychain ABSOLUTE_KEYCHAIN_PATH
```

Reject `--notary-keychain` without a profile, a profile without a keychain, a
relative keychain path, or either notary option combined with
`--signed-only`. Normalize `OUTPUT_DIR` with the same non-mutating Python
`abspath` approach as Task 1 before evaluating dry-run.

Dry-run outputs this shell-escaped plan and exits before creating output:

```text
bundle_id=local.meeting.recorder
bundle_name=Local Meeting Recorder
version=<version>
build_number=<build>
signing_identity=<identity>
mode=notarized-production|signed-release-candidate
output_dir=<absolute path>
notary_keychain=<absolute path or none>
```

Never call `security`, `swift`, `codesign`, `notarytool`, `ditto`, `rm`, or
`mkdir` in dry-run mode.

- [ ] **Step 4: Preflight the exact signing identity**

Before any build:

```bash
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! printf '%s\n' "$IDENTITIES" \
    | grep -F -- "\"$SIGNING_IDENTITY\"" >/dev/null; then
  echo "Developer ID Application identity is not available." >&2
  exit 78
fi
```

Also require the identity string to start with
`Developer ID Application:`. Do not print the complete identity inventory.
In notarized mode, require `NOTARY_KEYCHAIN` to be a readable regular file
before building; do not print its contents.

- [ ] **Step 5: Assemble an unsigned production bundle**

Create a temporary release directory only after identity preflight:

```bash
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lmr-release.XXXXXX")"
PUBLISH_STAGING=""
cleanup() {
  rm -rf "$WORK_DIR"
  if [[ -n "$PUBLISH_STAGING" ]]; then
    rm -rf "$PUBLISH_STAGING"
  fi
}
trap cleanup EXIT
APP="$WORK_DIR/Local Meeting Recorder.app"

"$ROOT_DIR/scripts/build-app.sh" \
  --configuration release \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --bundle-id local.meeting.recorder \
  --bundle-name "Local Meeting Recorder" \
  --output "$APP" \
  --sign none >/dev/null
```

- [ ] **Step 6: Sign inside-out with hardened runtime**

```bash
codesign --force \
  --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements \
  "$ROOT_DIR/Config/LocalMeetingRecorder.entitlements" \
  "$APP/Contents/MacOS/LocalMeetingRecorder"

codesign --force \
  --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements \
  "$ROOT_DIR/Config/LocalMeetingRecorder.entitlements" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$SIGN_DETAILS" | grep -q 'flags=.*runtime'
printf '%s\n' "$SIGN_DETAILS" | grep -q 'TeamIdentifier='
ENTITLEMENT_DUMP="$WORK_DIR/effective-entitlements.plist"
codesign -d --entitlements :- "$APP" \
  > "$ENTITLEMENT_DUMP" 2>/dev/null
test "$(
  plutil -extract com.apple.security.device.audio-input \
    raw -o - "$ENTITLEMENT_DUMP"
)" = "true"
```

If any command fails, exit 70 and publish nothing.

- [ ] **Step 7: Notarize only in production mode**

Create a temporary submission ZIP:

```bash
SUBMISSION_ZIP="$WORK_DIR/notary-submission.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
xcrun notarytool submit \
  "$SUBMISSION_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --keychain "$NOTARY_KEYCHAIN" \
  --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
```

`--signed-only` skips these four commands and uses artifact stem:

```text
Local-Meeting-Recorder-<version>-<build>-release-candidate
```

Notarized mode uses:

```text
Local-Meeting-Recorder-<version>-<build>
```

- [ ] **Step 8: Add checksum and atomic-publication helpers**

Create `scripts/write-sha256.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || {
  echo "Usage: write-sha256.sh <artifact>" >&2
  exit 64
}
ARTIFACT="$1"
[[ -f "$ARTIFACT" ]] || {
  echo "Artifact is not a regular file." >&2
  exit 66
}
DIRECTORY="$(cd "$(dirname "$ARTIFACT")" && pwd)"
BASENAME="$(basename "$ARTIFACT")"
CHECKSUM="$DIRECTORY/$BASENAME.sha256"
(
  cd "$DIRECTORY"
  /usr/bin/shasum -a 256 "$BASENAME" \
    > "$BASENAME.sha256"
  /usr/bin/shasum -a 256 -c "$BASENAME.sha256" \
    >/dev/null
)
printf '%s\n' "$CHECKSUM"
```

The checksum line contains only the ZIP basename, so it remains verifiable
after download.

Create `scripts/atomic-publish-directory.py`:

```python
#!/usr/bin/env python3
import ctypes
import errno
import os
import sys
from pathlib import Path


AT_FDCWD = -2
RENAME_EXCL = 0x00000004


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: atomic-publish-directory.py "
            "<source-directory> <destination-directory>",
            file=sys.stderr,
        )
        return 64
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    if source.is_symlink() or not source.is_dir():
        print("Source is not a regular directory.", file=sys.stderr)
        return 66
    if not source.is_absolute() or not destination.is_absolute():
        print("Publication paths must be absolute.", file=sys.stderr)
        return 64

    libc = ctypes.CDLL(
        "/usr/lib/libSystem.B.dylib",
        use_errno=True,
    )
    rename_exclusive = libc.renameatx_np
    rename_exclusive.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    rename_exclusive.restype = ctypes.c_int
    result = rename_exclusive(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(destination),
        RENAME_EXCL,
    )
    if result == 0:
        return 0
    status = ctypes.get_errno()
    if status == errno.EEXIST:
        print(
            "Release output directory already exists.",
            file=sys.stderr,
        )
        return 73
    print(
        f"Atomic release publication failed with errno {status}.",
        file=sys.stderr,
    )
    return 70


if __name__ == "__main__":
    raise SystemExit(main())
```

The Darwin SDK defines `RENAME_EXCL` as `0x00000004`; this call fails rather
than nesting or replacing when a competing destination appears.

- [ ] **Step 9: Publish only final verified artifacts**

Require the final output directory to be absent, then stage the complete
release set in a temporary sibling directory on the same filesystem:

```bash
[[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || {
  echo "Release output directory must not already exist." >&2
  exit 73
}
mkdir -p "$(dirname "$OUTPUT_DIR")"
PUBLISH_STAGING="$(
  mktemp -d \
    "$(dirname "$OUTPUT_DIR")/.lmr-release-publish.XXXXXX"
)"
STAGED_ZIP="$PUBLISH_STAGING/${ARTIFACT_STEM}.zip"
ditto -c -k --keepParent "$APP" "$STAGED_ZIP"
STAGED_CHECKSUM="$(
  "$ROOT_DIR/scripts/write-sha256.sh" "$STAGED_ZIP"
)"
cp "$ROOT_DIR/LICENSE" "$PUBLISH_STAGING/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" \
  "$PUBLISH_STAGING/THIRD_PARTY_NOTICES.md"

test -s "$STAGED_ZIP"
test -s "$STAGED_CHECKSUM"
cmp -s "$ROOT_DIR/LICENSE" "$PUBLISH_STAGING/LICENSE"
cmp -s \
  "$ROOT_DIR/THIRD_PARTY_NOTICES.md" \
  "$PUBLISH_STAGING/THIRD_PARTY_NOTICES.md"
(
  cd "$PUBLISH_STAGING"
  /usr/bin/shasum -a 256 -c \
    "$(basename "$STAGED_CHECKSUM")" >/dev/null
)

/usr/bin/python3 \
  "$ROOT_DIR/scripts/atomic-publish-directory.py" \
  "$PUBLISH_STAGING" \
  "$OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" && ! -e "$PUBLISH_STAGING" ]] || {
  echo "Atomic release publication failed." >&2
  exit 70
}
PUBLISH_STAGING=""

FINAL_ZIP="$OUTPUT_DIR/${ARTIFACT_STEM}.zip"
CHECKSUM="$FINAL_ZIP.sha256"
printf '%s\n' "$FINAL_ZIP"
printf '%s\n' "$CHECKSUM"
```

No final artifact path exists until ZIP, checksum, `LICENSE`, and
`THIRD_PARTY_NOTICES.md` all pass verification. A failure removes only the
temporary staging directory.

- [ ] **Step 10: Run no-certificate tests and commit Task 3**

```bash
chmod +x scripts/build-release.sh scripts/write-sha256.sh
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_build_release_contract -v
/bin/bash -n scripts/build-release.sh
git add \
  scripts/build-release.sh \
  scripts/write-sha256.sh \
  scripts/atomic-publish-directory.py \
  Tests/ScriptTests/test_build_release_contract.py
git commit -m "Add gated Developer ID release builder"
```

Expected: dry-run tests pass and the current machine's missing-identity test
fails closed with exit 78. Do not claim a production artifact.

### Task 4: Continuous Integration Workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `Tests/ScriptTests/test_workflow_contract.py`

**Interfaces:**
- Produces: required `swift-tests`, `script-tests`, `packaging`, and `policy`
  jobs

- [ ] **Step 1: Write a failing workflow contract test**

Use Python standard-library text assertions so CI needs no YAML package:

```python
class WorkflowContractTests(unittest.TestCase):
    def test_ci_has_required_jobs_and_commands(self):
        workflow = (
            ROOT / ".github/workflows/ci.yml"
        ).read_text(encoding="utf-8")
        for job in (
            "swift-tests:",
            "script-tests:",
            "packaging:",
            "policy:",
        ):
            self.assertIn(job, workflow)
        self.assertIn("swift test", workflow)
        self.assertIn(
            "python3 -m unittest discover",
            workflow,
        )
        self.assertIn(
            "Tests/PackagingTests/run-tests.sh",
            workflow,
        )
        self.assertIn(
            "VirtualMicDriverTests/run-tests.sh",
            workflow,
        )
        self.assertNotIn("install-app.sh", workflow)
        self.assertNotIn("install-virtual-mic.sh", workflow)
```

- [ ] **Step 2: Create the CI workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  swift-tests:
    runs-on: macos-26
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - name: Targeted transcription tests
        run: swift test --filter OpenAICompatibleTranscriptionClientTests
      - name: Swift tests
        run: swift test
      - name: Swift tests stability pass
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: swift test

  script-tests:
    runs-on: macos-26
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - name: Python script tests
        run: >-
          python3 -m unittest discover
          -s Tests/ScriptTests
          -p 'test_*.py'
          -v

  packaging:
    runs-on: macos-26
    timeout-minutes: 20
    needs: [swift-tests, script-tests]
    steps:
      - uses: actions/checkout@v4
      - name: App bundle smoke tests
        run: Tests/PackagingTests/run-tests.sh
      - name: Virtual microphone bridge tests
        run: Tests/VirtualMicDriverTests/run-tests.sh
      - name: Virtual microphone bundle tests
        run: Tests/VirtualMicDriverTests/run-bundle-tests.sh
      - name: Virtual microphone script tests
        run: Tests/VirtualMicDriverTests/run-script-tests.sh

  policy:
    runs-on: macos-26
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: License and active metadata policy
        run: >-
          python3 -m unittest
          Tests.ScriptTests.test_packaging_contract
          Tests.ScriptTests.test_workflow_contract
          -v
      - name: Diff whitespace
        run: git diff --check origin/main...HEAD
```

Do not add third-party actions beyond `actions/checkout@v4` in this milestone.

- [ ] **Step 3: Run workflow tests and commit Task 4**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_workflow_contract -v
/usr/bin/python3 -m unittest discover \
  -s Tests/ScriptTests -p 'test_*.py' -v
git add \
  .github/workflows/ci.yml \
  Tests/ScriptTests/test_workflow_contract.py
git commit -m "Add macOS continuous integration"
```

Expected: all script tests pass.

### Task 5: Protected Manual Release Workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `Tests/ScriptTests/test_workflow_contract.py`

**Interfaces:**
- Produces: manual `workflow_dispatch`
- Uses: protected `production` environment
- Consumes repository secrets:
  `MACOS_CERTIFICATE_P12_BASE64`,
  `MACOS_CERTIFICATE_PASSWORD`,
  `MACOS_SIGNING_IDENTITY`,
  `MACOS_NOTARY_KEY_ID`,
  `MACOS_NOTARY_ISSUER_ID`,
  `MACOS_NOTARY_PRIVATE_KEY_BASE64`

- [ ] **Step 1: Add failing release-workflow policy tests**

```python
def test_release_is_manual_and_protected(self):
    workflow = (
        ROOT / ".github/workflows/release.yml"
    ).read_text(encoding="utf-8")
    self.assertIn("workflow_dispatch:", workflow)
    self.assertIn("environment: production", workflow)
    self.assertIn("build-release.sh", workflow)
    self.assertIn("--notary-profile", workflow)
    self.assertIn("--notary-keychain", workflow)
    self.assertIn("refs/heads/main", workflow)
    self.assertIn("swift test", workflow)
    self.assertIn(
        "Tests/PackagingTests/run-tests.sh",
        workflow,
    )
    self.assertLess(
        workflow.index("Verify releasable ref"),
        workflow.index("Configure temporary signing keychain"),
    )
    self.assertLess(
        workflow.index("Run release gates"),
        workflow.index("Configure temporary signing keychain"),
    )
    self.assertIn("if: always()", workflow)
    self.assertNotIn("pull_request:", workflow)
    self.assertNotIn("push:", workflow)
```

- [ ] **Step 2: Create exact workflow inputs and permissions**

```yaml
name: Production Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: CFBundleShortVersionString
        required: true
        type: string
      build_number:
        description: CFBundleVersion
        required: true
        type: string

permissions:
  contents: read

jobs:
  release:
    runs-on: macos-26
    timeout-minutes: 45
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Verify releasable ref
        run: |
          if [[ "$GITHUB_REF" != "refs/heads/main" ]]; then
            echo "Production releases must run from main." >&2
            exit 64
          fi
      - name: Run release gates
        run: |
          swift test
          swift test
          python3 -m unittest discover \
            -s Tests/ScriptTests -p 'test_*.py' -v
          Tests/PackagingTests/run-tests.sh
          Tests/VirtualMicDriverTests/run-tests.sh
          Tests/VirtualMicDriverTests/run-bundle-tests.sh
          Tests/VirtualMicDriverTests/run-script-tests.sh
      - name: Preflight required secrets
        env:
          P12: ${{ secrets.MACOS_CERTIFICATE_P12_BASE64 }}
          P12_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
          IDENTITY: ${{ secrets.MACOS_SIGNING_IDENTITY }}
          KEY_ID: ${{ secrets.MACOS_NOTARY_KEY_ID }}
          ISSUER_ID: ${{ secrets.MACOS_NOTARY_ISSUER_ID }}
          PRIVATE_KEY: ${{ secrets.MACOS_NOTARY_PRIVATE_KEY_BASE64 }}
        run: |
          for value in "$P12" "$P12_PASSWORD" "$IDENTITY" \
            "$KEY_ID" "$ISSUER_ID" "$PRIVATE_KEY"; do
            test -n "$value" || {
              echo "A required production secret is missing." >&2
              exit 78
            }
          done
```

- [ ] **Step 3: Import credentials into a temporary Keychain**

Add:

```yaml
      - name: Configure temporary signing keychain
        env:
          P12: ${{ secrets.MACOS_CERTIFICATE_P12_BASE64 }}
          P12_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
          PRIVATE_KEY: ${{ secrets.MACOS_NOTARY_PRIVATE_KEY_BASE64 }}
          KEY_ID: ${{ secrets.MACOS_NOTARY_KEY_ID }}
          ISSUER_ID: ${{ secrets.MACOS_NOTARY_ISSUER_ID }}
        run: |
          KEYCHAIN="$RUNNER_TEMP/lmr-signing.keychain-db"
          KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
          printf '%s' "$P12" | base64 --decode \
            > "$RUNNER_TEMP/signing.p12"
          printf '%s' "$PRIVATE_KEY" | base64 --decode \
            > "$RUNNER_TEMP/AuthKey.p8"
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
          security import "$RUNNER_TEMP/signing.p12" \
            -k "$KEYCHAIN" \
            -P "$P12_PASSWORD" \
            -T /usr/bin/codesign \
            -T /usr/bin/security
          security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s \
            -k "$KEYCHAIN_PASSWORD" \
            "$KEYCHAIN"
          security list-keychains -d user -s "$KEYCHAIN"
          xcrun notarytool store-credentials lmr-production \
            --key "$RUNNER_TEMP/AuthKey.p8" \
            --key-id "$KEY_ID" \
            --issuer "$ISSUER_ID" \
            --keychain "$KEYCHAIN"
          echo "::add-mask::$KEYCHAIN_PASSWORD"
          echo "LMR_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
```

Mask `KEYCHAIN_PASSWORD` with `::add-mask::` before writing it to
`GITHUB_ENV`.

- [ ] **Step 4: Run the release builder and upload only final artifacts**

```yaml
      - name: Build, sign, notarize, and verify
        env:
          SIGNING_IDENTITY: ${{ secrets.MACOS_SIGNING_IDENTITY }}
        run: |
          ./scripts/build-release.sh \
            --version "${{ inputs.version }}" \
            --build-number "${{ inputs.build_number }}" \
            --signing-identity "$SIGNING_IDENTITY" \
            --notary-profile lmr-production \
            --notary-keychain "$LMR_KEYCHAIN" \
            --output-dir "$RUNNER_TEMP/release"

      - name: Verify portable checksum
        run: |
          cd "$RUNNER_TEMP/release"
          /usr/bin/shasum -a 256 -c ./*.sha256

      - name: Upload verified release
        uses: actions/upload-artifact@v4
        with:
          name: Local-Meeting-Recorder-${{ inputs.version }}-${{ inputs.build_number }}
          path: |
            ${{ runner.temp }}/release/*.zip
            ${{ runner.temp }}/release/*.sha256
            ${{ runner.temp }}/release/LICENSE
            ${{ runner.temp }}/release/THIRD_PARTY_NOTICES.md
          if-no-files-found: error
```

`actions/upload-artifact@v4` is the only additional official GitHub action.

- [ ] **Step 5: Always destroy temporary credentials**

```yaml
      - name: Remove temporary credentials
        if: always()
        run: |
          KEYCHAIN="${LMR_KEYCHAIN:-$RUNNER_TEMP/lmr-signing.keychain-db}"
          if [[ -e "$KEYCHAIN" ]]; then
            security delete-keychain "$KEYCHAIN" || true
          fi
          rm -f \
            "$RUNNER_TEMP/signing.p12" \
            "$RUNNER_TEMP/AuthKey.p8"
```

- [ ] **Step 6: Run policy tests and commit Task 5**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_workflow_contract -v
git add \
  .github/workflows/release.yml \
  Tests/ScriptTests/test_workflow_contract.py
git commit -m "Add protected notarized release workflow"
```

Expected: policy tests pass. Do not dispatch the workflow until repository
secrets and environment approvals are configured by the owner.

### Task 6: Release Documentation and Complete Verification

**Files:**
- Modify: `README.md`
- Verify all build and workflow artifacts.

**Interfaces:**
- Documents: staging, signed candidate, notarized production, and current local
  limitation

- [ ] **Step 1: Add exact build commands to README**

```markdown
## Build and Release

Local staging build:

```bash
./scripts/build-app.sh
```

Repeatable release-configuration staging build:

```bash
./scripts/build-app.sh \
  --configuration release \
  --version 0.2.0 \
  --build-number 2 \
  --sign ad-hoc
```

Validate a staging bundle:

```bash
./Tests/PackagingTests/run-tests.sh
```

Preview a signed release candidate without building:

```bash
./scripts/build-release.sh \
  --version 1.0.0 \
  --build-number 100 \
  --signing-identity "Developer ID Application: Name (TEAMID)" \
  --signed-only \
  --dry-run
```

Production release requires a real Developer ID Application identity and a
configured `notarytool` Keychain profile:

```bash
./scripts/build-release.sh \
  --version 1.0.0 \
  --build-number 100 \
  --signing-identity "Developer ID Application: Name (TEAMID)" \
  --notary-profile lmr-production \
  --notary-keychain "/absolute/path/to/release.keychain-db"
```

An ad-hoc staging build is never labeled as a production release. The manual
workflow uploads a notarized candidate; it does not publish a GitHub Release
until the microphone acceptance check below passes on an authorized QA Mac.
```

- [ ] **Step 2: Run every automated gate**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
/usr/bin/python3 -m unittest discover \
  -s Tests/ScriptTests -p 'test_*.py' -v
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./Tests/PackagingTests/run-tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./Tests/VirtualMicDriverTests/run-tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./Tests/VirtualMicDriverTests/run-bundle-tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./Tests/VirtualMicDriverTests/run-script-tests.sh
```

Expected: zero failures and only the existing intentional Swift skip.

- [ ] **Step 3: Prove production failure gates locally**

```bash
./scripts/build-release.sh \
  --version 1.0.0 \
  --build-number 100 \
  --signing-identity "Developer ID Application: Missing" \
  --signed-only
```

Expected: exit 78 before any release output directory or ZIP is created.

- [ ] **Step 4: Verify repository state and commit documentation**

```bash
git diff --check c201cc1..HEAD
git status --short
git add README.md
git commit -m "Document staged and notarized release workflows"
```

Expected before the final commit: only README is staged. Expected after: clean
worktree.

- [ ] **Step 5: Define the signed microphone acceptance gate**

After a real Developer ID/notarized workflow succeeds, but before creating a
public GitHub Release, an authorized QA user must:

```text
1. Download the workflow artifact and verify its SHA-256 with:
   /usr/bin/shasum -a 256 -c <checksum-file>
2. Expand the ZIP into a temporary QA folder, not /Applications.
3. Run codesign --verify --deep --strict and spctl --assess --type execute.
4. Launch that exact candidate, grant Microphone permission when macOS asks,
   choose Mic Only mode, and record 10 seconds of speech.
5. Confirm the in-app mic waveform moves and the saved M4A is non-empty and
   audible, then quit and remove the temporary QA copy.
```

Record the tested commit SHA, artifact SHA-256, macOS version, input device,
and pass/fail in the release notes. This gate cannot be claimed on the current
machine until a real Developer ID identity exists.

- [ ] **Step 6: Independent release review**

The reviewer checks:

```text
- no secret values in workflow, script arguments, or logs
- dry-run performs no mutation
- identity preflight precedes build
- signing is inside-out with runtime and timestamp
- signed app contains the Audio Input entitlement
- notarization precedes final ZIP and checksum
- notary profile is read from the explicit custom Keychain
- checksum contains only the portable ZIP basename and verifies successfully
- signed-only artifact says release-candidate
- manual release runs only from main and reruns all gates before credentials
- CI never installs or launches the app/driver
- final release remains unclaimed until a real Developer ID run succeeds
```
