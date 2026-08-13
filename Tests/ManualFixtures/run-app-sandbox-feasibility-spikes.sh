#!/usr/bin/env bash
set -euo pipefail

# Disposable App Sandbox evidence only. It does not call any production build,
# install, signing, entitlement, release, or TCC-setting path.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/Tests/ManualFixtures"
OUTPUT_ROOT="${1:-/private/tmp/local-meeting-recorder-sandbox-spike}"
APP="$OUTPUT_ROOT/LocalMeetingRecorderSandboxSpike.app"
BUNDLE_ID="com.localmeetingrecorder.sandbox-spike.$(id -u)"
SWIFTC="$(/usr/bin/xcrun --find swiftc)"
CODESIGN="$(/usr/bin/xcrun --find codesign)"
SDKROOT="$(/usr/bin/xcrun --show-sdk-path)"

case "$OUTPUT_ROOT" in
  /private/tmp/*) ;;
  *) echo "Output must stay under /private/tmp." >&2; exit 64 ;;
esac

rm -rf "$OUTPUT_ROOT"
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
echo "manual-bookmark-select=$APP/Contents/MacOS/SandboxSpike bookmark-select"
echo "manual-bookmark-relaunch=$APP/Contents/MacOS/SandboxSpike bookmark-verify"
echo "manual-background-launch=/usr/bin/open -gj '$APP' --args ipc-embedded"

# Passive/fixture-owned runtime evidence: no permission requests or GUI panels.
"$APP/Contents/MacOS/SandboxSpike" capture-status
"$APP/Contents/MacOS/SandboxSpike" pending
if "$APP/Contents/MacOS/SandboxSpike" ipc-embedded; then
  echo "ipc.embedded-helper-result=passed"
else
  ipc_status=$?
  echo "ipc.embedded-helper-result=failed(exit=$ipc_status)"
fi
