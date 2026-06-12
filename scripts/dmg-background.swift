#!/usr/bin/env swift
// Generates the DMG installer background.
//
// Design constraint: Finder draws icon labels in BLACK whenever a window has
// a custom background picture (no API to change it, and the picture cannot
// adapt to light/dark mode). A light backdrop is therefore the only way to
// keep the "Fuse" / "Applications" labels readable in every theme.
//
// Usage: swift scripts/dmg-background.swift <output.png>
// Geometry must match release.sh: 660×340 pt window, icon centers at
// Finder (top-left) y=160 → bottom-left drawing y=180.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let size = NSSize(width: 660, height: 340)
let scale: CGFloat = 2   // retina; rep.size keeps the point size

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

// Soft paper-white gradient — black Finder labels read cleanly on it.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.90, alpha: 1),
    NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.96, alpha: 1),
])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 90)

// Arrow between the icon slots (centers x=165 and x=495, y=180): ONE filled
// opaque path — overlapping translucent strokes previously left a visible
// blob where shaft and head crossed.
let arrowY: CGFloat = 180
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 250, y: arrowY - 8))
arrow.line(to: NSPoint(x: 375, y: arrowY - 8))
arrow.line(to: NSPoint(x: 375, y: arrowY - 25))
arrow.line(to: NSPoint(x: 412, y: arrowY))
arrow.line(to: NSPoint(x: 375, y: arrowY + 25))
arrow.line(to: NSPoint(x: 375, y: arrowY + 8))
arrow.line(to: NSPoint(x: 250, y: arrowY + 8))
arrow.close()
NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
arrow.fill()
// Rounded corners via a stroke of the same color.
NSColor(calibratedWhite: 0.28, alpha: 1).setStroke()
arrow.lineWidth = 6
arrow.lineJoinStyle = .round
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encoding failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
