import CoreGraphics

/// Vector syringe drawn with Core Graphics. Shared by the menu bar icon (runtime) and
/// the app icon / DMG background generator (Scripts/AssetGenerator), so every Meth
/// syringe has exactly the same silhouette. No external or remote assets.
enum SyringeGlyph {
    /// Draws a diagonal syringe (needle bottom-left, plunger top-right) fitted to `rect`.
    /// - Parameters:
    ///   - fill: 0…1 fraction of the barrel filled with liquid.
    ///   - lineWidth: stroke width in the glyph's 24-unit design space.
    static func draw(in ctx: CGContext, rect: CGRect, fill: CGFloat, stroke: CGColor, liquid: CGColor,
                     lineWidth: CGFloat = 1.5, angleDegrees: CGFloat = 45) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Design space: syringe along +x from -12…+12, centred on the origin.
        let scale = min(rect.width, rect.height) / 24.0
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.rotate(by: angleDegrees * .pi / 180)

        ctx.setStrokeColor(stroke)
        ctx.setFillColor(stroke)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Needle.
        ctx.move(to: CGPoint(x: -11.6, y: 0))
        ctx.addLine(to: CGPoint(x: -7.2, y: 0))
        ctx.strokePath()

        // Hub.
        ctx.fill(CGRect(x: -7.4, y: -1.25, width: 1.6, height: 2.5))

        // Barrel.
        let barrel = CGRect(x: -5.8, y: -2.9, width: 10.6, height: 5.8)
        let barrelPath = CGPath(roundedRect: barrel, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)

        // Liquid (clipped to the barrel interior).
        let clamped = max(0, min(1, fill))
        if clamped > 0 {
            ctx.saveGState()
            let inner = barrel.insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
            ctx.clip()
            ctx.setFillColor(liquid)
            ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width * clamped, height: inner.height))
            ctx.restoreGState()
        }

        ctx.addPath(barrelPath)
        ctx.strokePath()

        // Graduation ticks.
        ctx.setLineWidth(lineWidth * 0.55)
        for x in stride(from: -3.6, through: 2.4, by: 2.0) {
            ctx.move(to: CGPoint(x: x, y: 2.9))
            ctx.addLine(to: CGPoint(x: x, y: 1.4))
        }
        ctx.strokePath()
        ctx.setLineWidth(lineWidth)

        // Finger flange.
        let flange = CGRect(x: 4.8, y: -4.6, width: 1.5, height: 9.2)
        ctx.addPath(CGPath(roundedRect: flange, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
        ctx.fillPath()

        // Plunger rod and thumb rest.
        ctx.fill(CGRect(x: 6.3, y: -0.8, width: 3.6, height: 1.6))
        let thumb = CGRect(x: 9.9, y: -3.1, width: 1.6, height: 6.2)
        ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
        ctx.fillPath()
    }
}
