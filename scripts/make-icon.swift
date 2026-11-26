// Renders the app icon (pink rounded square, white "F") from the App icon artboard's
// SVG geometry into an AppIcon.appiconset (16–1024 px).
// Usage: swift scripts/make-icon.swift <output .appiconset dir>
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The "F" from the SVG (1024 canvas, y down), as a polygon with 28-px rounded outer corners.
func fPath() -> CGPath {
    // (x, y, rounded)
    let pts: [(CGFloat, CGFloat, Bool)] = [
        (364, 286, true), (688, 286, true), (688, 406, true), (508, 406, false), (508, 490, false),
        (660, 490, true), (660, 606, true), (508, 606, false), (508, 752, true), (364, 752, true),
    ]
    let p = CGMutablePath()
    let n = pts.count
    // Start at the midpoint of the last edge so every corner is handled uniformly.
    let last = pts[n - 1], first = pts[0]
    p.move(to: CGPoint(x: (last.0 + first.0) / 2, y: (last.1 + first.1) / 2))
    for i in 0..<n {
        let cur = pts[i], next = pts[(i + 1) % n]
        if cur.2 {
            p.addArc(tangent1End: CGPoint(x: cur.0, y: cur.1), tangent2End: CGPoint(x: next.0, y: next.1), radius: 28)
        } else {
            p.addLine(to: CGPoint(x: cur.0, y: cur.1))
        }
    }
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    // Flip to SVG coordinates (y down).
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)

    let bg = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [color(0xFF4D8D), color(0xE30066)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()

    ctx.addPath(fPath())
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(px).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(out.path)")
