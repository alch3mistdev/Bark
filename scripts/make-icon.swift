#!/usr/bin/env swift
// Generates Resources/Bark.icns — a rounded gradient tile with a white mic glyph.
// Run: swift scripts/make-icon.swift
import AppKit
import Foundation

func renderPNG(size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let full = NSRect(x: 0, y: 0, width: size, height: size)

    // Rounded background with a blue→indigo gradient (macOS "squircle"-ish inset).
    let inset = size * 0.06
    let radius = size * 0.225
    let tile = NSBezierPath(roundedRect: full.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.96, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: -90)

    // White mic glyph, centered.
    if let base = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Bark") {
        let conf = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let glyph = base.withSymbolConfiguration(conf) {
            let gs = glyph.size
            let scale = (size * 0.5) / max(gs.width, gs.height)
            let w = gs.width * scale, h = gs.height * scale
            glyph.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
        }
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png render failed at \(size)")
    }
    return png
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Bark.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    let data = renderPNG(size: size)
    try! data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let out = root.appendingPathComponent("Resources/Bark.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(proc.terminationStatus == 0 ? "✓ wrote \(out.path)" : "✗ iconutil failed (\(proc.terminationStatus))")
