#!/usr/bin/env bash
# Run the real ASR→polish[→translate] pipeline over the sample recordings in audios/ using the
# on-device engines, and print RAW vs FINAL. This is the regression check for prompt / provider
# changes — run it after touching PolishPrompt.swift or MLXProviders.swift.
#
#   ./scripts/test-audios.sh              # dictation polish over every audios/*.m4a
#   ./scripts/test-audios.sh translate ja # translation mode to a target language
#
# The SaidDoneSpike binary (built by `swift build`) can't load MLX's metallib on its own, so we copy
# the metallib resource bundle (produced by scripts/bundle-xcode.sh) next to it first.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-dictate}"
LANG="${2:-zh}"

swift build >/dev/null
BIN=".build/debug/SaidDoneSpike"

# Ensure MLX's metallib is reachable next to the spike binary.
BUNDLE_SRC="/tmp/dd-saiddone/Build/Products/Debug"
if [ ! -d ".build/debug/mlx-swift_Cmlx.bundle" ]; then
  if [ -d "$BUNDLE_SRC/mlx-swift_Cmlx.bundle" ]; then
    cp -R "$BUNDLE_SRC"/*.bundle .build/debug/ 2>/dev/null || true
  else
    echo "MLX metallib bundle not found. Run ./scripts/bundle-xcode.sh once first." >&2
    exit 1
  fi
fi

shopt -s nullglob
specs=()
for f in audios/*.m4a audios/*.wav audios/*.aiff; do
  specs+=("$f|$MODE|$LANG")
done
[ ${#specs[@]} -gt 0 ] || { echo "No audio files in audios/" >&2; exit 1; }

"$BIN" "${specs[@]}"
