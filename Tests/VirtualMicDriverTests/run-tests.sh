#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/virtual-mic-driver-tests"
TEST_BINARY="$BUILD_DIR/VirtualMicDriverContractTests"

mkdir -p "$BUILD_DIR"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-unused-parameter \
    "$ROOT_DIR/Tests/VirtualMicDriverTests/DriverContractTests.c" \
    "$ROOT_DIR/Driver/LocalRecorderVirtualMic/LocalRecorderVirtualMic.c" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$TEST_BINARY"

"$TEST_BINARY"
