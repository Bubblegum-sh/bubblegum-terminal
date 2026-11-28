import AppKit
import SwiftUI
import BubblegumCore

/// The open Session Info popover's row, reported by `SessionRow`.
struct SessionInfoAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Places the Session Info popover next to its sidebar row, over the terminal area, with an
/// arrow pointing at the row. Without a row on screen it sits at the top of the terminal area.
/// Closes on ✕, Esc and any click outside it (the click still goes through).
struct SessionInfoOverlay: View {
    let session: Session
    let anchor: Anchor<CGRect>?
    /// Left edge of the terminal area (the sidebar's width).
    let contentLeading: CGFloat

    @EnvironmentObject private var store: SessionStore
    @State private var popoverSize = CGSize(width: SessionInfoPopover.width, height: 320)
    @State private var popoverFrame: CGRect = .zero
    @State private var monitors: [Any] = []

    private static let arrowWidth: CGFloat = 8
    private static let margin: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let row = anchor.map { proxy[$0] }
            let layout = layout(row: row, in: proxy.size)
            ZStack(alignment: .topLeading) {
                SessionInfoPopover(session: session, arrowY: layout.arrowY)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { measured(g.frame(in: .global)) }
                            .onChange(of: g.frame(in: .global)) { _, f in measured(f) }
                    })
                    .offset(x: layout.x, y: layout.y)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .onAppear(perform: installMonitors)
        .onDisappear(perform: removeMonitors)
    }

    private func measured(_ f: CGRect) {
        popoverFrame = f
        if f.size != popoverSize { popoverSize = f.size }
    }

    private func layout(row: CGRect?, in size: CGSize) -> (x: CGFloat, y: CGFloat, arrowY: CGFloat?) {
        let h = popoverSize.height
        let maxY = max(Self.margin, size.height - h - Self.margin)
        guard let row, row.height > 0 else {
            return (contentLeading + 12, min(60, maxY), nil)
        }
        // Arrow tip on the sidebar's edge, level with the row; the popover's top a little above.
        let x = max(row.maxX, contentLeading) + Self.arrowWidth - 4
        let y = min(max(row.midY - 34, Self.margin), maxY)
        let arrowY = row.midY - y
        // Only point at the row while it's within the popover's straight edge.
        let visible = arrowY >= 18 && arrowY <= h - 18
        return (x, y, visible ? arrowY : nil)
    }

    // MARK: Esc and clicks outside

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53, event.window === window, event.window?.attachedSheet == nil else { return event }
            store.closeSessionInfo()
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in
            guard let w = event.window, w === window, let content = w.contentView else { return event }
            // Window coordinates have their origin at the bottom left; SwiftUI's global space
            // (the content view, under the hidden title bar) at the top left.
            let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !popoverFrame.contains(p) { store.closeSessionInfo() }
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }
}

/// Session Info (BUB-6): model, effort, time and tokens for one session.
struct SessionInfoPopover: View {
    let session: Session
    /// Where the arrow on the left edge points, from the top; nil hides it.
    var arrowY: CGFloat?

