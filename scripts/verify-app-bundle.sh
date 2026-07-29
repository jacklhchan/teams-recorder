#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: verify-app-bundle.sh APP_PATH EXPECTED_BUNDLE_ID EXPECTED_VERSION EXPECTED_BUILD SIGN_MODE" >&2
  exit 64
fi

APP="$1"
EXPECTED_ID="$2"
EXPECTED_VERSION="$3"
EXPECTED_BUILD="$4"
SIGN_MODE="$5"

[[ "$SIGN_MODE" == "ad-hoc" || "$SIGN_MODE" == "none" ]] || {
  echo "Sign mode must be ad-hoc or none." >&2
  exit 64
}
[[ -d "$APP" && ! -L "$APP" ]] || {
  echo "App path must be a non-symlinked directory." >&2
  exit 66
}

PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST" >&2
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "$EXPECTED_ID"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$EXPECTED_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$EXPECTED_BUILD"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = "15.0"
file "$APP/Contents/MacOS/LocalMeetingRecorder" | grep -q 'arm64'
test -x "$APP/Contents/Resources/transcribe-openai-compatible.sh"
test -x "$APP/Contents/Resources/openai_asr_longform.py"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test ! -e "$APP/Contents/Resources/release-manifest.json"
test "$(<"$APP/Contents/Resources/.lmr-build-owner")" = "local.meeting.recorder.build-app.v1"

if [[ "$SIGN_MODE" == "ad-hoc" ]]; then
  codesign --verify --deep --strict "$APP"
  ENTITLEMENT_DUMP="$(mktemp "${TMPDIR:-/tmp}/lmr-entitlements.XXXXXX")"
  trap 'rm -f "$ENTITLEMENT_DUMP"' EXIT
  codesign -d --entitlements :- "$APP" > "$ENTITLEMENT_DUMP" 2>/dev/null
  test "$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - "$ENTITLEMENT_DUMP")" = "true"
else
  if codesign -dv "$APP" >/dev/null 2>&1; then
    echo "Unsigned staging bundle unexpectedly has a signature." >&2
    exit 70
  fi
fi
