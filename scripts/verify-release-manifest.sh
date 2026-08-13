#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYRING="$ROOT_DIR/Config/release-manifest-keyring-v1.json"
[[ $# -eq 8 && "$1" == --manifest && "$3" == --signature && "$5" == --zip && "$7" == --minimum-build ]] || exit 64
[[ -f "$KEYRING" && ! -L "$KEYRING" ]] || exit 66
exec /usr/bin/xcrun swift run -c release ReleaseManifestTool verify "$@" --keyring "$KEYRING"
