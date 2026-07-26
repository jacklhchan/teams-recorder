#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER_DIR="$ROOT_DIR/Driver/LocalRecorderVirtualMic"
BUILD_DIR="$ROOT_DIR/build"
BUNDLE="$BUILD_DIR/LocalRecorderVirtualMic.driver"
CONTENTS="$BUNDLE/Contents"
EXECUTABLE="$CONTENTS/MacOS/LocalRecorderVirtualMic"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS"

cp "$DRIVER_DIR/Info.plist" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"

xcrun clang \
    -arch arm64 \
    -std=c11 \
    -O2 \
    -fblocks \
    -fPIC \
    -fvisibility=hidden \
    -bundle \
    -mmacosx-version-min=15.0 \
    "$DRIVER_DIR/LocalRecorderVirtualMic.c" \
    -Wl,-exported_symbol,_LocalRecorderVirtualMic_Create \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$EXECUTABLE"

codesign \
    --force \
    --sign - \
    --timestamp=none \
    "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

echo "$BUNDLE"
