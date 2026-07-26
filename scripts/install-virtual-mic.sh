#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/build/LocalRecorderVirtualMic.driver"
TARGET="/Library/Audio/Plug-Ins/HAL/LocalRecorderVirtualMic.driver"
EXPECTED_BUNDLE_ID="local.meeting.recorder.virtual-mic"
BACKUP_ROOT="/Library/Application Support/Local Meeting Recorder/Driver Backups"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--dry-run]" >&2
    exit 64
fi

"$ROOT_DIR/scripts/build-virtual-mic.sh" >/dev/null

if [[ -L "$SOURCE" || ! -d "$SOURCE" ]]; then
    echo "Refusing unexpected driver source: $SOURCE" >&2
    exit 1
fi

SOURCE_ID="$(plutil -extract CFBundleIdentifier raw "$SOURCE/Contents/Info.plist")"
if [[ "$SOURCE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Unexpected driver bundle identifier: $SOURCE_ID" >&2
    exit 1
fi
codesign --verify --deep --strict "$SOURCE"

if [[ "$DRY_RUN" == true ]]; then
    echo "Would install: $SOURCE"
    echo "Target: $TARGET"
    echo "No audio service will be restarted; reboot required after installation."
    exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
STAGING="/Library/Audio/Plug-Ins/HAL/.LocalRecorderVirtualMic.driver.staging-$STAMP-$$"
BACKUP="$BACKUP_ROOT/LocalRecorderVirtualMic-$STAMP.driver"

echo "Installing Local Recorder Virtual Mic requires administrator authentication."
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 755 \
    "/Library/Audio/Plug-Ins/HAL" \
    "$BACKUP_ROOT"
/usr/bin/sudo /usr/bin/ditto "$SOURCE" "$STAGING"
/usr/bin/sudo /usr/sbin/chown -R root:wheel "$STAGING"
/usr/bin/sudo /bin/chmod -R u=rwX,go=rX "$STAGING"
/usr/bin/sudo /usr/bin/codesign --verify --deep --strict "$STAGING"

if [[ -e "$TARGET" ]]; then
    INSTALLED_ID="$(plutil -extract CFBundleIdentifier raw "$TARGET/Contents/Info.plist")"
    if [[ "$INSTALLED_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
        echo "Refusing to replace unexpected bundle at $TARGET" >&2
        exit 1
    fi
    /usr/bin/sudo /bin/mv "$TARGET" "$BACKUP"
fi

/usr/bin/sudo /bin/mv "$STAGING" "$TARGET"
/usr/bin/sudo /usr/bin/codesign --verify --deep --strict "$TARGET"

echo "Installed: $TARGET"
echo "A reboot is required before macOS and Teams can enumerate the device."
