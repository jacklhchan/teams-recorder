#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_EXECUTABLE="LocalMeetingRecorder"
CONFIGURATION="debug"
VERSION="0.1.0"
BUILD_NUMBER="1"
BUNDLE_ID="local.meeting.recorder.staging"
BUNDLE_NAME="Local Meeting Recorder Staging"
OUTPUT="$ROOT_DIR/build/Local Meeting Recorder Staging.app"
SIGN_MODE="ad-hoc"
OWNER_MARKER_NAME=".lmr-build-owner"
OWNER_MARKER_VALUE="local.meeting.recorder.build-app.v1"

usage() {
  cat >&2 <<'USAGE'
Usage: build-app.sh [options]
  --configuration debug|release
  --version X.Y.Z
  --build-number N
  --bundle-id IDENTIFIER
  --bundle-name NAME
  --output PATH
  --sign ad-hoc|none
USAGE
}

die_usage() {
  echo "$1" >&2
  usage
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) [[ $# -ge 2 ]] || die_usage "Missing configuration"; CONFIGURATION="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die_usage "Missing version"; VERSION="$2"; shift 2 ;;
    --build-number) [[ $# -ge 2 ]] || die_usage "Missing build number"; BUILD_NUMBER="$2"; shift 2 ;;
    --bundle-id) [[ $# -ge 2 ]] || die_usage "Missing bundle identifier"; BUNDLE_ID="$2"; shift 2 ;;
    --bundle-name) [[ $# -ge 2 ]] || die_usage "Missing bundle name"; BUNDLE_NAME="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || die_usage "Missing output path"; OUTPUT="$2"; shift 2 ;;
    --sign) [[ $# -ge 2 ]] || die_usage "Missing sign mode"; SIGN_MODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "Unknown option: $1" ;;
  esac
done

[[ "$CONFIGURATION" == "debug" || "$CONFIGURATION" == "release" ]] || die_usage "Configuration must be debug or release."
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die_usage "Version must contain two or three numeric components."
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die_usage "Build number must be a positive integer."
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die_usage "Bundle identifier is invalid."
[[ -n "$BUNDLE_NAME" ]] || die_usage "Bundle name cannot be empty."
[[ "$SIGN_MODE" == "ad-hoc" || "$SIGN_MODE" == "none" ]] || die_usage "Sign mode must be ad-hoc or none."
[[ "$OUTPUT" == *.app ]] || die_usage "Output path must end in .app."
[[ "$(basename "$OUTPUT")" != ".app" ]] || die_usage "Output app name cannot be empty."
[[ "$OUTPUT" != "/" ]] || die_usage "Output path cannot be the filesystem root."

OUTPUT="$(
  /usr/bin/python3 - "$OUTPUT" <<'PY'
import os
import sys
from pathlib import Path

candidate = Path(os.path.abspath(os.path.expanduser(sys.argv[1])))
for component in (candidate, *candidate.parents):
    if component.is_symlink():
        print("Output path cannot contain symbolic links.", file=sys.stderr)
        raise SystemExit(73)
print(candidate)
PY
)"

if [[ -e "$OUTPUT" ]]; then
  MARKER="$OUTPUT/Contents/Resources/$OWNER_MARKER_NAME"
  if [[ ! -d "$OUTPUT" || ! -f "$MARKER" || "$(<"$MARKER")" != "$OWNER_MARKER_VALUE" ]]; then
    echo "Refusing to replace an output not owned by build-app.sh." >&2
    exit 73
  fi
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT_DIR"
echo "Building $CONFIGURATION app binary" >&2
swift build -c "$CONFIGURATION" --arch arm64 >&2
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
BINARY_PATH="$BIN_DIR/$APP_EXECUTABLE"
[[ -x "$BINARY_PATH" ]] || {
  echo "Built executable not found: $BINARY_PATH" >&2
  exit 70
}

OUTPUT_PARENT="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT"
TEMP_ROOT="$(mktemp -d "$OUTPUT_PARENT/.lmr-build.XXXXXX")"
TEMP_OUTPUT="$TEMP_ROOT/$(basename "$OUTPUT")"
PREVIOUS_OUTPUT=""
cleanup() {
  if [[ -n "$PREVIOUS_OUTPUT" && -e "$PREVIOUS_OUTPUT" && ! -e "$OUTPUT" ]]; then
    mv "$PREVIOUS_OUTPUT" "$OUTPUT"
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

CONTENTS_DIR="$TEMP_OUTPUT/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
printf '%s' "$OWNER_MARKER_VALUE" > "$RESOURCES_DIR/$OWNER_MARKER_NAME"

cp "$BINARY_PATH" "$MACOS_DIR/$APP_EXECUTABLE"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/scripts/transcribe-openai-compatible.sh" "$RESOURCES_DIR/transcribe-openai-compatible.sh"
cp "$ROOT_DIR/scripts/transcribe-qwen-asr.sh" "$RESOURCES_DIR/transcribe-qwen-asr.sh"
cp "$ROOT_DIR/scripts/openai_asr_longform.py" "$RESOURCES_DIR/openai_asr_longform.py"
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
chmod +x "$RESOURCES_DIR/transcribe-openai-compatible.sh"
chmod +x "$RESOURCES_DIR/transcribe-qwen-asr.sh"
chmod +x "$RESOURCES_DIR/openai_asr_longform.py"

PLIST="$CONTENTS_DIR/Info.plist"
/usr/bin/python3 - "$PLIST" "$BUNDLE_ID" "$BUNDLE_NAME" "$VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib
import sys
from pathlib import Path

path, bundle_id, bundle_name, version, build = sys.argv[1:]
document = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "LocalMeetingRecorder",
    "CFBundleIdentifier": bundle_id,
    "CFBundleIconFile": "AppIcon",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": bundle_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "LSMinimumSystemVersion": "15.0",
    "NSHighResolutionCapable": True,
    "NSMicrophoneUsageDescription": "Local Meeting Recorder needs microphone access to record your selected mic input.",
    "NSDownloadsFolderUsageDescription": "Local Meeting Recorder reads and saves recordings in your Downloads folder.",
    "NSScreenCaptureUsageDescription": "Local Meeting Recorder captures system or selected app audio without changing your Mac output.",
}
with Path(path).open("wb") as stream:
    plistlib.dump(document, stream, sort_keys=True)
PY
plutil -lint "$PLIST" >&2

if [[ "$SIGN_MODE" == "ad-hoc" ]]; then
  ENTITLEMENTS="$ROOT_DIR/Config/LocalMeetingRecorder.entitlements"
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$MACOS_DIR/$APP_EXECUTABLE"
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$TEMP_OUTPUT"
  codesign --verify --deep --strict "$TEMP_OUTPUT"
else
  codesign --remove-signature "$MACOS_DIR/$APP_EXECUTABLE" >/dev/null 2>&1 || true
  if codesign -dv "$TEMP_OUTPUT" >/dev/null 2>&1; then
    echo "Unsigned staging bundle unexpectedly has a signature." >&2
    exit 70
  fi
fi

if [[ -e "$OUTPUT" ]]; then
  PREVIOUS_OUTPUT="${OUTPUT}.previous-$$"
  [[ ! -e "$PREVIOUS_OUTPUT" && ! -L "$PREVIOUS_OUTPUT" ]] || {
    echo "Temporary backup path already exists." >&2
    exit 73
  }
  mv "$OUTPUT" "$PREVIOUS_OUTPUT"
fi
mv "$TEMP_OUTPUT" "$OUTPUT"
if [[ -n "$PREVIOUS_OUTPUT" ]]; then
  rm -rf "$PREVIOUS_OUTPUT"
  PREVIOUS_OUTPUT=""
fi
printf '%s\n' "$OUTPUT"
