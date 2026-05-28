#!/usr/bin/env swift
import AppKit

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "SparkPlug.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let bg = NSColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
let yellow = NSColor(red: 1.00, green: 0.84, blue: 0.13, alpha: 1.0)

for (name, px) in sizes {
    let s = CGFloat(px)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    ) else { fatalError("bitmap rep") }
    rep.size = NSSize(width: px, height: px)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
    let prev = NSGraphicsContext.current
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // Background squircle (Big Sur radius ≈ 22.37% of edge)
    bg.setFill()
    let radius = s * 0.2237
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: radius, yRadius: radius).fill()

    // Lightning bolt via SF Symbol
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.58, weight: .black)
    let paletteCfg = NSImage.SymbolConfiguration(paletteColors: [yellow])
    let combined = cfg.applying(paletteCfg)
    if let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil),
       let bolt = base.withSymbolConfiguration(combined) {
        let drawRect = NSRect(
            x: (s - bolt.size.width) / 2,
            y: (s - bolt.size.height) / 2,
            width: bolt.size.width,
            height: bolt.size.height
        )
        bolt.draw(in: drawRect)
    }

    NSGraphicsContext.current = prev

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode \(name)")
    }
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("✓ \(name)")
}
print("done → \(outDir)")
