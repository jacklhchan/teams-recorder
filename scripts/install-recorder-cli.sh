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

LINK_PATH="$(
  /usr/bin/python3 - "$INSTALL_ROOT" <<'PY'
import stat
import sys
from pathlib import Path

root_argument = sys.argv[1]
root = Path(root_argument) if root_argument else Path("/")
try:
    canonical_root = root.resolve(strict=True)
    current = root
    for component in ("usr", "local", "bin"):
        current /= component
        if stat.S_ISLNK(current.lstat().st_mode) or not current.is_dir():
            raise OSError
    canonical_bin = current.resolve(strict=True)
except (OSError, RuntimeError):
    print(
        "CLI destination directory must exist without symlink components.",
        file=sys.stderr,
    )
    raise SystemExit(73)

expected_bin = canonical_root / "usr" / "local" / "bin"
if canonical_bin != expected_bin:
    print("CLI destination escapes the install root.", file=sys.stderr)
    raise SystemExit(73)
print(canonical_bin / "recorderctl")
PY
)"

# The destination parent is a trust boundary: it must not be mutated by a
# hostile same-UID process during this short check/unlink window. Darwin has no
# narrow pathname API that conditionally unlinks only a previously seen inode.
# After unlink, symlink(2) is deliberately exclusive, so a late file, symlink,
# or directory is preserved instead of being force-clobbered or used as a target.
/usr/bin/python3 - "$LINK_PATH" "$HELPER" "$OWNER_MARKER_VALUE" "$INSTALL_ROOT" <<'PY'
import os
import stat
import sys
from pathlib import Path

link = Path(sys.argv[1])
helper_argument = sys.argv[2]
helper = Path(helper_argument)
owner_marker_value = sys.argv[3]
install_root = sys.argv[4]


def refuse(message):
    print(message, file=sys.stderr)
    raise SystemExit(73)


try:
    helper_target = helper.resolve(strict=True)
except (OSError, RuntimeError):
    refuse("Recorder helper cannot be resolved.")

removed_existing = False
try:
    checked = os.lstat(link)
except FileNotFoundError:
    checked = None
except OSError:
    refuse("Cannot inspect the CLI destination.")

if checked is not None:
    if not stat.S_ISLNK(checked.st_mode):
        refuse("Refusing to replace a non-symlink CLI destination.")
    try:
        existing_target = link.resolve(strict=True)
    except (OSError, RuntimeError):
        refuse("Refusing to replace an unresolved CLI symlink.")

    existing_app = existing_target.parent.parent.parent
    existing_marker = existing_app / "Contents/Resources/.lmr-build-owner"
    if (
        existing_target.name != "recorderctl"
        or existing_target.parent.name != "Helpers"
        or existing_target.parent.parent.name != "Contents"
        or existing_app.suffix != ".app"
        or not existing_app.is_dir()
        or not existing_target.is_file()
        or not os.access(existing_target, os.X_OK)
    ):
        refuse("Refusing to replace a symlink not owned by a Recorder app helper.")
    try:
        marker_value = existing_marker.read_text(encoding="utf-8")
    except OSError:
        refuse("Refusing to replace a symlink not owned by a Recorder app helper.")
    if marker_value != owner_marker_value:
        refuse("Refusing to replace a symlink not owned by a Recorder app helper.")

    if existing_target == helper_target:
        raise SystemExit(0)

    try:
        current = os.lstat(link)
    except OSError:
        refuse("CLI destination changed during validation.")
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_ctime_ns,
    )
    if identity(current) != identity(checked):
        refuse("CLI destination changed during validation.")
    try:
        os.unlink(link)
    except OSError:
        refuse("Could not remove the validated Recorder CLI symlink.")
    removed_existing = True

# Deterministic test seam, accepted only under a redirected test install root.
test_source = os.environ.get("RECORDER_CLI_TEST_POST_UNLINK_SOURCE")
if test_source and removed_existing:
    if not install_root:
        refuse("The post-unlink test seam requires a redirected install root.")
    try:
        os.link(test_source, link, follow_symlinks=False)
    except OSError:
        refuse("Could not create the post-unlink test replacement.")

try:
    os.symlink(helper_argument, link)
except FileExistsError:
    refuse("Refusing to replace a CLI destination created during installation.")
except OSError:
    refuse("Could not create the Recorder CLI symlink.")
PY
printf '%s\n' "$LINK_PATH"
