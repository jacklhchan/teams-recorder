#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER_BUNDLE="$ROOT_DIR/build/LocalRecorderVirtualMic.driver"
INFO_PLIST="$DRIVER_BUNDLE/Contents/Info.plist"
EXECUTABLE="$DRIVER_BUNDLE/Contents/MacOS/LocalRecorderVirtualMic"

"$ROOT_DIR/scripts/build-virtual-mic.sh"

test -d "$DRIVER_BUNDLE"
test -f "$INFO_PLIST"
test -x "$EXECUTABLE"

plutil -lint "$INFO_PLIST"
test "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" = \
    "local.meeting.recorder.virtual-mic"
test "$(plutil -extract CFBundleExecutable raw "$INFO_PLIST")" = \
    "LocalRecorderVirtualMic"
test "$(plutil -extract CFBundlePackageType raw "$INFO_PLIST")" = "BNDL"
test "$(plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")" = "26.0"
test "$(plutil -extract \
    'CFPlugInFactories.9CA4DB46-8093-4A4E-AD1F-0E119FA69B26' \
    raw \
    "$INFO_PLIST")" = "LocalRecorderVirtualMic_Create"
test "$(plutil -extract \
    'CFPlugInTypes.443ABAB8-E7B3-491A-B985-BEB9187030DB.0' \
    raw \
    "$INFO_PLIST")" = "9CA4DB46-8093-4A4E-AD1F-0E119FA69B26"

file "$EXECUTABLE" | grep -q "arm64"
nm -gU "$EXECUTABLE" | grep -q "_LocalRecorderVirtualMic_Create"
BUILD_INFO="$(/usr/bin/xcrun vtool -show-build "$EXECUTABLE")"
print -r -- "$BUILD_INFO" | \
    /usr/bin/grep -Eq '^[[:space:]]*platform MACOS$'
print -r -- "$BUILD_INFO" | \
    /usr/bin/grep -Eq '^[[:space:]]*minos 26\.0$'
codesign --verify --deep --strict "$DRIVER_BUNDLE"

echo "Virtual mic driver bundle contract tests passed"
