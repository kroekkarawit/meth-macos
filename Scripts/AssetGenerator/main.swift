// Renders Meth's raster assets from the shared vector glyph (Meth/UI/SyringeGlyph.swift):
//   • Meth/Assets.xcassets/AppIcon.appiconset/*.png
//   • docs/assets/logo.png
//   • Scripts/dmg/background.png, background@2x.png
// Run via Scripts/generate-assets.sh. Output is deterministic.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ ctx: CGContext, to url: URL, dpi: Int = 72) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "PNG write failed: \(url.path)")
}

/// macOS app icon: rounded-rect "squircle" tile on a 1024 grid (824 pt body, 100 pt margin).
func drawAppIcon(size: Int) -> CGContext {
    let ctx = bitmap(size, size)
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: srgb(0x000000, 0.28))
    ctx.addPath(path)
    ctx.setFillColor(srgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Clinical white-to-cool-grey gradient.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [srgb(0xFFFFFF), srgb(0xE6EAF0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Subtle inner top highlight.
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.9))
    ctx.setLineWidth(6)
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(path)
    ctx.setStrokeColor(srgb(0x000000, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()

    // Syringe with a faint shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: srgb(0x0B1A33, 0.22))
    SyringeGlyph.draw(in: ctx, rect: body.insetBy(dx: 96, dy: 96), fill: 0.68,
                      stroke: srgb(0x232830), liquid: srgb(0x2F7CF6), lineWidth: 1.25)
    ctx.restoreGState()
    return ctx
}

// MARK: App icon set

let iconset = root.appendingPathComponent("Meth/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(drawAppIcon(size: px), to: iconset.appendingPathComponent(name), dpi: 72 * scale)
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconset.appendingPathComponent("Contents.json"))

// MARK: README logo

writePNG(drawAppIcon(size: 512), to: root.appendingPathComponent("docs/assets/logo.png"))

// MARK: DMG background (660 × 400 window)

func drawDMGBackground(scale: Int) -> CGContext {
    let w = 660, h = 400
    let ctx = bitmap(w * scale, h * scale)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [srgb(0xFBFBFD), srgb(0xEEF0F4)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])

    // Chevron arrow between the app (x=180) and Applications (x=480), icon centre y=190 from top.
    let y = CGFloat(h) - 190
    ctx.setStrokeColor(srgb(0x8A9099, 0.55))
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 286, y: y))
    ctx.addLine(to: CGPoint(x: 372, y: y))
    ctx.move(to: CGPoint(x: 360, y: y + 12))
    ctx.addLine(to: CGPoint(x: 374, y: y))
    ctx.addLine(to: CGPoint(x: 360, y: y - 12))
    ctx.strokePath()
    return ctx
}
writePNG(drawDMGBackground(scale: 1), to: root.appendingPathComponent("Scripts/dmg/background.png"))
writePNG(drawDMGBackground(scale: 2), to: root.appendingPathComponent("Scripts/dmg/background@2x.png"), dpi: 144)

print("Assets written under \(root.path)")
