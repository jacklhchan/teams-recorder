#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install-virtual-mic.sh"
UNINSTALL_SCRIPT="$ROOT_DIR/scripts/uninstall-virtual-mic.sh"

zsh -n "$INSTALL_SCRIPT"
zsh -n "$UNINSTALL_SCRIPT"

"$ROOT_DIR/scripts/build-virtual-mic.sh" >/dev/null

INSTALL_DRY_RUN="$("$INSTALL_SCRIPT" --dry-run)"
echo "$INSTALL_DRY_RUN" | grep -q \
    "/Library/Audio/Plug-Ins/HAL/LocalRecorderVirtualMic.driver"
echo "$INSTALL_DRY_RUN" | grep -q "reboot required"

UNINSTALL_DRY_RUN="$("$UNINSTALL_SCRIPT" --dry-run)"
echo "$UNINSTALL_DRY_RUN" | grep -q \
    "/Library/Audio/Plug-Ins/HAL/LocalRecorderVirtualMic.driver"
echo "$UNINSTALL_DRY_RUN" | grep -q "reboot required"

if grep -Eiq 'killall[[:space:]]+coreaudiod|password[=:]' \
    "$INSTALL_SCRIPT" "$UNINSTALL_SCRIPT"; then
    echo "Installer scripts must not restart Core Audio or accept passwords" >&2
    exit 1
fi

echo "Virtual mic install script tests passed"
