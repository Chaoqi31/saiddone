#!/usr/bin/env bash
# Generate AppIcon.icns (a waveform glyph on an indigo→violet gradient, rounded-square macOS style).
# Output: $1 (default dist/AppIcon.icns). Regenerated at bundle time; not committed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist/AppIcon.icns}"
TMP="$(mktemp -d)"
SWIFT="$TMP/makeicon.swift"

cat > "$SWIFT" <<'SWIFTEOF'
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225).addClip()
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.42, green: 0.36, blue: 0.92, alpha: 1),
    NSColor(srgbRed: 0.58, green: 0.30, blue: 0.86, alpha: 1),
])
grad?.draw(in: rect, angle: -90)
// subtle top highlight
NSColor.white.withAlphaComponent(0.12).setFill()
NSBezierPath(ovalIn: NSRect(x: -size*0.2, y: size*0.55, width: size*1.4, height: size*0.9)).fill()

let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = base.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    base.draw(at: .zero, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (size - s.width)/2, y: (size - s.height)/2, width: s.width, height: s.height))
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFTEOF

MASTER="$TMP/icon_1024.png"
swift "$SWIFT" "$MASTER"

SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$MASTER" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$MASTER" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
echo "icon -> $OUT"
rm -rf "$TMP"
