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
// Rounded square fills ~90% of the canvas with a small transparent margin (room for the OS drop
// shadow). The strict ~80% grid read visibly smaller than the real-world Dock icons next to it.
let m = 52.0, C = 920.0, f = 920.0 / 1024.0
func tx(_ v: Double) -> Double { m + v * f }   // map original 1024-design coord into the inset grid
func ts(_ v: Double) -> Double { v * f }        // scale a length/radius into the grid

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let bg = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.067, alpha: 1)

// Near-black squircle (inset; canvas stays transparent around it).
let sq = NSRect(x: m, y: m, width: C, height: C)
let squircle = NSBezierPath(roundedRect: sq, xRadius: C * 0.2237, yRadius: C * 0.2237)
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
bg.setFill(); sq.fill()

// White speech bubble + bottom-left tail.
let bubble = NSBezierPath(roundedRect: NSRect(x: tx(242), y: tx(392), width: ts(540), height: ts(392)),
                          xRadius: ts(150), yRadius: ts(150))
let tail = NSBezierPath()
tail.move(to: NSPoint(x: tx(322), y: tx(432)))
tail.line(to: NSPoint(x: tx(486), y: tx(432)))
tail.line(to: NSPoint(x: tx(312), y: tx(300)))
tail.close()
NSColor.white.setFill()
bubble.fill(); tail.fill()

// Checkmark as negative space (stroke in the background color over the white bubble).
let chk = NSBezierPath()
chk.move(to: NSPoint(x: tx(424), y: tx(576)))
chk.line(to: NSPoint(x: tx(500), y: tx(498)))
chk.line(to: NSPoint(x: tx(658), y: tx(666)))
chk.lineWidth = ts(66)
chk.lineCapStyle = .round
chk.lineJoinStyle = .round
bg.setStroke(); chk.stroke()
NSGraphicsContext.restoreGraphicsState()

// Hairline highlight on the squircle edge.
let border = NSBezierPath(roundedRect: sq.insetBy(dx: ts(14), dy: ts(14)),
                          xRadius: C * 0.205, yRadius: C * 0.205)
border.lineWidth = ts(8)
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
