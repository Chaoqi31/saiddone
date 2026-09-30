#!/usr/bin/env bash
# Package dist/SaidDone.app.
#
#   scripts/bundle.sh            # release build
#   scripts/bundle.sh debug
#
# With Xcode and its Metal toolchain, the build goes through xcodebuild, which compiles MLX's shaders so on-device
# AI (Qwen) runs. With only the Command Line Tools it goes through SwiftPM: on-device speech and every cloud engine
# work, on-device AI does not.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/SaidDone.app"
VER="${SAIDDONE_VERSION:-2.0.0}"
VER="${VER#v}"
IFS=. read -r V_MAJ V_MIN V_PAT _ <<< "$VER"
BUILD="${SAIDDONE_BUILD:-$((V_MAJ * 1000 + V_MIN * 100 + V_PAT))}"

if [[ "$(xcode-select -p)" != *CommandLineTools* ]] && xcrun --find metal >/dev/null 2>&1; then
  SCHEME_CONFIG=$([ "$CONFIG" = debug ] && echo Debug || echo Release)
  DERIVED=/tmp/dd-saiddone
  echo "Building with xcodebuild ($SCHEME_CONFIG, MLX shaders included)…"
  xcodebuild -scheme SaidDone -configuration "$SCHEME_CONFIG" -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' build >/dev/null
  PRODUCTS="$DERIVED/Build/Products/$SCHEME_CONFIG"
else
  echo "Building with SwiftPM ($CONFIG). No Metal toolchain, so on-device AI is unavailable in this build."
  swift build -c "$CONFIG" --product SaidDone
  PRODUCTS="$(swift build -c "$CONFIG" --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/SaidDone" "$APP/Contents/MacOS/SaidDone"
# Resource bundles (MLX's metallib, tokenizer fallbacks). Xcode's generated accessors look in Contents/Resources.
for bundle in "$PRODUCTS"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key><string>${VER}</string>
  <key>CFBundleVersion</key>          <string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>zh-Hans</string></array>
  <key>LSUIElement</key>              <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>SaidDone listens while you use its shortcut, and turns what you say into text.</string>
</dict>
</plist>
PLIST

./scripts/make-icon.sh "$APP/Contents/Resources/AppIcon.icns" >/dev/null
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signing changes it every build.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "SaidDone Dev"; then
  codesign --force --deep --sign "SaidDone Dev" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP ($VER)"
