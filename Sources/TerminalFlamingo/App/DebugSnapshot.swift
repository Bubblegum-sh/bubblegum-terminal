#if DEBUG
import AppKit

/// Development aid: `TF_SNAPSHOT=/path/prefix` writes PNGs of the main window
/// (optionally after toggling UI via `TF_SNAPSHOT_STEPS`), then quits.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(store: SessionStore, settings: AppSettings) {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["TF_SNAPSHOT"] else { return }
        let steps = (env["TF_SNAPSHOT_STEPS"] ?? "main").split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            for step in steps {
                switch step {
                case "light": settings.appearance = .light
                case "dark": settings.appearance = .dark
                case "switcher": store.toggleQuickSwitcher()
                case "search": store.query = "pa"
                case "clear": store.query = ""; store.showQuickSwitcher = false
                case "rename": store.beginRename()
                default: break
                }
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: "\(prefix)-\(step).png")
                if let id = store.selectedId, let tv = store.terminals.view(for: id) {
                    tv.selectAll()
                    let text = tv.getSelection() ?? "<no selection>"
                    tv.selectNone()
                    let info = "bg=\(tv.nativeBackgroundColor) fg=\(tv.nativeForegroundColor) font=\(tv.font.fontName) \(tv.font.pointSize)\n"
                    try? (info + text).write(toFile: "\(prefix)-\(step).txt", atomically: true, encoding: .utf8)
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if !view.isFlipped { /* CALayer renders with y-up in a bitmap context already */ }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
