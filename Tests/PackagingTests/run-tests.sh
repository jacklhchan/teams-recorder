#!/usr/bin/env bash
set -euo pipefail

validate_macho_dependencies() {
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *) echo "Unexpected dependency: $dependency" >&2; return 1 ;;
    esac
  done
}

validate_macos_26_binary() {
  local binary="$1"
  local build_info
  build_info="$(/usr/bin/xcrun vtool -show-build "$binary")"

  if ! printf '%s\n' "$build_info" \
    | /usr/bin/grep -Eq '^[[:space:]]*platform MACOS$'; then
    echo "Expected a macOS Mach-O build command: $binary" >&2
    return 1
  fi
  if ! printf '%s\n' "$build_info" \
    | /usr/bin/grep -Eq '^[[:space:]]*minos 26\.0$'; then
    echo "Expected Mach-O minimum macOS 26.0: $binary" >&2
    return 1
  fi
}

main() {
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

validate_macos_26_binary "$MOVED/Contents/MacOS/LocalMeetingRecorder"

test ! -e "$MOVED/Contents/Resources/transcribe-openai-compatible.sh"
test ! -e "$MOVED/Contents/Resources/transcribe-qwen-asr.sh"
test ! -e "$MOVED/Contents/Resources/openai_asr_longform.py"

if LC_ALL=C /usr/bin/grep -R -n -E \
  '/Users/apple|open -a "oMLX"|OMLX_API_KEY|release-manifest.json' \
  "$MOVED/Contents"; then
  echo "Forbidden checkout/provider string found in bundle." >&2
  exit 1
fi

/usr/bin/otool -L "$MOVED/Contents/MacOS/LocalMeetingRecorder" \
  | /usr/bin/tail -n +2 \
  | /usr/bin/awk '{print $1}' \
  | validate_macho_dependencies
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
