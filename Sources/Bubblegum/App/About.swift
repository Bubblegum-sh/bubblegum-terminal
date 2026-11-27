import AppKit
import BubblegumCore

/// "About Bubblegum": name, version and icon from code, so it is complete even when the
/// app runs without its bundle (e.g. from Xcode, where there is no Info.plist or AppIcon).
@MainActor
enum About {
    static func show() {
        let credits = NSAttributedString(
            string: "Run several Claude Code sessions side by side.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Bubblegum",
            .applicationVersion: AppVersion.version,
            .version: AppVersion.build,
            .applicationIcon: appIcon,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AppVersion.copyright,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The bundle's icon when there is one, otherwise the same artwork drawn in code.
    static var appIcon: NSImage {
        if Bundle.main.bundleURL.pathExtension == "app", let icon = NSApp.applicationIconImage { return icon }
        return BubblegumIcon.image(size: 512)
    }
}

/// The app icon (App icon artboard): pink rounded square, gradient #FF4D8D → #E30066, white "B".
/// Same geometry as scripts/make-icon.swift, on the 1024-point icon grid.
enum BubblegumIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 1024
            ctx.scaleBy(x: s, y: s)
            let bg = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
            ctx.saveGState()
            ctx.addPath(bg)
            ctx.clip()
            let colors = [NSColor.hex(0xFF4D8D).cgColor, NSColor.hex(0xE30066).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
            }
            ctx.restoreGState()
            ctx.addPath(letterB())
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
    }

    private static func letterB() -> CGPath {
        // SVG: M392 286 H600 C690 286 740 336 740 404 C740 448 718 480 684 494 C730 508 760 546 760 600
        //      C760 684 700 738 610 738 H392 A28 28 0 0 1 364 710 V314 A28 28 0 0 1 392 286 Z
        //      M496 384 H582 C612 384 628 400 628 422 C628 444 612 460 582 460 H496 Z
        //      M496 552 H596 C630 552 648 570 648 596 C648 622 630 640 596 640 H496 Z, translated x −50.
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - 50, y: y) }
        let p = CGMutablePath()
        p.move(to: pt(392, 286))
        p.addLine(to: pt(600, 286))
        p.addCurve(to: pt(740, 404), control1: pt(690, 286), control2: pt(740, 336))
        p.addCurve(to: pt(684, 494), control1: pt(740, 448), control2: pt(718, 480))
        p.addCurve(to: pt(760, 600), control1: pt(730, 508), control2: pt(760, 546))
        p.addCurve(to: pt(610, 738), control1: pt(760, 684), control2: pt(700, 738))
        p.addLine(to: pt(392, 738))
        p.addArc(tangent1End: pt(364, 738), tangent2End: pt(364, 710), radius: 28)
        p.addLine(to: pt(364, 314))
        p.addArc(tangent1End: pt(364, 286), tangent2End: pt(392, 286), radius: 28)
        p.closeSubpath()
        // Counters (holes; fill with even-odd).
        p.move(to: pt(496, 384))
        p.addLine(to: pt(582, 384))
        p.addCurve(to: pt(628, 422), control1: pt(612, 384), control2: pt(628, 400))
        p.addCurve(to: pt(582, 460), control1: pt(628, 444), control2: pt(612, 460))
        p.addLine(to: pt(496, 460))
        p.closeSubpath()
        p.move(to: pt(496, 552))
        p.addLine(to: pt(596, 552))
        p.addCurve(to: pt(648, 596), control1: pt(630, 552), control2: pt(648, 570))
        p.addCurve(to: pt(596, 640), control1: pt(648, 622), control2: pt(630, 640))
        p.addLine(to: pt(496, 640))
        p.closeSubpath()
        return p
    }
}
