// Meth's app icon: an orange-and-white capsule on a sky-blue tile, drawn on Apple's
// 1024-pt macOS icon grid (824-pt body, superellipse corners). Used by main.swift.

import CoreGraphics

func grad(_ cs: [CGColor], _ l: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cs as CFArray, locations: l)!
}
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { srgb(hex, a) }

/// Apple's continuous-corner tile approximated by a superellipse (n = 5) on the 1024 grid.
func squircle(_ r: CGRect, n: CGFloat = 4) -> CGPath {
    let p = CGMutablePath(); let a = r.width/2, b = r.height/2, cx = r.midX, cy = r.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2/n)
        let y = cy + b * (st >= 0 ? 1 : -1) * pow(abs(st), 2/n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}

struct Style { let name: String; let bgTop: UInt32; let bgBot: UInt32; let capA: [UInt32]; let capB: [UInt32]; let shadow: UInt32; let dark: Bool }
// capX = [edge-dark, body, light, specular]

let pillStyle = Style(name: "C", bgTop: 0x8FE1FF, bgBot: 0x2A7BF6, capA: [0xD97706, 0xFF9F0A, 0xFFD27A, 0xFFF7E6],
                      capB: [0xB9C2CF, 0xF2F4F7, 0xFFFFFF, 0xFFFFFF], shadow: 0x0B2A6B, dark: false)

/// A capsule along +x, centred at origin, length L, diameter D, shaded as a cylinder.
func capsule(_ ctx: CGContext, L: CGFloat, D: CGFloat, st: Style) {
    let r = D/2
    let full = CGPath(roundedRect: CGRect(x: -L/2, y: -r, width: L, height: D), cornerWidth: r, cornerHeight: r, transform: nil)
    func half(_ left: Bool, _ cols: [UInt32]) {
        ctx.saveGState()
        ctx.addPath(full); ctx.clip()
        ctx.clip(to: left ? CGRect(x: -L/2 - 2, y: -r - 2, width: L/2 + 2, height: D + 4) : CGRect(x: 0, y: -r - 2, width: L/2 + 2, height: D + 4))
        // cylinder shading across the diameter (bottom edge dark → body → light → specular → body → top edge)
        ctx.drawLinearGradient(grad([c(cols[0]), c(cols[1]), c(cols[2]), c(cols[1]), c(cols[0])], [0, 0.28, 0.62, 0.86, 1]),
                               start: CGPoint(x: 0, y: -r), end: CGPoint(x: 0, y: r), options: [])
        // ends fall off slightly (rounded caps catch less light)
        let endX = left ? -L/2 : L/2
        ctx.drawLinearGradient(grad([c(cols[0], 0.35), c(cols[0], 0)], [0, 1]),
                               start: CGPoint(x: endX, y: 0), end: CGPoint(x: endX + (left ? r*0.9 : -r*0.9), y: 0), options: [])
        ctx.restoreGState()
    }
    half(true, st.capA); half(false, st.capB)
    // seam: the white half overlaps slightly — a thin shadowed ring
    ctx.saveGState(); ctx.addPath(full); ctx.clip()
    ctx.setFillColor(c(0x000000, 0.18)); ctx.fill(CGRect(x: -3, y: -r, width: 6, height: D))
    ctx.setFillColor(c(0xFFFFFF, 0.55)); ctx.fill(CGRect(x: 3, y: -r, width: 3, height: D))
    // specular highlight streak along the top
    let hl = CGPath(roundedRect: CGRect(x: -L/2 + r*0.55, y: r*0.38, width: L - r*1.1, height: r*0.26), cornerWidth: r*0.13, cornerHeight: r*0.13, transform: nil)
    ctx.addPath(hl); ctx.setFillColor(c(0xFFFFFF, 0.55)); ctx.fillPath()
    // bounce light on the bottom edge
    ctx.setStrokeColor(c(0xFFFFFF, 0.22)); ctx.setLineWidth(5)
    ctx.addPath(CGPath(roundedRect: CGRect(x: -L/2 + 6, y: -r + 6, width: L - 12, height: D - 12), cornerWidth: r - 6, cornerHeight: r - 6, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()
    // crisp outline
    ctx.addPath(full); ctx.setStrokeColor(c(0x000000, 0.12)); ctx.setLineWidth(2); ctx.strokePath()
}

func drawPillIcon(_ ctx: CGContext, _ st: Style = pillStyle) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(body)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: c(0, 0.3))
    ctx.addPath(tile); ctx.setFillColor(c(st.bgBot)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(grad([c(st.bgTop), c(st.bgBot)], [0, 1]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    if st.dark {
        ctx.drawRadialGradient(grad([c(st.capA[1], 0.35), c(st.capA[1], 0)], [0, 1]), startCenter: CGPoint(x: 512, y: 520), startRadius: 0, endCenter: CGPoint(x: 512, y: 520), endRadius: 420, options: [])
    }
    // contact shadow under the pill
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 352); ctx.scaleBy(x: 1, y: 0.22)
    ctx.drawRadialGradient(grad([c(st.shadow, st.dark ? 0.6 : 0.32), c(st.shadow, 0)], [0, 1]), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330, options: [])
    ctx.restoreGState()
    // pill
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 548); ctx.rotate(by: .pi/4 - 0.05)
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 40, color: c(st.shadow, st.dark ? 0.7 : 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    capsule(ctx, L: 640, D: 236, st: st)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    // top sheen + edge
    ctx.drawLinearGradient(grad([c(0xFFFFFF, st.dark ? 0.10 : 0.35), c(0xFFFFFF, 0)], [0, 1]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
    ctx.restoreGState()
    ctx.addPath(tile); ctx.setStrokeColor(c(st.dark ? 0xFFFFFF : 0x000000, st.dark ? 0.12 : 0.08)); ctx.setLineWidth(3); ctx.strokePath()
}


/// The capsule alone on a transparent full-bleed 1024 canvas: the foreground layer of
/// Meth/AppIcon.icon (Icon Composer). macOS 26 supplies the tile shape, fill and shadow.
func drawPillLayer(_ ctx: CGContext, _ st: Style = pillStyle) {
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 530)
    ctx.rotate(by: .pi/4 - 0.05)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    capsule(ctx, L: 700, D: 258, st: st)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}
