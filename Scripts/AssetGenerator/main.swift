// Renders Meth's raster assets (app icon from PillIcon.swift):
//   • Meth/AppIcon.icon (Icon Composer bundle: icon.json + pill layer)
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

/// macOS app icon (see PillIcon.swift).
func drawAppIcon(size: Int) -> CGContext {
    let ctx = bitmap(size, size)
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawPillIcon(ctx)
    return ctx
}

// MARK: Icon Composer bundle (macOS 26 Liquid Glass icon; Xcode derives older sizes from it)

let iconBundle = root.appendingPathComponent("Meth/AppIcon.icon")
do {
    let layer = bitmap(1024, 1024)
    drawPillLayer(layer)
    writePNG(layer, to: iconBundle.appendingPathComponent("Assets/pill.png"))
    let iconJSON = """
    {
      "fill" : {
        "linear-gradient" : [
          "srgb:0.56078,0.88235,1.00000,1.00000",
          "srgb:0.16471,0.48235,0.96471,1.00000"
        ],
        "orientation" : { "start" : { "x" : 0.5, "y" : 0 }, "stop" : { "x" : 0.5, "y" : 1 } }
      },
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "image-name" : "pill.png",
              "name" : "pill",
              "position" : { "scale" : 1, "translation-in-points" : [ 0, 0 ] }
            }
          ],
          "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try iconJSON.write(to: iconBundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
}

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
