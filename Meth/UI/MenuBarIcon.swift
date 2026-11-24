import AppKit
import MethCore

/// Menu bar icons, readable at a glance without opening the popover:
///   Sober     dimmed, empty syringe (inactive)
///   Bump      syringe ~40 % filled
///   High      syringe completely filled
///   Overdose  filled with system orange (the only non-template icon)
/// Template images follow the menu bar's light/dark/tinted appearance automatically.
/// Icons are static: Meth never animates the menu bar.
@MainActor
enum MenuBarIcon {
    private static var cache: [SleepMode: NSImage] = [:]

    static func image(for mode: SleepMode) -> NSImage {
        if let cached = cache[mode] { return cached }
        let size = NSSize(width: 18, height: 18)
        let isTemplate = mode != .overdose
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Template images keep their alpha, so a translucent Sober icon renders as
            // the system's "inactive" grey in both light and dark menu bars.
            let ink = mode == .sober ? NSColor.black.withAlphaComponent(0.45).cgColor
                : (isTemplate ? NSColor.black.cgColor : NSColor.labelColor.cgColor)
            let liquid: CGColor
            switch mode {
            case .overdose: liquid = NSColor.systemOrange.cgColor
            default: liquid = NSColor.black.cgColor
            }
            let fill: CGFloat = switch mode {
            case .sober: 0
            case .bump: 0.4
            case .high, .overdose: 1
            }
            SyringeGlyph.draw(in: ctx, rect: rect.insetBy(dx: 0.5, dy: 0.5), fill: fill,
                              stroke: ink, liquid: liquid, lineWidth: 1.7)
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "Meth"
        cache[mode] = image
        return image
    }

    /// Short remaining-time label shown next to the icon: "1:42" (h:mm) or "42m".
    static func timeLabel(remainingSeconds: Int) -> String {
        let minutes = max(1, (remainingSeconds + 59) / 60)
        if minutes >= 60 {
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        return String(localized: "\(minutes)m", comment: "Minutes, short")
    }
}
