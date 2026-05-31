#!/usr/bin/env bash
# Build the MLX-enabled app and install it to /Applications so it shows in Launchpad / 应用程序
# with its icon. Clicking the icon launches it (and opens the window).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle-xcode.sh
DEST="/Applications/SaidDone.app"
rm -rf "$DEST" 2>/dev/null || { echo "Can't write $DEST — drag dist/SaidDone.app into /Applications manually."; exit 1; }
cp -R dist/SaidDone.app "$DEST"
echo "Installed -> $DEST"
