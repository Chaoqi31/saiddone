#!/usr/bin/env bash
# Build a distributable DMG (ad-hoc signed). Strangers download it, drag to /Applications, and open
# once via right-click → Open (macOS 14) or System Settings → Privacy & Security → "Open Anyway"
# (macOS 15). Open-source apps distribute this way without paid notarization.
# For a no-Gatekeeper-warning build, use scripts/notarize.sh with an Apple Developer account.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle-xcode.sh

DMG="dist/SaidDone.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Stage a friendly DMG: the app, a drop target for /Applications, and a plain-text first-run guide.
cp -R "dist/SaidDone.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST — 先读我.txt" <<'TXT'
SaidDone — install & first launch
=================================

1. Drag SaidDone onto the Applications folder (the shortcut in this window).

2. The first open may be blocked ("Apple cannot verify…"). To allow it:
   • macOS 14 (Sonoma): right-click SaidDone in Applications → Open → Open.
   • macOS 15 (Sequoia): double-click it, then open
     System Settings → Privacy & Security → scroll down → "Open Anyway".
   • Or run in Terminal:
       xattr -dr com.apple.quarantine /Applications/SaidDone.app

3. On first launch a Setup Assistant walks you through microphone +
   accessibility permissions, choosing your engines (local or cloud),
   and downloading the models.

Open-source · local-first · MIT. Requires Apple Silicon · macOS 14+.
TXT

rm -f "$DMG"
hdiutil create -volname "SaidDone" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
# Ad-hoc sign the DMG so its contents aren't flagged as tampered after download.
codesign --force --sign - "$DMG" 2>/dev/null || echo "warn: DMG codesign skipped"
echo "Built $DMG  ($(du -h "$DMG" | cut -f1))"
