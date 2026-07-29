#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER_DIR="$ROOT_DIR/Driver/LocalRecorderVirtualMic"
BUILD_DIR="$ROOT_DIR/build"
BUNDLE="$BUILD_DIR/LocalRecorderVirtualMic.driver"
CONTENTS="$BUNDLE/Contents"
EXECUTABLE="$CONTENTS/MacOS/LocalRecorderVirtualMic"
OBJECT_DIR="$BUILD_DIR/virtual-mic-driver-objects"
DRIVER_OBJECT="$OBJECT_DIR/LocalRecorderVirtualMic.o"
BRIDGE_OBJECT="$OBJECT_DIR/VirtualMicBridge.o"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
mkdir -p "$OBJECT_DIR"

cp "$DRIVER_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$DRIVER_DIR/LICENSE-Apple-Sample.txt" "$CONTENTS/Resources/LICENSE-Apple-Sample.txt"
plutil -lint "$CONTENTS/Info.plist"

xcrun clang \
    -arch arm64 \
    -std=c11 \
    -O2 \
    -fblocks \
    -fPIC \
    -fvisibility=hidden \
    -mmacosx-version-min=15.0 \
    -I "$ROOT_DIR/Sources/VirtualMicBridge/include" \
    -c \
    "$DRIVER_DIR/LocalRecorderVirtualMic.c" \
    -o "$DRIVER_OBJECT"

xcrun clang++ \
    -arch arm64 \
    -std=c++17 \
    -O2 \
    -fPIC \
    -fvisibility=hidden \
    -mmacosx-version-min=15.0 \
    -I "$ROOT_DIR/Sources/VirtualMicBridge/include" \
    -c \
    "$ROOT_DIR/Sources/VirtualMicBridge/VirtualMicBridge.cpp" \
    -o "$BRIDGE_OBJECT"

xcrun clang++ \
    -arch arm64 \
    -bundle \
    -mmacosx-version-min=15.0 \
    "$DRIVER_OBJECT" \
    "$BRIDGE_OBJECT" \
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
