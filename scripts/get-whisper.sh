#!/usr/bin/env bash
# Download + install the WhisperKit ASR model SaidDone loads from:
#   ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>/
#
# Usage:
#   ./scripts/get-whisper.sh                              # default turbo
#   ./scripts/get-whisper.sh openai_whisper-large-v3        # full large-v3
#   HF_ENDPOINT=https://hf-mirror.com ./scripts/get-whisper.sh   # China mirror
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${1:-openai_whisper-large-v3-v20240930_turbo}"
CACHE=".cache/whisper"
DEST="$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/$MODEL"

if ! command -v hf >/dev/null 2>&1 && ! command -v huggingface-cli >/dev/null 2>&1; then
  echo "Need HuggingFace CLI: pip install huggingface_hub" >&2
  exit 1
fi
CLI="$(command -v hf || command -v huggingface-cli)"

echo "==> Downloading $MODEL (WhisperKit / argmaxinc/whisperkit-coreml)"
mkdir -p "$CACHE"
"$CLI" download argmaxinc/whisperkit-coreml \
  --include "${MODEL}/*" \
  --local-dir "$CACHE"

if [ ! -d "$CACHE/$MODEL/AudioEncoder.mlmodelc" ]; then
  echo "Download incomplete — AudioEncoder.mlmodelc missing" >&2
  exit 1
fi

echo "==> Installing to $DEST"
mkdir -p "$(dirname "$DEST")"
# Clear stale/corrupted partial downloads (common when a prior run was interrupted).
rm -rf "$DEST"
cp -R "$CACHE/$MODEL" "$DEST"

echo "==> Done ($(du -sh "$DEST" | cut -f1))"
echo "    Restart SaidDone if it was open during install."
