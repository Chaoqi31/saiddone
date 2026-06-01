#!/usr/bin/env bash
# Package a FULL-featured SaidDone.app via xcodebuild — includes MLX's compiled metallib so the
# Qwen LLM (polish + translation) runs. Requires the Metal Toolchain
# (xcodebuild -downloadComponent MetalToolchain). For the lightweight WhisperKit-only app, use bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

DD=/tmp/dd-saiddone
APP="dist/SaidDone.app"
PROD="$DD/Build/Products/Debug"

echo "Building SaidDone via xcodebuild (compiles metallib)…"
xcodebuild -scheme SaidDone -derivedDataPath "$DD" -destination 'platform=macOS,arch=arm64' build >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROD/SaidDone" "$APP/Contents/MacOS/SaidDone"
# SPM resource bundles (metallib, tokenizer Hub). Bundle.module resolves via Bundle.main.resourceURL
# (Contents/Resources) for a .app, but also checks next to the executable — copy to both to be safe.
for b in "$PROD"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/Contents/Resources/"
  cp -R "$b" "$APP/Contents/MacOS/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>SaidDone</string>
  <key>CFBundleDisplayName</key>      <string>SaidDone</string>
  <key>CFBundleIdentifier</key>       <string>com.saiddone.app</string>
  <key>CFBundleExecutable</key>       <string>SaidDone</string>
  <key>CFBundleIconFile</key>         <string>AppIcon</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key>          <string>1</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>zh-Hans</string></array>
  <key>NSMicrophoneUsageDescription</key>
  <string>SaidDone transcribes your speech on-device to type for you.</string>
</dict>
</plist>
PLIST

# App icon (generated, not committed).
./scripts/make-icon.sh "$APP/Contents/Resources/AppIcon.icns" >/dev/null

# Localizations (hand-authored .strings). SwiftUI Text / NSLocalizedString resolve against
# Bundle.main = the .app, so these *.lproj must live in Contents/Resources.
for lproj in Resources/*.lproj; do
  [ -e "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# Prefer the stable self-signed "SaidDone Dev" identity so macOS persists the Accessibility grant
# across rebuilds (ad-hoc "-" re-prompts every launch). Falls back to ad-hoc if the cert is absent.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "SaidDone Dev"; then
  codesign --force --deep --sign "SaidDone Dev" "$APP"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "warn: codesign skipped"
fi
echo "Built $APP (MLX-enabled)"
