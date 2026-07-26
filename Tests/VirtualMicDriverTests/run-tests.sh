#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/virtual-mic-driver-tests"
TEST_BINARY="$BUILD_DIR/VirtualMicDriverContractTests"
TEST_OBJECT="$BUILD_DIR/DriverContractTests.o"
DRIVER_OBJECT="$BUILD_DIR/LocalRecorderVirtualMic.o"
BRIDGE_OBJECT="$BUILD_DIR/VirtualMicBridge.o"

mkdir -p "$BUILD_DIR"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-unused-parameter \
    -I "$ROOT_DIR/Sources/VirtualMicBridge/include" \
    -c \
    "$ROOT_DIR/Tests/VirtualMicDriverTests/DriverContractTests.c" \
    -o "$TEST_OBJECT"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-unused-parameter \
    -I "$ROOT_DIR/Sources/VirtualMicBridge/include" \
    -c \
    "$ROOT_DIR/Driver/LocalRecorderVirtualMic/LocalRecorderVirtualMic.c" \
    -o "$DRIVER_OBJECT"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun clang++ \
    -std=c++17 \
    -Wall \
    -Wextra \
    -Werror \
    -I "$ROOT_DIR/Sources/VirtualMicBridge/include" \
    -c \
    "$ROOT_DIR/Sources/VirtualMicBridge/VirtualMicBridge.cpp" \
    -o "$BRIDGE_OBJECT"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun clang++ \
    "$TEST_OBJECT" \
    "$DRIVER_OBJECT" \
    "$BRIDGE_OBJECT" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$TEST_BINARY"

"$TEST_BINARY"
