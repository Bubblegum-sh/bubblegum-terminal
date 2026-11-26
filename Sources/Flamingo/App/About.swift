import AppKit
import FlamingoCore

/// "About Flamingo": name, version and icon from code, so it is complete even when the
/// app runs without its bundle (e.g. from Xcode, where there is no Info.plist or AppIcon).
@MainActor
enum About {
    static func show() {
        let credits = NSAttributedString(
            string: "Run several Claude Code sessions side by side.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Flamingo",
            .applicationVersion: AppVersion.version,
            .version: AppVersion.build,
            .applicationIcon: appIcon,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The bundle's icon when there is one, otherwise the same artwork drawn in code.
    static var appIcon: NSImage {
        if Bundle.main.bundleURL.pathExtension == "app", let icon = NSApp.applicationIconImage { return icon }
        return FlamingoIcon.image(size: 512)
    }
}

/// The app icon (App icon artboard): pink rounded square, gradient #FF4D8D → #E30066, white "F".
/// Same geometry as scripts/make-icon.swift, on the 1024-point icon grid.
enum FlamingoIcon {
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
            ctx.addPath(letterF())
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            return true
        }
    }

    private static func letterF() -> CGPath {
        let pts: [(CGFloat, CGFloat, Bool)] = [
            (364, 286, true), (688, 286, true), (688, 406, true), (508, 406, false), (508, 490, false),
            (660, 490, true), (660, 606, true), (508, 606, false), (508, 752, true), (364, 752, true),
        ]
        let p = CGMutablePath()
        let last = pts[pts.count - 1], first = pts[0]
        p.move(to: CGPoint(x: (last.0 + first.0) / 2, y: (last.1 + first.1) / 2))
        for i in pts.indices {
            let cur = pts[i], next = pts[(i + 1) % pts.count]
            if cur.2 {
                p.addArc(tangent1End: CGPoint(x: cur.0, y: cur.1), tangent2End: CGPoint(x: next.0, y: next.1), radius: 28)
            } else {
                p.addLine(to: CGPoint(x: cur.0, y: cur.1))
            }
        }
        p.closeSubpath()
        return p
    }
}
