#!/usr/bin/env bash
# Build the app and put it in /Applications, where Launchpad and Open at Login find it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
DEST="/Applications/SaidDone.app"
rm -rf "$DEST" 2>/dev/null || { echo "Can't write $DEST. Drag dist/SaidDone.app into /Applications instead."; exit 1; }
cp -R dist/SaidDone.app "$DEST"
echo "Installed $DEST"
