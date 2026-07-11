#!/usr/bin/env swift
//
// Quartet Desk app icon generator — "QD" cyan monogram on an AppSpace-style
// dark squircle (mirrors web/public/apple-touch-icon.png: near-black rounded
// square, thin inset cyan outline ring, big cyan glyphs, cyan dot bottom-right).
//
// Run:  swift scripts/generate-appicon.swift
//
// Writes all 10 macOS icon PNGs + Contents.json into
// App/Assets.xcassets/AppIcon.appiconset/ (paths relative to the repo root —
// run from the repo root). Every size is rendered VECTOR-FRESH at its exact
// pixel size (no downscaling of one master bitmap; 16px needs crisp hinting).
//
// Design metrics (master canvas 1024×1024, spec §5.1; all scale by size/1024):
// - squircle: rect (100,100,824,824), corner radius 185.4, fill vertical
//   gradient #111116 (top) → #0A0A0B (bottom)
// - inset ring: #92F8FF @ 85%, 6px stroke, rect (130,130,764,764), radius 168
//   — OMITTED below 64px output so the QD strokes stay legible at 16/32px
// - monogram: "QD", SF Pro heavy 380pt, #92F8FF, max width 560px, optically
//   centered then offset up-left (-12,+12) to make room for the dot
// - dot: 96px circle, #92F8FF, center (724,724) in top-left coordinates
// - no shadows/bevels (flat brand; macOS composites its own shadow)

import AppKit
import Foundation

let ice = NSColor(srgbRed: 146 / 255, green: 248 / 255, blue: 255 / 255, alpha: 1)
let gradientTop = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x16 / 255, alpha: 1)
let gradientBottom = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255, alpha: 1)

/// Draws the icon into the CURRENT graphics context at `pixels`×`pixels`.
/// All spec metrics are in a 1024 master space with TOP-LEFT origin; this
/// function converts to Cocoa's bottom-left origin explicitly.
func drawIcon(pixels: Int) {
    let s = CGFloat(pixels) / 1024.0
    func flipY(_ topLeftY: CGFloat) -> CGFloat { (1024.0 - topLeftY) * s }

    // Squircle (symmetric rect: same in either origin convention)
    let squircleRect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: squircleRect,
                                xRadius: 185.4 * s, yRadius: 185.4 * s)
    // NSGradient at angle 90° runs start→end from bottom to top.
    guard let gradient = NSGradient(starting: gradientBottom, ending: gradientTop) else {
        fatalError("NSGradient creation failed")
    }
    gradient.draw(in: squircle, angle: 90)

    // Inset outline ring — off below 64px output for 16/32px legibility.
    if pixels >= 64 {
        let ringRect = NSRect(x: 130 * s, y: 130 * s, width: 764 * s, height: 764 * s)
        let ring = NSBezierPath(roundedRect: ringRect, xRadius: 168 * s, yRadius: 168 * s)
        ring.lineWidth = 6 * s
        ice.withAlphaComponent(0.85).setStroke()
        ring.stroke()
    }

    // Monogram "QD"
    var fontSize = 380 * s
    var font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ice]
    var textSize = NSAttributedString(string: "QD", attributes: attributes).size()
    let maxWidth = 560 * s
    if textSize.width > maxWidth {
        fontSize *= maxWidth / textSize.width
        font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        attributes = [.font: font, .foregroundColor: ice]
        textSize = NSAttributedString(string: "QD", attributes: attributes).size()
    }
    let squircleCenterX = squircleRect.midX
    let squircleCenterY = squircleRect.midY
    // Optical centering: center the CAP-HEIGHT block (caps have no descender;
    // centering the full line box would sit the glyphs visibly low).
    let offsetX = -12 * s // up-left, per spec: room for the dot at bottom-right
    let offsetY = 12 * s
    let baselineY = squircleCenterY - font.capHeight / 2 + offsetY
    let drawOrigin = NSPoint(x: squircleCenterX - textSize.width / 2 + offsetX,
                             y: baselineY + font.descender) // descender < 0
    NSAttributedString(string: "QD", attributes: attributes).draw(at: drawOrigin)

    // Dot — the "A." brand echo, bottom-right inside the ring.
    // Spec center (724,724) is in top-left coordinates.
    let dotDiameter = 96 * s
    let dotCenter = NSPoint(x: 724 * s, y: flipY(724))
    let dotRect = NSRect(x: dotCenter.x - dotDiameter / 2,
                         y: dotCenter.y - dotDiameter / 2,
                         width: dotDiameter, height: dotDiameter)
    ice.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
}

func renderPNG(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels,
                                     pixelsHigh: pixels,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .calibratedRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else {
        fatalError("Could not create bitmap rep for \(pixels)px")
    }
    let srgbRep = rep.retagging(with: .sRGB) ?? rep

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: srgbRep) else {
        fatalError("Could not create graphics context for \(pixels)px")
    }
    NSGraphicsContext.current = context
    drawIcon(pixels: pixels)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = srgbRep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(pixels)px")
    }
    return png
}

// (pt, scale, pixels, filename) — the 10 required macOS entries.
let sizes: [(pt: Int, scale: Int, px: Int, file: String)] = [
    (16, 1, 16, "icon_16.png"),
    (16, 2, 32, "icon_16@2x.png"),
    (32, 1, 32, "icon_32.png"),
    (32, 2, 64, "icon_32@2x.png"),
    (128, 1, 128, "icon_128.png"),
    (128, 2, 256, "icon_128@2x.png"),
    (256, 1, 256, "icon_256.png"),
    (256, 2, 512, "icon_256@2x.png"),
    (512, 1, 512, "icon_512.png"),
    (512, 2, 1024, "icon_512@2x.png"),
]

let outputDir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("FATAL: could not create \(outputDir.path): \(error)\n".utf8))
    exit(1)
}

for entry in sizes {
    let png = renderPNG(pixels: entry.px)
    let url = outputDir.appendingPathComponent(entry.file)
    do {
        try png.write(to: url, options: .atomic)
        print("wrote \(url.path) (\(entry.px)px)")
    } catch {
        FileHandle.standardError.write(Data("FATAL: write failed for \(url.path): \(error)\n".utf8))
        exit(1)
    }
}

let images = sizes.map { entry in
    """
        {
          "filename" : "\(entry.file)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.pt)x\(entry.pt)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

do {
    try Data(contents.utf8).write(to: outputDir.appendingPathComponent("Contents.json"), options: .atomic)
    print("wrote \(outputDir.path)/Contents.json")
} catch {
    FileHandle.standardError.write(Data("FATAL: Contents.json write failed: \(error)\n".utf8))
    exit(1)
}
print("Done. Re-run `xcodegen generate` so the app target picks up the catalog.")
