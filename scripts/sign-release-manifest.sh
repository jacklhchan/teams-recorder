#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 20 ]] || exit 64
exec /usr/bin/xcrun swift run -c release ReleaseManifestTool sign "$@"
