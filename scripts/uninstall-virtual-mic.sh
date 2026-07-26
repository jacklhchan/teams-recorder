#!/bin/zsh
set -euo pipefail

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

if [[ "$DRY_RUN" == true ]]; then
    echo "Would remove only: $TARGET"
    echo "The bundle would be retained under: $BACKUP_ROOT"
    echo "No audio service will be restarted; reboot required after removal."
    exit 0
fi

if [[ ! -e "$TARGET" ]]; then
    echo "Local Recorder Virtual Mic is not installed."
    exit 0
fi

INSTALLED_ID="$(plutil -extract CFBundleIdentifier raw "$TARGET/Contents/Info.plist")"
if [[ "$INSTALLED_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Refusing to remove unexpected bundle at $TARGET" >&2
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/LocalRecorderVirtualMic-removed-$STAMP.driver"

echo "Quit the recorder, Teams, and other audio clients before continuing."
echo "Removal requires administrator authentication."
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 755 "$BACKUP_ROOT"
/usr/bin/sudo /bin/mv "$TARGET" "$BACKUP"

echo "Moved the driver to: $BACKUP"
echo "A reboot is required before macOS fully unloads the device."
