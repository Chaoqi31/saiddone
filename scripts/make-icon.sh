#!/usr/bin/env bash
# Generate AppIcon.icns: a flat speech-bubble-with-checkmark mark ("said" + "done") in white with a
# negative-space check, on a near-black macOS squircle. Output: $1 (default dist/AppIcon.icns).
# Also refreshes the committed README logo (assets/logo.png) from the same master. Not committed (.icns).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist/AppIcon.icns}"
TMP="$(mktemp -d)"
SWIFT="$TMP/makeicon.swift"

cat > "$SWIFT" <<'SWIFTEOF'
import AppKit
let S = 1024.0
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let bg = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.067, alpha: 1)
let rect = NSRect(x: 0, y: 0, width: S, height: S)

// Near-black macOS squircle.
NSBezierPath(roundedRect: rect, xRadius: S * 0.225, yRadius: S * 0.225).addClip()
bg.setFill(); rect.fill()

// White speech bubble + bottom-left tail.
let bx = 242.0, by = 392.0, bw = 540.0, bh = 392.0, r = 150.0
let bubble = NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: bh), xRadius: r, yRadius: r)
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 322, y: by + 40))
tail.line(to: NSPoint(x: 486, y: by + 40))
tail.line(to: NSPoint(x: 312, y: 300))
tail.close()
NSColor.white.setFill()
bubble.fill(); tail.fill()

// Checkmark as negative space (stroke in the background color over the white bubble).
let chk = NSBezierPath()
chk.move(to: NSPoint(x: 424, y: 576))
chk.line(to: NSPoint(x: 500, y: 498))
chk.line(to: NSPoint(x: 658, y: 666))
chk.lineWidth = 66
chk.lineCapStyle = .round
chk.lineJoinStyle = .round
bg.setStroke(); chk.stroke()

// Hairline inner highlight for a touch of polish.
let inset = rect.insetBy(dx: S * 0.018, dy: S * 0.018)
let border = NSBezierPath(roundedRect: inset, xRadius: S * 0.205, yRadius: S * 0.205)
border.lineWidth = S * 0.008
NSColor.white.withAlphaComponent(0.08).setStroke(); border.stroke()

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

# Refresh the committed README logo (256px) from the same master.
sips -z 256 256 "$MASTER" --out "assets/logo.png" >/dev/null 2>&1 || true

echo "icon -> $OUT"
rm -rf "$TMP"
