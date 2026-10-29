#!/usr/bin/env swift
// Draws the Mac Clean icon and packs it into an .icns file (no design tool or Xcode needed).
// Adapted from App Clean's Scripts/make_icon.swift (same rendering and packing; a new design).
//
// Usage: swift Scripts/make_icon.swift [output.icns] [preview.png]
//   output.icns  default: Resources/AppIcon.icns
//   preview.png  optional: also write the 1024x1024 master, for looking at the design
//
// The design says what the app does: a drive (what fills the disk) with a storage bar in the
// colours of what was found, its end freed, and a sparkle where space was cleaned. Drawn in a
// 1024-unit space on Apple's macOS icon grid (an 824-unit body centred in the canvas) and
// re-rendered at each size; the smallest sizes drop the fine details and enlarge the bar.
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func sparkle(at c: NSPoint, long: CGFloat, short: CGFloat) -> NSBezierPath {
    // Four points with concave sides: each side is a curve pulled towards the centre.
    let path = NSBezierPath()
    let tips = (0..<4).map { i -> NSPoint in
        let a = CGFloat(i) * .pi / 2 + .pi / 2
        return NSPoint(x: c.x + long * cos(a), y: c.y + long * sin(a))
    }
    path.move(to: tips[0])
    for i in 0..<4 {
        let mid = CGFloat(i) * .pi / 2 + .pi / 2 + .pi / 4
        let pull = NSPoint(x: c.x + short * cos(mid), y: c.y + short * sin(mid))
        path.curve(to: tips[(i + 1) % 4], controlPoint1: pull, controlPoint2: pull)
    }
    path.close()
    return path
}

