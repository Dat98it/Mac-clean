#!/usr/bin/env swift
// Makes the menu bar glyph from the chosen artwork, Resources/MenuBarIcon-source.png.
//
// Usage: swift Scripts/make_menubar_icon.swift [preview-folder]
//   writes Resources/MenuBarIcon.png (1x) and Resources/MenuBarIcon@2x.png
//   preview-folder  optional: also the cleaned master and the glyph on light and dark menu bars
//
// The artwork came with its transparency painted in (a grey checkerboard, no alpha channel), so
// the glyph is taken from darkness: near-black is opaque, light grey transparent, with a soft ramp
// between for smooth edges. It is then cropped and fitted to the menu bar: 16 pt tall inside an
// 18 pt image, as a template (black with alpha; macOS tints it for light and dark menu bars).
import AppKit

let source = "Resources/MenuBarIcon-source.png"
guard let data = FileManager.default.contents(atPath: source), let art = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write(Data("cannot read \(source)\n".utf8))
    exit(1)
}
let w = art.pixelsWide, h = art.pixelsHigh

// Darkness → alpha. The glyph is about 0.0 luminance, the checkerboard 0.5 to 0.85.
let opaqueBelow: CGFloat = 0.15, clearAbove: CGFloat = 0.42
let mask = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
var box = (minX: w, maxX: 0, minY: h, maxY: 0)
for y in 0..<h {
    for x in 0..<w {
        let c = art.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let lum = (c.redComponent + c.greenComponent + c.blueComponent) / 3
        let alpha = max(0, min(1, (clearAbove - lum) / (clearAbove - opaqueBelow)))
        mask.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: alpha), atX: x, y: y)
        if alpha > 0.5 { box = (min(box.minX, x), max(box.maxX, x), min(box.minY, y), max(box.maxY, y)) }
    }
}
let glyphWidth = CGFloat(box.maxX - box.minX + 1), glyphHeight = CGFloat(box.maxY - box.minY + 1)
let maskImage = NSImage(size: NSSize(width: w, height: h))
maskImage.addRepresentation(mask)
// The glyph's box in AppKit coordinates (origin bottom left).
let glyphRect = NSRect(x: CGFloat(box.minX), y: CGFloat(h - 1 - box.maxY), width: glyphWidth, height: glyphHeight)

/// The glyph `glyphPoints` tall, centred in an image `imagePoints` tall, at `scale` pixels per point.
func render(glyphPoints: CGFloat, imagePoints: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    let glyphW = glyphPoints * glyphWidth / glyphHeight
    let imageW = (glyphW + (imagePoints - glyphPoints)).rounded(.up)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(imageW * scale), pixelsHigh: Int(imagePoints * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: imageW, height: imagePoints)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let target = NSRect(x: (imageW - glyphW) / 2, y: (imagePoints - glyphPoints) / 2, width: glyphW, height: glyphPoints)
    maskImage.draw(in: target, from: glyphRect, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

_ = NSApplication.shared
let one = render(glyphPoints: 16, imagePoints: 18, scale: 1)
let two = render(glyphPoints: 16, imagePoints: 18, scale: 2)
try write(one, "Resources/MenuBarIcon.png")
try write(two, "Resources/MenuBarIcon@2x.png")
print("Wrote Resources/MenuBarIcon.png (\(one.pixelsWide)x\(one.pixelsHigh)) and @2x (\(two.pixelsWide)x\(two.pixelsHigh))")

if CommandLine.arguments.count > 1 {
    let folder = CommandLine.arguments[1]
    try write(render(glyphPoints: 900, imagePoints: 1000, scale: 1), folder + "/master.png")
    // How it looks on a light and a dark menu bar, at 1x and 2x, magnified without smoothing.
    let sheet = NSImage(size: NSSize(width: 520, height: 240))
    sheet.lockFocus()
    for (row, (bar, ink)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
        let y = CGFloat(row) * 120
        bar.setFill()
        NSRect(x: 0, y: y, width: 520, height: 120).fill()
        for (i, rep) in [one, two].enumerated() {
            let glyph = NSImage(size: rep.size)
            glyph.addRepresentation(rep)
            glyph.isTemplate = true
            // Tint like the menu bar does: fill the glyph's shape with the ink colour.
            let tinted = NSImage(size: rep.size, flipped: false) { r in
                glyph.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            NSGraphicsContext.current?.imageInterpolation = .none
            tinted.draw(in: NSRect(x: 20 + CGFloat(i) * 250, y: y + 15, width: rep.size.width * 4, height: rep.size.height * 4))
            NSGraphicsContext.current?.imageInterpolation = .high
            tinted.draw(in: NSRect(x: 20 + CGFloat(i) * 250 + rep.size.width * 4 + 20, y: y + 50, width: rep.size.width, height: rep.size.height))
        }
    }
    sheet.unlockFocus()
    try NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: folder + "/sheet.png"))
}
