#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Local Meeting Recorder"
SOURCE_APP="$ROOT_DIR/build/LocalMeetingRecorder.app"
TARGET_APP="/Applications/$APP_NAME.app"

osascript -e 'tell application "Local Meeting Recorder" to quit' 2>/dev/null || true
pkill -f '/Applications/Local Meeting Recorder.app/Contents/MacOS/LocalMeetingRecorder' 2>/dev/null || true
sleep 1

"$ROOT_DIR/scripts/build-app.sh" >/dev/null
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"
codesign --force --deep --sign - "$TARGET_APP"

echo "Installed: $TARGET_APP"
open -R "$TARGET_APP"
