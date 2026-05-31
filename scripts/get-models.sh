#!/usr/bin/env bash
# Pre-download the default local MLX LLM into the location SaidDone loads from
# (~/Documents/huggingface/models/...). WhisperKit downloads its ASR model itself on first run.
# Requires the HuggingFace CLI: `pip install huggingface_hub` (provides `hf`).
set -euo pipefail

MODEL="${1:-mlx-community/Qwen3-1.7B-4bit}"
DEST="$HOME/Documents/huggingface/models/$MODEL"

if ! command -v hf >/dev/null 2>&1 && ! command -v huggingface-cli >/dev/null 2>&1; then
  echo "Need HuggingFace CLI. Install: pip install huggingface_hub" >&2
  exit 1
fi
CLI="$(command -v hf || command -v huggingface-cli)"

echo "Downloading $MODEL -> $DEST"
"$CLI" download "$MODEL" --local-dir "$DEST"
echo "Done. Size: $(du -sh "$DEST" | cut -f1)"
