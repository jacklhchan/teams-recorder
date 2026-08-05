#!/usr/bin/env bash
set -euo pipefail

OWNER_MARKER_VALUE="local.meeting.recorder.build-app.v1"
INSTALL_ROOT="${RECORDER_CLI_INSTALL_ROOT:-}"
LINK_PATH="$INSTALL_ROOT/usr/local/bin/recorderctl"

if [[ $# -ne 1 ]]; then
  echo "Usage: install-recorder-cli.sh /absolute/path/to/Local Meeting Recorder.app" >&2
  exit 64
fi

APP="$1"
if [[ "$APP" != /* || "$APP" != *.app || "$(basename "$APP")" == ".app" ]]; then
  echo "App path must be one absolute .app path." >&2
  exit 64
fi
if [[ -n "$INSTALL_ROOT" && ( "$INSTALL_ROOT" != /* || ! -d "$INSTALL_ROOT" || -L "$INSTALL_ROOT" ) ]]; then
  echo "Install root must be an absolute non-symlinked directory." >&2
  exit 73
fi
if [[ ! -d "$APP" || -L "$APP" ]]; then
  echo "App path must be a non-symlinked directory." >&2
  exit 66
fi

MARKER="$APP/Contents/Resources/.lmr-build-owner"
HELPER="$APP/Contents/Helpers/recorderctl"
if [[ ! -f "$MARKER" || "$(<"$MARKER")" != "$OWNER_MARKER_VALUE" || ! -f "$HELPER" || ! -x "$HELPER" || -L "$HELPER" ]]; then
  echo "App is not an owned Recorder bundle with an executable helper." >&2
  exit 66
fi

BIN_DIR="$(dirname "$LINK_PATH")"
if [[ ! -d "$BIN_DIR" || -L "$BIN_DIR" ]]; then
  echo "CLI destination directory must already exist and must not be a symlink." >&2
  exit 73
fi

is_owned_recorder_helper() {
  local target="$1"
  local target_app
  case "$target" in
    */Contents/Helpers/recorderctl) ;;
    *) return 1 ;;
  esac
  target_app="${target%/Contents/Helpers/recorderctl}"
  [[ "$target_app" == *.app && -d "$target_app" ]] || return 1
  [[ -f "$target_app/Contents/Resources/.lmr-build-owner" ]] || return 1
  [[ "$(<"$target_app/Contents/Resources/.lmr-build-owner")" == "$OWNER_MARKER_VALUE" ]] || return 1
  [[ -f "$target" && -x "$target" ]]
}

if [[ -e "$LINK_PATH" || -L "$LINK_PATH" ]]; then
  if [[ ! -L "$LINK_PATH" ]]; then
    echo "Refusing to replace a non-symlink CLI destination." >&2
    exit 73
  fi
  EXISTING_TARGET="$(
    /usr/bin/python3 - "$LINK_PATH" <<'PY'
import sys
from pathlib import Path

try:
    print(Path(sys.argv[1]).resolve(strict=True))
except (OSError, RuntimeError):
    raise SystemExit(73)
PY
  )" || {
    echo "Refusing to replace an unresolved CLI symlink." >&2
    exit 73
  }
  if ! is_owned_recorder_helper "$EXISTING_TARGET"; then
    echo "Refusing to replace a symlink not owned by a Recorder app helper." >&2
    exit 73
  fi
fi

/bin/ln -sfn "$HELPER" "$LINK_PATH"
printf '%s\n' "$LINK_PATH"
