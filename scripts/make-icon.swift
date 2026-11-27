// Renders the app icon (pink rounded square, white "B") from the App icon artboard's
// SVG geometry into an AppIcon.appiconset (16–1024 px).
// Usage: swift scripts/make-icon.swift <output .appiconset dir>
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The "B" from the App icon artboard's SVG (1024 canvas, y down); counters are even-odd holes.
func bPath() -> CGPath {
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

    ctx.addPath(bPath())
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath(using: .evenOdd)

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
