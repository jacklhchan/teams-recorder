#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
if [[ $# -lt 2 ]]; then
  echo "Usage: transcribe-openai-compatible.sh <audio-file> <output-folder>" >&2
  exit 64
fi
AUDIO_FILE="$1"
OUTPUT_FOLDER="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-/usr/bin/python3}"
HELPER="${LONGFORM_HELPER:-${SCRIPT_DIR}/openai_asr_longform.py}"
PUBLISH_MODE="${TRANSCRIPTION_PUBLISH_MODE:-replace}"
LOG_OUTPUT="${OUTPUT_FOLDER}/transcription.log"
if [[ ! -f "$AUDIO_FILE" ]]; then echo "Missing audio file: $AUDIO_FILE" >&2; exit 66; fi
if [[ ! -x "$PYTHON" ]]; then echo "Missing Python runtime: $PYTHON" >&2; exit 69; fi
if [[ ! -f "$HELPER" ]]; then echo "Missing long-form transcription helper: $HELPER" >&2; exit 69; fi
mkdir -p "$OUTPUT_FOLDER"
exec "$PYTHON" "$HELPER" --audio "$AUDIO_FILE" --output-folder "$OUTPUT_FOLDER" --publish-mode "$PUBLISH_MODE" --log "$LOG_OUTPUT"
