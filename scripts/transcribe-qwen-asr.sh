#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: transcribe-qwen-asr.sh <audio-file> <output-folder>" >&2
  exit 64
fi

AUDIO_FILE="$1"
OUTPUT_FOLDER="$2"
ASR_WORKSPACE="${ASR_WORKSPACE:-/Users/apple/Documents/AIA ASR}"
PYTHON="${PYTHON:-${ASR_WORKSPACE}/.venv/bin/python}"
MODEL="${MODEL:-${ASR_WORKSPACE}/models/Qwen3-ASR-1.7B-bf16}"
LANGUAGE="${LANGUAGE:-yue}"
CHUNK_DURATION="${CHUNK_DURATION:-30}"
MAX_TOKENS="${MAX_TOKENS:-50000}"
CONTEXT="${CONTEXT:-Hong Kong Cantonese meeting recording, business discussion, mixed Cantonese and English terms}"

RAW_OUTPUT_BASE="${OUTPUT_FOLDER}/transcript_qwen3_asr_1_7b_bf16_${LANGUAGE}"
RAW_OUTPUT="${RAW_OUTPUT_BASE}.txt"
TRAD_OUTPUT="${OUTPUT_FOLDER}/transcript_qwen3_asr_1_7b_bf16_${LANGUAGE}_trad.txt"

open -a "oMLX" >/dev/null 2>&1 || true

if [[ ! -f "$AUDIO_FILE" ]]; then
  echo "Missing audio file: $AUDIO_FILE" >&2
  exit 66
fi
if [[ ! -x "$PYTHON" ]]; then
  echo "Missing ASR Python environment: $PYTHON" >&2
  exit 69
fi
if [[ ! -f "${MODEL}/model.safetensors" ]]; then
  echo "Missing Qwen ASR model: ${MODEL}/model.safetensors" >&2
  exit 69
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Missing ffmpeg. Install it with Homebrew." >&2
  exit 69
fi

WORKDIR="$(mktemp -d -t recorder-qwen-asr.XXXXXX)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

MONO_AUDIO="${WORKDIR}/input_mono16k.wav"

echo "Opening oMLX and loading Qwen ASR model..."
echo "Normalizing audio to 16 kHz mono..."
ffmpeg -y -hide_banner -loglevel error -i "$AUDIO_FILE" -ac 1 -ar 16000 "$MONO_AUDIO"

echo "Transcribing with Qwen3-ASR-1.7B-bf16..."
"$PYTHON" -m mlx_audio.stt.generate \
  --model "$MODEL" \
  --audio "$MONO_AUDIO" \
  --output-path "$RAW_OUTPUT_BASE" \
  --format txt \
  --language "$LANGUAGE" \
  --context "$CONTEXT" \
  --chunk-duration "$CHUNK_DURATION" \
  --max-tokens "$MAX_TOKENS"

if [[ ! -f "$RAW_OUTPUT" ]]; then
  echo "ASR completed but transcript was not created: $RAW_OUTPUT" >&2
  exit 70
fi

echo "Converting transcript to Traditional Chinese..."
"$PYTHON" - "$RAW_OUTPUT" "$TRAD_OUTPUT" <<'PY'
from pathlib import Path
import sys
try:
    from opencc import OpenCC
except Exception:
    OpenCC = None

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text(encoding="utf-8", errors="ignore")
if OpenCC is not None:
    text = OpenCC("s2hk").convert(text)
dst.write_text(text, encoding="utf-8")
PY

echo "TRANSCRIPT_PATH=${TRAD_OUTPUT}"
