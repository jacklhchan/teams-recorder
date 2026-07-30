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
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"
FILE_BIN="${FILE_BIN:-file}"

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
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = "26.0"
"$FILE_BIN" "$APP/Contents/MacOS/LocalMeetingRecorder" | grep -q 'arm64'
test -f "$APP/Contents/Resources/AppIcon.icns"
test ! -e "$APP/Contents/Resources/transcribe-openai-compatible.sh"
test ! -e "$APP/Contents/Resources/transcribe-qwen-asr.sh"
test ! -e "$APP/Contents/Resources/openai_asr_longform.py"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test ! -e "$APP/Contents/Resources/release-manifest.json"
test "$(<"$APP/Contents/Resources/.lmr-build-owner")" = "local.meeting.recorder.build-app.v1"

if [[ "$SIGN_MODE" == "ad-hoc" ]]; then
  "$CODESIGN_BIN" --verify --deep --strict "$APP" >&2
  SIGNING_METADATA="$("$CODESIGN_BIN" -d --verbose=4 "$APP" 2>&1 | tr -d '\r')"
  if ! printf '%s\n' "$SIGNING_METADATA" | grep -Eq '^[[:space:]]*Signature=adhoc[[:space:]]*$'; then
    echo "Expected an ad-hoc app signature." >&2
    exit 70
  fi
  TEAM_IDENTIFIER_LINES="$(printf '%s\n' "$SIGNING_METADATA" | grep -E '^[[:space:]]*TeamIdentifier=' || true)"
  if [[ -n "$TEAM_IDENTIFIER_LINES" ]] && printf '%s\n' "$TEAM_IDENTIFIER_LINES" | grep -Evq '^[[:space:]]*TeamIdentifier=not set[[:space:]]*$'; then
    echo "Ad-hoc app signature must not carry a team identifier." >&2
    exit 70
  fi
  ENTITLEMENT_DUMP="$(mktemp "${TMPDIR:-/tmp}/lmr-entitlements.XXXXXX")"
  trap 'rm -f "$ENTITLEMENT_DUMP"' EXIT
  "$CODESIGN_BIN" -d --entitlements :- "$APP" > "$ENTITLEMENT_DUMP" 2>/dev/null
  if ! /usr/bin/python3 - "$ENTITLEMENT_DUMP" <<'PY'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as stream:
    entitlements = plistlib.load(stream)
if entitlements != {"com.apple.security.device.audio-input": True}:
    raise SystemExit(1)
PY
  then
    echo "App entitlements must contain only Audio Input." >&2
    exit 70
  fi
else
  if "$CODESIGN_BIN" -dv "$APP" >/dev/null 2>&1; then
    echo "Unsigned staging bundle unexpectedly has a signature." >&2
    exit 70
  fi
fi
