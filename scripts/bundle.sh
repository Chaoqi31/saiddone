#!/usr/bin/env bash
# Package the built executable into a runnable menu-bar SaidDone.app.
# Menu-bar app needs LSUIElement + a mic usage string + (ad-hoc) code signing for TCC grants.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/SaidDone.app"
BIN_NAME="SaidDone"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>SaidDone</string>
  <key>CFBundleDisplayName</key>      <string>SaidDone</string>
  <key>CFBundleIdentifier</key>       <string>com.saiddone.app</string>
  <key>CFBundleExecutable</key>       <string>SaidDone</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key>          <string>1</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>LSUIElement</key>              <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>SaidDone transcribes your speech on-device to type for you.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS TCC (mic / accessibility) attributes grants to a stable identity.
codesign --force --sign - --deep "$APP" 2>/dev/null || echo "warn: codesign skipped"

echo "Built $APP"
