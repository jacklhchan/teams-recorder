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

RAW_OUTPUT="${OUTPUT_FOLDER}/transcript_qwen3_asr_1_7b_8bit_${LANGUAGE}.txt"
TRAD_OUTPUT="${OUTPUT_FOLDER}/transcript_qwen3_asr_1_7b_8bit_${LANGUAGE}_trad.txt"
JSON_OUTPUT="${OUTPUT_FOLDER}/transcript_qwen3_asr_1_7b_8bit_${LANGUAGE}.json"
LOG_OUTPUT="${OUTPUT_FOLDER}/transcription_qwen_asr.log"

: > "$LOG_OUTPUT"
exec > >(tee -a "$LOG_OUTPUT") 2>&1

echo "LOG_PATH=${LOG_OUTPUT}"
open -a "oMLX" >/dev/null 2>&1 || true

if [[ ! -f "$AUDIO_FILE" ]]; then
  echo "Missing audio file: $AUDIO_FILE" >&2
  exit 66
fi
if [[ ! -x "$PYTHON" ]]; then
  echo "Missing ASR Python environment: $PYTHON" >&2
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

echo "Checking oMLX ASR model..."
MODELS_RESPONSE="$(curl -sS --max-time 10 -H "Authorization: Bearer ${API_KEY}" "${OMLX_URL}/v1/models" 2>&1 || true)"
if ! echo "$MODELS_RESPONSE" | grep -q "\"id\":\"${OMLX_ASR_MODEL}\""; then
  echo "oMLX ASR model is not ready: ${OMLX_ASR_MODEL}" >&2
  echo "$MODELS_RESPONSE" >&2
  exit 69
fi

echo "Transcribing with oMLX API model ${OMLX_ASR_MODEL}..."
HTTP_STATUS="$(
  curl -sS --max-time 7200 \
    -H "Authorization: Bearer ${API_KEY}" \
    -o "$JSON_OUTPUT" \
    -w "%{http_code}" \
    "${OMLX_URL}/v1/audio/transcriptions" \
    -F "file=@${AUDIO_FILE}" \
    -F "model=${OMLX_ASR_MODEL}" \
    -F "language=${LANGUAGE}" \
    -F "response_format=json"
)"

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "oMLX transcription failed with HTTP ${HTTP_STATUS}" >&2
  cat "$JSON_OUTPUT" >&2 || true
  exit 70
fi

"$PYTHON" - "$JSON_OUTPUT" "$RAW_OUTPUT" "$TRAD_OUTPUT" <<'PY'
from pathlib import Path
import json
import sys

json_path = Path(sys.argv[1])
raw_path = Path(sys.argv[2])
trad_path = Path(sys.argv[3])
data = json.loads(json_path.read_text(encoding="utf-8", errors="ignore"))
text = data.get("text", "")
raw_path.write_text(text, encoding="utf-8")

try:
    from opencc import OpenCC
except Exception:
    OpenCC = None

if OpenCC is not None:
    text = OpenCC("s2hk").convert(text)
trad_path.write_text(text, encoding="utf-8")
PY

if [[ ! -f "$TRAD_OUTPUT" ]]; then
  echo "ASR completed but transcript was not created: $TRAD_OUTPUT" >&2
  exit 70
fi

echo "TRANSCRIPT_PATH=${TRAD_OUTPUT}"
