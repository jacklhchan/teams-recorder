#!/usr/bin/env bash
set -euo pipefail

# Disposable App Sandbox evidence only. It does not call any production build,
# install, signing, entitlement, release, or TCC-setting path.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/Tests/ManualFixtures"
MODE="passive"
case "$#" in
  0) ;;
  1)
    case "$1" in
      "--bookmark") MODE="bookmark" ;;
      *)
        echo "usage: $0 [--bookmark]" >&2
        exit 64
        ;;
    esac
    ;;
  *)
    echo "usage: $0 [--bookmark]" >&2
    exit 64
    ;;
esac

OUTPUT_ROOT="$(mktemp -d /private/tmp/lmr-sandbox-spike.XXXXXX)"
OUTPUT_CREATED=1
APP="$OUTPUT_ROOT/LocalMeetingRecorderSandboxSpike.app"
BUNDLE_ID="com.localmeetingrecorder.sandbox-spike.$(id -u)"
SWIFTC="$(/usr/bin/xcrun --find swiftc)"
CODESIGN="$(/usr/bin/xcrun --find codesign)"
SDKROOT="$(/usr/bin/xcrun --show-sdk-path)"

is_owned_output_root() {
  [[ "${OUTPUT_CREATED:-0}" == 1 ]] || return 1
  [[ -d "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] || return 1
  local canonical_output_root
  canonical_output_root="$(cd -P "$OUTPUT_ROOT" && /bin/pwd -P)" || return 1
  [[ "$canonical_output_root" == "$OUTPUT_ROOT" ]] || return 1
  case "$canonical_output_root" in
    /private/tmp/lmr-sandbox-spike.*) ;;
    *) return 1 ;;
  esac
}

cleanup_output_root() {
  if [[ "${MODE:-passive}" == "bookmark" && -x "${APP:-}/Contents/MacOS/SandboxSpike" ]]; then
    "$APP/Contents/MacOS/SandboxSpike" bookmark-cleanup >/dev/null 2>&1 || true
  fi
  if is_owned_output_root; then
    rm -rf -- "$OUTPUT_ROOT"
  else
    echo "Refusing to remove an unowned fixture output directory: $OUTPUT_ROOT" >&2
  fi
}
trap cleanup_output_root EXIT

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
/usr/bin/python3 - "$APP/Contents/Info.plist" "$BUNDLE_ID" <<'PY'
import plistlib
import sys
from pathlib import Path
plistlib.dump({
    "CFBundleExecutable": "SandboxSpike",
    "CFBundleIdentifier": sys.argv[2],
    "CFBundleName": "Local Meeting Recorder Sandbox Spike",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.0.1",
    "CFBundleVersion": "1",
    "NSMicrophoneUsageDescription": "Disposable sandbox feasibility probe.",
    "NSScreenCaptureUsageDescription": "Disposable sandbox feasibility probe.",
}, Path(sys.argv[1]).open("wb"))
PY

"$SWIFTC" -parse-as-library -sdk "$SDKROOT" -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
  "$FIXTURE_DIR/AppSandboxSpike.swift" -o "$APP/Contents/MacOS/SandboxSpike"
"$SWIFTC" -sdk "$SDKROOT" "$FIXTURE_DIR/AppSandboxSpikeHelper.swift" -o "$APP/Contents/Helpers/SandboxSpikeHelper"
"$CODESIGN" --force --sign - --timestamp=none --entitlements "$FIXTURE_DIR/AppSandboxSpikeHelper.entitlements" "$APP/Contents/Helpers/SandboxSpikeHelper"
"$CODESIGN" --force --sign - --timestamp=none --entitlements "$FIXTURE_DIR/AppSandboxSpike.entitlements" "$APP/Contents/MacOS/SandboxSpike"
"$CODESIGN" --force --sign - --timestamp=none --entitlements "$FIXTURE_DIR/AppSandboxSpike.entitlements" "$APP"
"$CODESIGN" --verify --deep --strict "$APP"
"$CODESIGN" -d --entitlements :- "$APP" 2>/dev/null

echo "app=$APP"
echo "manual-background-launch=/usr/bin/open -gj '$APP' --args ipc-embedded"

run_bookmark_spike() {
  # This keeps the disposable bundle present while the operator picks a folder,
  # then proves the saved bookmark from a separate process before cleanup.
  "$APP/Contents/MacOS/SandboxSpike" bookmark-select
  "$APP/Contents/MacOS/SandboxSpike" bookmark-verify
}

if [[ "$MODE" == "bookmark" ]]; then
  run_bookmark_spike
  exit 0
fi

# Passive/fixture-owned runtime evidence: no permission requests or GUI panels.
"$APP/Contents/MacOS/SandboxSpike" capture-status
"$APP/Contents/MacOS/SandboxSpike" pending-create
"$APP/Contents/MacOS/SandboxSpike" pending-recover
if "$APP/Contents/MacOS/SandboxSpike" ipc-embedded; then
  echo "ipc.embedded-helper-result=passed"
else
  ipc_status=$?
  echo "ipc.embedded-helper-result=failed(exit=$ipc_status)"
fi