    static let width: CGFloat = 340

    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @StateObject private var monitor = SessionInfoMonitor()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                if hasModelSection { section { modelSection } }
                if let info = monitor.info, info.startedAt != nil { section { timeSection(info, now: context.date) } }
                if let tokens = monitor.info?.tokens { section(bottom: 16) { tokenSection(tokens) } }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.popoverC))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.popoverBorderC, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if let arrowY {
                PopoverArrow()
                    .fill(theme.popoverC)
                    .overlay(PopoverArrow(open: true).stroke(theme.popoverBorderC, lineWidth: 1))
                    .frame(width: 8, height: 16)
                    .offset(x: -7.5, y: arrowY - 8)
                    .accessibilityHidden(true)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.16), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session info: \(session.name)")
        .onAppear { monitor.track(claudeId: session.claudeSessionId, running: session.status.isRunning) }
        .onChange(of: session.claudeSessionId) { _, id in monitor.track(claudeId: id, running: session.status.isRunning) }
        .onChange(of: session.status.isRunning) { _, running in monitor.track(claudeId: session.claudeSessionId, running: running) }
        .onDisappear { monitor.stop() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusDot(status: session.status)
                Text(session.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button { store.closeSessionInfo() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }
            HStack(spacing: 6) {
                if let g = store.group(session.groupId) {
                    chip {
                        // Rounded square like the sidebar and header, not a status-like dot.
                        GroupSwatch(color: g.color, size: 8)
                        Text(g.name)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Group: \(g.name)")
                }
                chip {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.text2)
                    Text(provider.displayName)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Provider: \(provider.displayName)")
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 12))
    }

    private var provider: SessionProviderKind { monitor.info?.provider ?? .claude }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6, content: content)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.text1)
            .lineLimit(1)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(theme.elevatedC))
    }

    // MARK: Sections

    private func section<C: View>(bottom: CGFloat = 12, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(EdgeInsets(top: 12, leading: 16, bottom: bottom, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(theme.borderC).frame(height: 1) }
    }

    /// The model of the last answer: from the transcript, else what the hooks reported.
    private var modelId: String? { monitor.info?.model ?? session.modelInfo?.model }
    /// Effort comes from the same source as the header indicator (saved with the session).
    private var effort: ModelInfo? { session.modelInfo?.effortLevel == nil ? nil : session.modelInfo }
    private var hasModelSection: Bool { modelId != nil || effort != nil }

    @ViewBuilder
    private var modelSection: some View {
        GroupLabel(text: "Model")
        if let id = modelId {
            row("Model") {
                Text(ModelInfo.displayName(for: id)).help(id)
            }
        }
        if let e = effort, let level = e.effortLevel, let label = e.effortLabel {
            row("Effort") {
                HStack(spacing: 8) {
                    EffortBars(level: level)
                    Text(label)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Effort: \(label)")
        }
    }

    @ViewBuilder
    private func timeSection(_ info: SessionInfo, now: Date) -> some View {
        GroupLabel(text: "Time")
        if let start = info.startedAt {
            row("Started") { Text(SessionInfoFormat.day(start, now: now)).help(SessionInfoFormat.exact(start)) }
        }
        if let last = info.lastActivityAt {
            row("Last activity") { Text(SessionInfoFormat.relative(last, now: now)).help(SessionInfoFormat.exact(last)) }
        }
        if let active = info.activeDuration {
            row("Duration", alignment: .firstTextBaseline) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(SessionInfoFormat.duration(active) + " active")
                    if let total = info.totalDuration {
                        Text(SessionInfoFormat.duration(total) + " since start")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text3)
                    }
                }
            }
            .help("Active time leaves out gaps longer than 5 minutes")
        }
    }

    @ViewBuilder
    private func tokenSection(_ t: TokenUsage) -> some View {
        HStack(alignment: .firstTextBaseline) {
            GroupLabel(text: "Tokens")
            Spacer(minLength: 0)
            Text(SessionInfoFormat.tokens(t.total))
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.text1)
                .help("\(t.total.formatted()) tokens: input + output")
                .accessibilityLabel("Total \(t.total.formatted()) tokens")
        }
        if t.total > 0 {
            TokenSplitBar(input: t.input, output: t.output)
                .padding(.vertical, 2)
        }
        tokenRow("Input", t.input, swatch: theme.tokenInputC)
            .help("Input and cache writes: \(t.input.formatted()) tokens")
        tokenRow("Output", t.output, swatch: theme.accentC)
            .help("\(t.output.formatted()) tokens")
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(theme.text3, lineWidth: 1)
                .frame(width: 8, height: 8)
                .padding(.trailing, 8)
            (Text("Cache read").foregroundStyle(theme.text2) + Text(" · not in total").foregroundStyle(theme.text3))
            Spacer(minLength: 8)
            Text(SessionInfoFormat.tokens(t.cacheRead))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text2)
        }
        .font(.system(size: 12))
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Line().stroke(theme.borderC, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
        }
        .help("\(t.cacheRead.formatted()) tokens read from the prompt cache")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cache read, not in total: \(SessionInfoFormat.tokens(t.cacheRead))")
    }

    private func tokenRow(_ label: String, _ n: Int, swatch: Color) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8).padding(.trailing, 8)
            Text(label).foregroundStyle(theme.text2)
            Spacer(minLength: 8)
            Text(SessionInfoFormat.tokens(n))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text1)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(SessionInfoFormat.tokens(n))")
    }

    private func row<V: View>(_ label: String, alignment: VerticalAlignment = .center, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: alignment, spacing: 8) {
            Text(label).foregroundStyle(theme.text2)
            Spacer(minLength: 8)
            value()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text1)
                .lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

/// Input / output split of the token total.
private struct TokenSplitBar: View {
    let input: Int
    let output: Int
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { g in
            let total = max(1, input + output)
            let w = g.size.width * CGFloat(input) / CGFloat(total)
            HStack(spacing: 0) {
                Rectangle().fill(theme.tokenInputC).frame(width: w)
                Rectangle().fill(theme.accentC)
            }
        }
        .frame(height: 6)
        .background(theme.borderC)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("Input \(percent(input)) percent, output \(percent(output)) percent")
    }

    private func percent(_ n: Int) -> Int {
        let total = input + output
        return total == 0 ? 0 : Int((Double(n) * 100 / Double(total)).rounded())
    }
}

/// The arrow on the popover's left edge, tip pointing left. `open` leaves out the right side,
/// so its outline joins the popover's border.
private struct PopoverArrow: Shape {
    var open = false

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        if !open { p.closeSubpath() }
        return p
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
