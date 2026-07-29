#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lmr-package.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

APP="$ROOT_DIR/build/Local Meeting Recorder Packaging Test.app"
MOVED="$TEMP_ROOT/Local Meeting Recorder.app"

"$ROOT_DIR/scripts/build-app.sh" \
  --configuration release \
  --version 0.2.0 \
  --build-number 2 \
  --bundle-id local.meeting.recorder.staging \
  --bundle-name "Local Meeting Recorder Packaging Test" \
  --output "$APP" \
  --sign ad-hoc >/dev/null

cp -R "$APP" "$MOVED"

"$ROOT_DIR/scripts/verify-app-bundle.sh" \
  "$MOVED" \
  local.meeting.recorder.staging \
  0.2.0 \
  2 \
  ad-hoc

/bin/bash -n "$MOVED/Contents/Resources/transcribe-openai-compatible.sh"
/usr/bin/python3 -m py_compile \
  "$MOVED/Contents/Resources/openai_asr_longform.py"

if LC_ALL=C /usr/bin/grep -R -n -E \
  '/Users/apple|open -a "oMLX"|OMLX_API_KEY|release-manifest.json' \
  "$MOVED/Contents"; then
  echo "Forbidden checkout/provider string found in bundle." >&2
  exit 1
fi

otool -L "$MOVED/Contents/MacOS/LocalMeetingRecorder" \
  | tail -n +2 \
  | awk '{print $1}' \
  | while IFS= read -r dependency; do
      case "$dependency" in
        /System/Library/*|/usr/lib/*|@rpath/libswift*) ;;
        *) echo "Unexpected dependency: $dependency" >&2; exit 1 ;;
      esac
    done
