#!/usr/bin/env bash
# Sign with Developer ID, build a DMG, notarize, and staple — the whole "shippable to strangers"
# pipeline. Needs a paid Apple Developer account (one-time external dependency the agent can't supply).
#
# Set these first:
#   export DEVID="Developer ID Application: Your Name (TEAMID)"   # cert installed in your keychain
#   export APPLE_ID="you@example.com"
#   export TEAM_ID="TEAMID"
#   export APP_PW="xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com
# Then: ./scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVID:?set DEVID}"; : "${APPLE_ID:?set APPLE_ID}"; : "${TEAM_ID:?set TEAM_ID}"; : "${APP_PW:?set APP_PW}"

./scripts/bundle-xcode.sh
APP="dist/SaidDone.app"; DMG="dist/SaidDone.dmg"

echo "Signing with Developer ID (hardened runtime)…"
codesign --force --deep --options runtime --timestamp --sign "$DEVID" "$APP"

echo "Building DMG…"
rm -f "$DMG"
hdiutil create -volname "SaidDone" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$DEVID" "$DMG"

echo "Notarizing (waits for Apple)…"
xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" --wait

echo "Stapling…"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
echo "Done -> $DMG (notarized; others can open it without Gatekeeper warnings)."
