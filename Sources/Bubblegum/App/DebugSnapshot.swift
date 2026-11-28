#if DEBUG
import AppKit
import BubblegumCore

/// Development aid: `BUBBLEGUM_SNAPSHOT=/path/prefix` writes PNGs of the main window
/// (optionally after toggling UI via `BUBBLEGUM_SNAPSHOT_STEPS`), then quits.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(store: SessionStore, settings: AppSettings) {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["BUBBLEGUM_SNAPSHOT"] else { return }
        let steps = (env["BUBBLEGUM_SNAPSHOT_STEPS"] ?? "main").split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            for step in steps {
                switch step {
                case "bigger": settings.increaseFont()
                case "smaller": settings.decreaseFont()
                case "light": settings.appearance = .light
                case "dark": settings.appearance = .dark
                case "switcher": store.toggleQuickSwitcher()
                case "search": store.query = "pa"
                case "clear": store.query = ""; store.showQuickSwitcher = false
                case "rename": store.beginRename()
                case "info": store.toggleSessionInfo()
                case "newsession": store.showNewSessionSheet()
                case "down": store.newSessionIndex += 1
                case "filter": store.newSessionFilter = "par"
                case "close": store.closeNewSessionSheet()
                case "ended": store.debugEnd()
                case "first": if let id = store.visibleIds.first { store.select(id, focusTerminal: false) }
                case "last": if let id = store.visibleIds.last { store.select(id, focusTerminal: false) }
                case "togglearchived": store.archivedOpen.toggle()
                case "toggleungrouped": store.ungroupedOpen.toggle()
                case "collapsegroup": if let g = store.sortedGroups.first { store.toggleCollapsed(g.id) }
                case "newingroup": store.showNewSessionSheet(inGroup: store.sortedGroups.first?.id)
                case "newgroup": store.showGroupSheet()
                case "groupfromsession": store.showGroupSheet(movingSession: store.selectedId)
                case "takenname": store.groupSheet = GroupSheetRequest(mode: .fromSession, sessionId: store.selectedId, suggestedName: "work")
                case "newfolder":
                    if let s = store.selected {
                        store.groupSheet = GroupSheetRequest(mode: .newFolder, sessionId: s.id, suggestedName: SessionNaming.defaultName(for: s.directory))
                    }
                case "deletegroup": if let g = store.sortedGroups.first { store.requestDeleteGroup(g.id) }
                case "renamegroup": if let g = store.sortedGroups.first { store.beginRenameGroup(g.id) }
                case "colors":
                    let c = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
                    let h = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB)!
                    let hex = { (c: NSColor) in String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) }
                    try? "accent=\(hex(c)) selection=\(hex(h))".write(toFile: "\(prefix)-accent.txt", atomically: true, encoding: .utf8)
                case "fullscreen", "windowed":
                    NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 })?.toggleFullScreen(nil)
                    try? await Task.sleep(for: .seconds(5))
                case "exportmd":
                    // Renders the selected session's transcript (or BUBBLEGUM_EXPORT_TRANSCRIPT) without a save panel.
                    if let s = store.selected {
                        let url = env["BUBBLEGUM_EXPORT_TRANSCRIPT"].map { URL(fileURLWithPath: $0) }
                            ?? s.claudeSessionId.flatMap { ClaudeTranscripts.url(sessionId: $0) }
                        if let url, let data = try? Data(contentsOf: url) {
                            let md = TranscriptExporter.markdown(transcript: data, metadata: .init(title: s.name, directory: s.directory, model: s.modelInfo, claudeSessionId: s.claudeSessionId))
                            try? md.write(toFile: "\(prefix)-export.md", atomically: true, encoding: .utf8)
                        }
                    }
                case "about":
                    About.show()
                    try? await Task.sleep(for: .seconds(1))
                    if let panel = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel && !String(describing: type(of: $0)).contains("Menu") && $0.frame.width > 150 }),
                       let view = panel.contentView?.superview, let layer = view.layer {
                        let sc = panel.backingScaleFactor, sz = view.bounds.size
                        if let ctx = CGContext(data: nil, width: Int(sz.width * sc), height: Int(sz.height * sc), bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            ctx.scaleBy(x: sc, y: sc); layer.render(in: ctx)
                            if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-aboutpanel.png")) }
                        }
                    }
                case "askdelete": if let id = store.selectedId { store.requestDelete(id) }
                case "delete": if let id = store.confirmDeleteId ?? store.selectedId { store.delete(id) }
                case "hittest": hitTest(to: "\(prefix)-hits.txt")
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

    /// Reports which view receives a click at the "+" button and toolbar buttons,
    /// and where the traffic lights are (points from the window's top-left).
    private static func hitTest(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let frameView = window.contentView?.superview else { return }
        let h = frameView.bounds.height
        var lines: [String] = []
        if let close = window.standardWindowButton(.closeButton), let sv = close.superview {
            let r = sv.convert(close.frame, to: nil)
            lines.append("closeButton center y from top = \(h - r.midY)")
        }
        let w = frameView.bounds.width
        for (name, x, yTop) in [("plus", 255.0, 27.0), ("pencil", w - 63, 26.0), ("restart", w - 31, 26.0), ("search", 120.0, 66.0)] {
            let hit = frameView.hitTest(NSPoint(x: x, y: h - yTop))
            var chain: [String] = []
            var v: NSView? = hit
            while let cur = v, chain.count < 4 { chain.append(String(describing: type(of: cur))); v = cur.superview }
            lines.append("\(name) @(\(Int(x)),\(Int(yTop))): \(chain.joined(separator: " < "))")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
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
