#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ASR_WORKSPACE="${ASR_WORKSPACE:-/Users/apple/Documents/AIA ASR}"
PYTHON="${PYTHON:-${ASR_WORKSPACE}/.venv/bin/python}"
MODEL_REPO="${MODEL_REPO:-aufklarer/Qwen3-ASR-1.7B-MLX-8bit}"
MODEL_DIR="${MODEL_DIR:-${ASR_WORKSPACE}/models/Qwen3-ASR-1.7B-MLX-8bit}"
LOG_OUTPUT="${ASR_WORKSPACE}/qwen_asr_model_prepare.log"

mkdir -p "$ASR_WORKSPACE" "$MODEL_DIR"
: > "$LOG_OUTPUT"
exec > >(tee -a "$LOG_OUTPUT") 2>&1

echo "LOG_PATH=${LOG_OUTPUT}"

if [[ ! -x "$PYTHON" ]]; then
  echo "Missing ASR Python environment: $PYTHON" >&2
  exit 69
fi

if [[ -f "${MODEL_DIR}/model.safetensors" ]]; then
  echo "MODEL_READY=${MODEL_DIR}"
  echo "Qwen ASR model is already prepared."
  exit 0
fi

echo "Downloading ${MODEL_REPO} to ${MODEL_DIR}..."
"$PYTHON" - "$MODEL_REPO" "$MODEL_DIR" <<'PY'
from pathlib import Path
import sys
from huggingface_hub import snapshot_download

repo_id = sys.argv[1]
local_dir = Path(sys.argv[2])
local_dir.mkdir(parents=True, exist_ok=True)
snapshot_download(
    repo_id=repo_id,
    local_dir=str(local_dir),
)
PY

if [[ ! -f "${MODEL_DIR}/model.safetensors" ]]; then
  echo "Model download finished but model.safetensors is missing: ${MODEL_DIR}/model.safetensors" >&2
  exit 70
fi

echo "MODEL_READY=${MODEL_DIR}"
echo "Qwen ASR model prepared."
