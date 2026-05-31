#!/usr/bin/env bash
# Build a distributable DMG (ad-hoc signed). Strangers download it, drag to /Applications, and
# right-click → Open once (open-source apps distribute this way without paid notarization).
# For a no-Gatekeeper-warning build, use scripts/notarize.sh with an Apple Developer account.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle-xcode.sh
DMG="dist/SaidDone.dmg"
rm -f "$DMG"
hdiutil create -volname "SaidDone" -srcfolder "dist/SaidDone.app" -ov -format UDZO "$DMG"
echo "Built $DMG  ($(du -h "$DMG" | cut -f1))"
