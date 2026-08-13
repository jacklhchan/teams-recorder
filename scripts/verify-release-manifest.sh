#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYRING="$ROOT_DIR/Config/release-manifest-keyring-v1.json"
ARGS=()
while [[ $# -gt 0 ]]; do case "$1" in --keyring) [[ $# -ge 2 ]] || exit 64; KEYRING="$2"; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
[[ "$KEYRING" == /* && -f "$KEYRING" && ! -L "$KEYRING" ]] || exit 66
exec /usr/bin/xcrun swift run -c release ReleaseManifestTool verify "${ARGS[@]}" --keyring "$KEYRING"
