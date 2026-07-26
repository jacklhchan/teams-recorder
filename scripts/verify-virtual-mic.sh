#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/virtual-mic-hal-probe"
PROBE="$BUILD_DIR/VirtualMicHALProbe"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$BUILD_DIR"

xcrun clang \
    -arch arm64 \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    "$ROOT_DIR/Tests/VirtualMicDriverTests/HALProbe.c" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$PROBE"

"$PROBE"
