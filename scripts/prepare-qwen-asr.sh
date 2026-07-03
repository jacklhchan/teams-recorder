#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ASR_WORKSPACE="${ASR_WORKSPACE:-/Users/apple/Documents/AIA ASR}"
PYTHON="${PYTHON:-/usr/bin/python3}"
OMLX_SETTINGS="${OMLX_SETTINGS:-${HOME}/.omlx/settings.json}"
OMLX_URL="${OMLX_URL:-http://127.0.0.1:8000}"
OMLX_ASR_MODEL="${OMLX_ASR_MODEL:-mlx-community--Qwen3-ASR-1.7B-4bit}"
LOG_OUTPUT="${ASR_WORKSPACE}/qwen_asr_model_prepare.log"

mkdir -p "$ASR_WORKSPACE"
: > "$LOG_OUTPUT"
exec > >(tee -a "$LOG_OUTPUT") 2>&1

echo "LOG_PATH=${LOG_OUTPUT}"
open -a "oMLX" >/dev/null 2>&1 || true

API_KEY="$("$PYTHON" - "$OMLX_SETTINGS" <<'PY'
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
if not settings.exists():
    raise SystemExit("")
data = json.loads(settings.read_text())
print(data.get("auth", {}).get("api_key", ""))
PY
)"

if [[ -z "$API_KEY" ]]; then
  echo "Missing oMLX API key in ${OMLX_SETTINGS}" >&2
  exit 69
fi

echo "Checking oMLX ASR server at ${OMLX_URL}..."
for attempt in {1..30}; do
  RESPONSE="$(curl -sS --max-time 5 -H "Authorization: Bearer ${API_KEY}" "${OMLX_URL}/v1/models" 2>&1 || true)"
  if echo "$RESPONSE" | grep -q "\"id\":\"${OMLX_ASR_MODEL}\""; then
    echo "MODEL_READY=${OMLX_ASR_MODEL}"
    echo "oMLX ASR server ready"
    exit 0
  fi
  echo "Waiting for oMLX ASR model (${attempt}/30)..."
  sleep 2
done

echo "oMLX ASR model not available: ${OMLX_ASR_MODEL}" >&2
echo "$RESPONSE" >&2
exit 70
