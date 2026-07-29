#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || {
  echo "Usage: write-sha256.sh <artifact>" >&2
  exit 64
}

ARTIFACT="$1"
[[ -f "$ARTIFACT" && ! -L "$ARTIFACT" ]] || {
  echo "Artifact is not a regular file." >&2
  exit 66
}

DIRECTORY="$(cd "$(dirname "$ARTIFACT")" && pwd)"
BASENAME="$(basename "$ARTIFACT")"
CHECKSUM="$DIRECTORY/$BASENAME.sha256"
(
  cd "$DIRECTORY"
  /usr/bin/shasum -a 256 "$BASENAME" > "$BASENAME.sha256"
  /usr/bin/shasum -a 256 -c "$BASENAME.sha256" >/dev/null
)
printf '%s\n' "$CHECKSUM"
