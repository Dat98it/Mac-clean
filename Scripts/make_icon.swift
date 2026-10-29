#!/usr/bin/env swift
// Makes Resources/AppIcon.icns from the chosen artwork, Resources/AppIcon-source.png (no design tool
// or Xcode needed). The rendering and packing are adapted from App Clean's Scripts/make_icon.swift.
//
// Usage: swift Scripts/make_icon.swift [output.icns] [preview.png]
//   output.icns  default: Resources/AppIcon.icns
//   preview.png  optional: also write the 1024x1024 master and small sizes, for checking
//
// The artwork's body (its opaque rounded square) is found from the alpha channel and fitted to
// Apple's macOS icon grid: an 824-unit body centred in a 1024-unit canvas, like every other app in
// the Dock. Its soft shadow and the magnifier handle keep their place around it.
import AppKit

let source = "Resources/AppIcon-source.png"
guard let data = FileManager.default.contents(atPath: source), let art = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write(Data("cannot read \(source)\n".utf8))
    exit(1)
}

/// The box of nearly opaque pixels, in image coordinates (origin at the top left).
func opaqueBounds(_ rep: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
    var box = (rep.pixelsWide, 0, rep.pixelsHigh, 0)
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)!.alphaComponent > 0.8 {
            box = (min(box.0, x), max(box.1, x), min(box.2, y), max(box.3, y))
        }
    }
    return box
}

let body = opaqueBounds(art)
let bodySize = CGFloat(max(body.maxX - body.minX, body.maxY - body.minY) + 1)
let scale = 824 / bodySize
// Centre of the body, flipped to AppKit's bottom-left origin.
let bodyCentre = NSPoint(x: CGFloat(body.minX + body.maxX + 1) / 2, y: CGFloat(art.pixelsHigh) - CGFloat(body.minY + body.maxY + 1) / 2)
let artRect = NSRect(x: 512 - bodyCentre.x * scale, y: 512 - bodyCentre.y * scale,
                     width: CGFloat(art.pixelsWide) * scale, height: CGFloat(art.pixelsHigh) * scale)
let artImage = NSImage(size: NSSize(width: art.pixelsWide, height: art.pixelsHigh))
artImage.addRepresentation(art)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let unit = CGFloat(pixels) / 1024
    let target = NSRect(x: artRect.minX * unit, y: artRect.minY * unit, width: artRect.width * unit, height: artRect.height * unit)
    artImage.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
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
print("Wrote \(output) (artwork body \(Int(bodySize)) px scaled by \(String(format: "%.3f", scale)))")
