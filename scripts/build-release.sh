#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRUSTED_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="$TRUSTED_PATH"
unset SWIFT_BIN CODESIGN_BIN

VERSION=""
BUILD_NUMBER=""
SIGNING_IDENTITY=""
NOTARY_PROFILE=""
NOTARY_KEYCHAIN=""
OUTPUT_DIR=""
SIGNED_ONLY=0
DRY_RUN=0

usage() {
  cat >&2 <<'USAGE'
Usage: build-release.sh --version X.Y.Z --build-number N --signing-identity ID
  (--notary-profile PROFILE --notary-keychain ABSOLUTE_KEYCHAIN_PATH | --signed-only)
  [--output-dir ABSOLUTE_PATH] [--dry-run]
USAGE
}

die_usage() {
  echo "$1" >&2
  usage
  exit 64
}

fail_execution() {
  echo "$1" >&2
  exit 70
}

run_checked() {
  if "$@"; then
    return 0
  fi
  fail_execution "Release command failed."
}

resolve_xcode_tool() {
  local tool="$1"
  local resolved
  resolved="$(/usr/bin/xcrun --find "$tool" 2>/dev/null)" || \
    fail_execution "Required Xcode tool is unavailable."
  [[ "$resolved" == /* && -x "$resolved" ]] || \
    fail_execution "Resolved Xcode tool is not an absolute executable."
  printf '%s\n' "$resolved"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || die_usage "Missing version"; VERSION="$2"; shift 2 ;;
    --build-number) [[ $# -ge 2 ]] || die_usage "Missing build number"; BUILD_NUMBER="$2"; shift 2 ;;
    --signing-identity) [[ $# -ge 2 ]] || die_usage "Missing signing identity"; SIGNING_IDENTITY="$2"; shift 2 ;;
    --notary-profile) [[ $# -ge 2 ]] || die_usage "Missing notary profile"; NOTARY_PROFILE="$2"; shift 2 ;;
    --notary-keychain) [[ $# -ge 2 ]] || die_usage "Missing notary keychain"; NOTARY_KEYCHAIN="$2"; shift 2 ;;
    --output-dir) [[ $# -ge 2 ]] || die_usage "Missing output directory"; OUTPUT_DIR="$2"; shift 2 ;;
    --signed-only) SIGNED_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "Unknown option: $1" ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die_usage "Version must contain two or three numeric components."
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die_usage "Build number must be a positive integer."
[[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] || die_usage "Signing identity must be a Developer ID Application identity."
[[ "$SIGNED_ONLY" -eq 1 || -n "$NOTARY_PROFILE" ]] || die_usage "Select a release mode."
[[ ! ( "$SIGNED_ONLY" -eq 1 && ( -n "$NOTARY_PROFILE" || -n "$NOTARY_KEYCHAIN" ) ) ]] || die_usage "Notary options cannot be combined with signed-only mode."
if [[ -n "$NOTARY_PROFILE" || -n "$NOTARY_KEYCHAIN" ]]; then
  [[ -n "$NOTARY_PROFILE" && -n "$NOTARY_KEYCHAIN" ]] || die_usage "Notary profile and keychain must be supplied together."
  [[ "$NOTARY_KEYCHAIN" == /* ]] || die_usage "Notary keychain path must be absolute."
fi

MODE="notarized-production"
ARTIFACT_STEM="Local-Meeting-Recorder-${VERSION}-${BUILD_NUMBER}"
if [[ "$SIGNED_ONLY" -eq 1 ]]; then
  MODE="signed-release-candidate"
  ARTIFACT_STEM+="-release-candidate"
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/build/releases/$ARTIFACT_STEM"
else
  [[ "$OUTPUT_DIR" == /* ]] || die_usage "Output directory path must be absolute."
fi
OUTPUT_DIR="$(/usr/bin/python3 - "$OUTPUT_DIR" <<'PY'
import os
import sys
from pathlib import Path

candidate = Path(os.path.abspath(os.path.expanduser(sys.argv[1])))
if any(component.is_symlink() for component in (candidate, *candidate.parents)):
    print("Output path cannot contain symbolic links.", file=sys.stderr)
    raise SystemExit(73)
print(candidate)
PY
)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'bundle_id=local.meeting.recorder\n'
  printf 'bundle_name=Local Meeting Recorder\n'
  printf 'version=%q\n' "$VERSION"
  printf 'build_number=%q\n' "$BUILD_NUMBER"
  printf 'signing_identity=%q\n' "$SIGNING_IDENTITY"
  printf 'mode=%s\n' "$MODE"
  printf 'output_dir=%q\n' "$OUTPUT_DIR"
  printf 'notary_keychain=%q\n' "${NOTARY_KEYCHAIN:-none}"
  exit 0
fi

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || {
  echo "Developer ID releases are supported only on macOS." >&2
  exit 78
}
[[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || {
  echo "Release output directory must not already exist." >&2
  exit 73
}
[[ -f "$ROOT_DIR/scripts/build-app.sh" && ! -L "$ROOT_DIR/scripts/build-app.sh" && -x "$ROOT_DIR/scripts/build-app.sh" ]] || {
  echo "Build helper is not a regular executable file." >&2
  exit 66
}
[[ -f "$ROOT_DIR/scripts/write-sha256.sh" && ! -L "$ROOT_DIR/scripts/write-sha256.sh" && -x "$ROOT_DIR/scripts/write-sha256.sh" ]] || {
  echo "Checksum helper is not a regular executable file." >&2
  exit 66
}
[[ -f "$ROOT_DIR/scripts/atomic-publish-directory.py" && ! -L "$ROOT_DIR/scripts/atomic-publish-directory.py" && -x "$ROOT_DIR/scripts/atomic-publish-directory.py" ]] || {
  echo "Publication helper is not a regular executable file." >&2
  exit 66
}
if [[ "$MODE" == "notarized-production" ]]; then
  [[ -f "$NOTARY_KEYCHAIN" && ! -L "$NOTARY_KEYCHAIN" && -r "$NOTARY_KEYCHAIN" ]] || {
    echo "Notary keychain is not a readable regular file." >&2
    exit 78
  }
fi

IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
if ! printf '%s\n' "$IDENTITIES" | /usr/bin/grep -F -- "\"$SIGNING_IDENTITY\"" >/dev/null; then
  echo "Developer ID Application identity is not available." >&2
  exit 78
fi

CODESIGN_BIN="$(resolve_xcode_tool codesign)"
PLUTIL_BIN="/usr/bin/plutil"
DITTO_BIN="/usr/bin/ditto"
SPCTL_BIN="/usr/sbin/spctl"
[[ -x "$PLUTIL_BIN" && -x "$DITTO_BIN" && -x "$SPCTL_BIN" ]] || fail_execution "Required system tool is unavailable."
if [[ "$MODE" == "notarized-production" ]]; then
  NOTARYTOOL_BIN="$(resolve_xcode_tool notarytool)"
  STAPLER_BIN="$(resolve_xcode_tool stapler)"
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lmr-release.XXXXXX")" || fail_execution "Cannot create release work directory."
PUBLISH_STAGING=""
cleanup() {
  /bin/rm -rf "$WORK_DIR"
  if [[ -n "$PUBLISH_STAGING" ]]; then
    /bin/rm -rf "$PUBLISH_STAGING"
  fi
}
trap cleanup EXIT
APP="$WORK_DIR/Local Meeting Recorder.app"

(
  unset SWIFT_BIN CODESIGN_BIN
  "$ROOT_DIR/scripts/build-app.sh" --configuration release --version "$VERSION" \
    --build-number "$BUILD_NUMBER" --bundle-id local.meeting.recorder \
    --bundle-name "Local Meeting Recorder" --output "$APP" --sign none
) >/dev/null || fail_execution "Release build failed."

run_checked "$CODESIGN_BIN" --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp --entitlements "$ROOT_DIR/Config/LocalMeetingRecorder.entitlements" "$APP/Contents/MacOS/LocalMeetingRecorder"
run_checked "$CODESIGN_BIN" --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp --entitlements "$ROOT_DIR/Config/LocalMeetingRecorder.entitlements" "$APP"
run_checked "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$APP"
SIGN_DETAILS="$($CODESIGN_BIN -d --verbose=4 "$APP" 2>&1)" || fail_execution "Signed bundle verification failed."
printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -q 'flags=.*runtime' || fail_execution "Hardened runtime is missing."
printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -q 'TeamIdentifier=' || fail_execution "Team identifier is missing."
ENTITLEMENT_DUMP="$WORK_DIR/effective-entitlements.plist"
"$CODESIGN_BIN" -d --entitlements :- "$APP" > "$ENTITLEMENT_DUMP" 2>/dev/null || fail_execution "Cannot inspect signed entitlements."
[[ "$("$PLUTIL_BIN" -extract com.apple.security.device.audio-input raw -o - "$ENTITLEMENT_DUMP")" == "true" ]] || fail_execution "Audio Input entitlement is missing."

if [[ "$MODE" == "notarized-production" ]]; then
  SUBMISSION_ZIP="$WORK_DIR/notary-submission.zip"
  run_checked "$DITTO_BIN" -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
  run_checked "$NOTARYTOOL_BIN" submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" --wait
  run_checked "$STAPLER_BIN" staple "$APP"
  run_checked "$STAPLER_BIN" validate "$APP"
  run_checked "$SPCTL_BIN" --assess --type execute --verbose=4 "$APP"
fi

OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
/bin/mkdir -p "$OUTPUT_PARENT" || fail_execution "Cannot create release output parent."
PUBLISH_STAGING="$(/usr/bin/mktemp -d "$OUTPUT_PARENT/.lmr-release-publish.XXXXXX")" || fail_execution "Cannot create release publication staging."
STAGED_ZIP="$PUBLISH_STAGING/${ARTIFACT_STEM}.zip"
run_checked "$DITTO_BIN" -c -k --keepParent "$APP" "$STAGED_ZIP"
STAGED_CHECKSUM="$("$ROOT_DIR/scripts/write-sha256.sh" "$STAGED_ZIP")" || fail_execution "Checksum generation failed."
/bin/cp "$ROOT_DIR/LICENSE" "$PUBLISH_STAGING/LICENSE" || fail_execution "Cannot stage LICENSE."
/bin/cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$PUBLISH_STAGING/THIRD_PARTY_NOTICES.md" || fail_execution "Cannot stage third-party notices."
[[ -s "$STAGED_ZIP" && -s "$STAGED_CHECKSUM" ]] || fail_execution "Staged release artifacts are incomplete."
/usr/bin/cmp -s "$ROOT_DIR/LICENSE" "$PUBLISH_STAGING/LICENSE" || fail_execution "Staged LICENSE differs."
/usr/bin/cmp -s "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$PUBLISH_STAGING/THIRD_PARTY_NOTICES.md" || fail_execution "Staged third-party notices differ."
(
  cd "$PUBLISH_STAGING"
  /usr/bin/shasum -a 256 -c "$(basename "$STAGED_CHECKSUM")" >/dev/null
) || fail_execution "Staged checksum verification failed."

if /usr/bin/python3 "$ROOT_DIR/scripts/atomic-publish-directory.py" "$PUBLISH_STAGING" "$OUTPUT_DIR"; then
  :
else
  STATUS=$?
  [[ "$STATUS" -eq 73 ]] && exit 73
  fail_execution "Atomic release publication failed."
fi
[[ -d "$OUTPUT_DIR" && ! -e "$PUBLISH_STAGING" ]] || fail_execution "Atomic release publication failed."
PUBLISH_STAGING=""

FINAL_ZIP="$OUTPUT_DIR/${ARTIFACT_STEM}.zip"
CHECKSUM="$FINAL_ZIP.sha256"
printf '%s\n' "$FINAL_ZIP"
printf '%s\n' "$CHECKSUM"
