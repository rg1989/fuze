#!/usr/bin/env swift
// Generates the DMG installer background: dark backdrop, arrow between the
// app icon and the Applications shortcut, "Drag Fuse to Applications" caption.
// Usage: swift scripts/dmg-background.swift <output.png>
// Geometry must match release.sh: 660×400 pt window, icons at y=185 (Finder
// top-left coords) → icon centers sit at bottom-left y≈215 in this drawing.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let size = NSSize(width: 660, height: 400)
let scale: CGFloat = 2   // retina; rep.size keeps the point size at 660×400

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("could not create bitmap")
}
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Warm near-black gradient — same family as the app's dark-glass HUD pills.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1),
    NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.18, alpha: 1),
])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 90)

// Arrow between the two icon slots (icon centers: x=165 and x=495, y≈215).
let arrowColor = NSColor.white.withAlphaComponent(0.85)
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 250, y: 215))
shaft.line(to: NSPoint(x: 390, y: 215))
shaft.lineWidth = 9
shaft.lineCapStyle = .round
arrowColor.setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 368, y: 242))
head.line(to: NSPoint(x: 404, y: 215))
head.line(to: NSPoint(x: 368, y: 188))
head.lineWidth = 9
head.lineCapStyle = .round
head.lineJoinStyle = .round
arrowColor.setStroke()
head.stroke()

// Caption under the icons.
let caption = "Drag Fuse to Applications"
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.92),
]
let captionSize = caption.size(withAttributes: attrs)
caption.draw(at: NSPoint(x: (size.width - captionSize.width) / 2, y: 64), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encoding failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