func withShadow(_ color: NSColor, offset: CGFloat, blur: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowOffset = NSSize(width: 0, height: -offset)
    shadow.shadowBlurRadius = blur
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func clipped(_ path: NSBezierPath, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(detailed: Bool) {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Background: deep blue, brighter towards the top, with a soft light behind the drive.
    withShadow(NSColor.black.withAlphaComponent(0.35), offset: 12, blur: 28) {
        rgb(0x14306E).setFill()
        shape.fill()
    }
    clipped(shape) {
        NSGradient(colors: [rgb(0x0A1633), rgb(0x173A86), rgb(0x2F7CE8)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
            .draw(in: body, angle: 90)
        let glow = NSPoint(x: 512, y: 560)
        NSGradient(colors: [rgb(0x8FD8FF, 0.35), rgb(0x8FD8FF, 0)])!
            .draw(fromCenter: glow, radius: 0, toCenter: glow, radius: 430, options: [])
        NSGradient(colors: [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)])!
            .draw(in: NSRect(x: 100, y: 700, width: 824, height: 224), angle: -90)
    }

    // The drive: a brushed-aluminium slab, front view.
    let drive = detailed ? NSRect(x: 176, y: 300, width: 672, height: 330) : NSRect(x: 150, y: 270, width: 724, height: 400)
    let slab = NSBezierPath(roundedRect: drive, xRadius: 76, yRadius: 76)
    withShadow(NSColor.black.withAlphaComponent(0.45), offset: 22, blur: 44) {
        rgb(0xC9D1DD).setFill()
        slab.fill()
    }
    clipped(slab) {
        NSGradient(colors: [rgb(0xFFFFFF), rgb(0xE6EBF2), rgb(0xBFC8D6)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
            .draw(in: drive, angle: -90)
        // A bevel: lighter top edge, darker bottom edge.
        NSGradient(colors: [rgb(0xFFFFFF, 0.9), rgb(0xFFFFFF, 0)])!
            .draw(in: NSRect(x: drive.minX, y: drive.maxY - 26, width: drive.width, height: 26), angle: -90)
        NSGradient(colors: [rgb(0x7E8A9E, 0), rgb(0x7E8A9E, 0.55)])!
            .draw(in: NSRect(x: drive.minX, y: drive.minY, width: drive.width, height: 30), angle: -90)
    }
    rgb(0xFFFFFF, 0.8).setStroke()
    let rim = NSBezierPath(roundedRect: drive.insetBy(dx: 1.5, dy: 1.5), xRadius: 75, yRadius: 75)
    rim.lineWidth = 3
    rim.stroke()

    // The storage bar: what the scan found, in colours, and a freed end.
    let bar = detailed ? NSRect(x: 236, y: 438, width: 552, height: 92) : NSRect(x: 214, y: 410, width: 596, height: 140)
    let track = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
    clipped(track) {
        NSGradient(colors: [rgb(0x1A2340), rgb(0x2B3658)])!.draw(in: bar, angle: -90)
        let parts: [(CGFloat, UInt32, UInt32)] = [
            (0.30, 0x4FB3FF, 0x2A6BFF),   // blue
            (0.17, 0xB58BFF, 0x7A4DFF),   // violet
            (0.13, 0xFFCB52, 0xFF8F3A),   // orange
            (0.10, 0x5BEAB0, 0x1FBF86),   // green
            (0.07, 0xFF86B0, 0xFF4F6E),   // pink
        ]
        var x = bar.minX
        let gap: CGFloat = detailed ? 6 : 8
        for (share, a, b) in parts {
            let w = bar.width * share
            let piece = NSRect(x: x, y: bar.minY, width: w - gap, height: bar.height)
            NSGradient(colors: [rgb(a), rgb(b)])!.draw(in: piece, angle: -90)
            // A gloss on the top half of each piece.
            NSGradient(colors: [rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)])!
                .draw(in: NSRect(x: piece.minX, y: piece.midY, width: piece.width, height: piece.height / 2), angle: -90)
            x += w
        }
    }
    // Inner shadow on the track, so the bar sits in the drive.
    rgb(0x0B1020, 0.35).setStroke()
    track.lineWidth = 4
    track.stroke()

    if detailed {
        // A status light and two screws.
        let led = NSRect(x: 748, y: 352, width: 40, height: 18)
        withShadow(rgb(0x37E39A, 0.9), offset: 0, blur: 16) {
            rgb(0x37E39A).setFill()
            NSBezierPath(roundedRect: led, xRadius: 9, yRadius: 9).fill()
        }
        for cx in [CGFloat(236), 300] {
            let screw = NSBezierPath(ovalIn: NSRect(x: cx, y: 352, width: 18, height: 18))
            rgb(0x9AA5B8).setFill()
            screw.fill()
        }
        // Groove lines across the face.
        rgb(0xFFFFFF, 0.7).setFill()
        NSRect(x: drive.minX + 40, y: 590, width: drive.width - 80, height: 3).fill()
        rgb(0x8C97AA, 0.45).setFill()
        NSRect(x: drive.minX + 40, y: 587, width: drive.width - 80, height: 3).fill()
    }

    // The sparkle over the freed end of the bar: space cleaned.
    // Its lower tip points down at the freed end, stopping just short of the drive.
    let starLong: CGFloat = detailed ? 132 : 150
    let freed = NSPoint(x: bar.minX + bar.width * 0.87, y: drive.maxY + starLong - 6)
    withShadow(rgb(0x8FE9FF, 0.9), offset: 0, blur: 30) {
        let star = sparkle(at: freed, long: starLong, short: starLong * 0.17)
        NSColor.white.setFill()
        star.fill()
        clipped(star) {
            NSGradient(colors: [NSColor.white, rgb(0xBDEFFF)])!.draw(in: star.bounds, angle: -90)
        }
    }
    if detailed {
        rgb(0xFFFFFF, 0.9).setFill()
        sparkle(at: NSPoint(x: freed.x - 170, y: freed.y + 110), long: 46, short: 8).fill()
        rgb(0x9FE6FF, 0.9).setFill()
        sparkle(at: NSPoint(x: freed.x - 300, y: freed.y + 40), long: 26, short: 5).fill()
    }

    rgb(0xFFFFFF, 0.12).setStroke()
    let border = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    border.lineWidth = 4
    border.stroke()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    drawIcon(detailed: pixels > 64)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.icns"
let preview = arguments.count > 2 ? arguments[2] : nil

_ = NSApplication.shared
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MacClean-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// The names and sizes iconutil expects: each point size at 1x and 2x.
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels: pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}
if let preview {
    try render(pixels: 1024).write(to: URL(fileURLWithPath: preview))
    // Small sizes next to the master, to check they stay legible.
    for pixels in [16, 32, 64, 128] {
        try render(pixels: pixels).write(to: URL(fileURLWithPath: preview.replacingOccurrences(of: ".png", with: "-\(pixels).png")))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output)")
