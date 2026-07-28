#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

if [[ $# -lt 2 ]]; then
  echo "Usage: transcribe-qwen-asr.sh <audio-file> <output-folder>" >&2
  exit 64
fi

AUDIO_FILE="$1"
OUTPUT_FOLDER="$2"
ASR_WORKSPACE="${ASR_WORKSPACE:-/Users/apple/Documents/AIA ASR}"
PYTHON="${PYTHON:-${ASR_WORKSPACE}/.venv/bin/python}"
OMLX_SETTINGS="${OMLX_SETTINGS:-${HOME}/.omlx/settings.json}"
OMLX_URL="${OMLX_URL:-http://127.0.0.1:8000}"
OMLX_ASR_MODEL="${OMLX_ASR_MODEL:-mlx-community--Qwen3-ASR-1.7B-4bit}"
LANGUAGE="${LANGUAGE:-yue}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LONGFORM_HELPER="${LONGFORM_HELPER:-${SCRIPT_DIR}/qwen_asr_longform.py}"
PUBLISH_MODE="${TRANSCRIPTION_PUBLISH_MODE:-replace}"
OMLX_LAUNCH_APP="${OMLX_LAUNCH_APP:-1}"

LOG_OUTPUT="${OUTPUT_FOLDER}/transcription_qwen_asr.log"

: > "$LOG_OUTPUT"

echo "LOG_PATH=${LOG_OUTPUT}" | tee -a "$LOG_OUTPUT"
if [[ "$OMLX_LAUNCH_APP" == "1" ]]; then
  open -a "oMLX" >/dev/null 2>&1 || true
fi

if [[ ! -f "$AUDIO_FILE" ]]; then
  echo "Missing audio file: $AUDIO_FILE" >&2
  exit 66
fi
if [[ ! -x "$PYTHON" ]]; then
  echo "Missing ASR Python environment: $PYTHON" >&2
  exit 69
fi
if [[ ! -f "$LONGFORM_HELPER" ]]; then
  echo "Missing long-form transcription helper: $LONGFORM_HELPER" >&2
  exit 69
fi

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

set +e
OMLX_API_KEY="$API_KEY" "$PYTHON" "$LONGFORM_HELPER" \
    --audio "$AUDIO_FILE" \
    --output-folder "$OUTPUT_FOLDER" \
    --omlx-url "$OMLX_URL" \
    --model "$OMLX_ASR_MODEL" \
    --language "$LANGUAGE" \
    --publish-mode "$PUBLISH_MODE" \
    2>&1 | tee -a "$LOG_OUTPUT"
HELPER_STATUS="${PIPESTATUS[0]}"
set -e
exit "$HELPER_STATUS"
