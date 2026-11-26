import SwiftUI
import FlamingoCore

/// Main window: fixed-width sidebar + detail, content under the (hidden) title bar.
struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = settings.theme
        ZStack {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 268)
                Rectangle().fill(theme.borderC).frame(width: 1)
                SessionDetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if store.showQuickSwitcher {
                QuickSwitcherView()
                    .transition(.opacity)
            }
            if store.showNewSession {
                NewSessionView()
                    .transition(.opacity)
            }
        }
        .background(theme.windowC)
        .background(WindowChrome())
        .foregroundStyle(theme.text1)
        .tint(theme.accentFillC)
        .ignoresSafeArea()
        .environment(\.theme, theme)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { applyTerminalAppearance() }
        .onChange(of: settings.appearance) { _, _ in applyTerminalAppearance() }
        .onChange(of: settings.fontSize) { _, _ in applyTerminalAppearance() }
        .sheet(isPresented: $store.showHookSheet) {
            HookSetupSheet()
                .environment(\.theme, theme)
        }
        .alert(store.errorTitle, isPresented: errorBinding, presenting: store.errorMessage) { _ in
            Button("OK") { store.errorMessage = nil }
        } message: { Text($0) }
        .confirmationDialog(
            "Restart “\(store.session(store.confirmRestartId)?.name ?? "")”?",
            isPresented: restartBinding, titleVisibility: .visible
        ) {
            Button("Restart") { if let id = store.confirmRestartId { store.restart(id) } }
            Button("Cancel", role: .cancel) { store.confirmRestartId = nil }
        } message: {
            Text("Claude is working. Restarting stops the current task and resumes the conversation.")
        }
        .confirmationDialog(
            "Delete “\(store.session(store.confirmDeleteId)?.name ?? "")”?",
            isPresented: deleteBinding, titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) { if let id = store.confirmDeleteId { store.delete(id) } }
            Button("Cancel", role: .cancel) { store.confirmDeleteId = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    /// S-8: the confirmation says when a running claude process will be stopped.
    private var deleteMessage: String {
        let base = "The session is removed from Flamingo. Claude’s transcript on disk is not touched."
        guard let id = store.confirmDeleteId, store.terminals.isRunning(id) else { return base }
        let working = store.session(id)?.status == .working
        return (working ? "Claude is working. " : "") + "Its claude process will be stopped. " + base
    }

    private func applyTerminalAppearance() {
        store.terminals.applyAppearance(theme: settings.theme, fontSize: settings.fontSize)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }
    private var restartBinding: Binding<Bool> {
        Binding(get: { store.confirmRestartId != nil }, set: { if !$0 { store.confirmRestartId = nil } })
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { store.confirmDeleteId != nil }, set: { if !$0 { store.confirmDeleteId = nil } })
    }
}

/// Gives the window a 52 pt transparent title bar (an empty unified toolbar), so the
/// traffic lights are vertically centered on the sidebar's top row and the 52 pt
/// detail header, as on the Main window artboard.
struct WindowChrome: NSViewRepresentable {
    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "FlamingoMain")
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)

            // In full screen macOS draws the toolbar as an opaque band above the content,
            // covering our top row and header. There are no traffic lights to align with
            // there, so hide it while in full screen.
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak window] _ in
                    window?.toolbar?.isVisible = false
                },
                center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak window] _ in
                    window?.toolbar?.isVisible = true
                },
            ]
            toolbar.isVisible = !window.styleMask.contains(.fullScreen)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Lets an empty area of our custom title region drag the window (and double-click to zoom).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Small square icon button used in the sidebar and toolbar (26 pt, rounded hover).
struct IconButton: View {
    let systemImage: String
    let label: String
    var tint: Color? = nil
    var size: CGFloat = 13
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? theme.text2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? theme.text3.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 8 pt status dot with a tooltip (status is never conveyed by color alone).
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8
    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .fill(theme.statusC(status))
            .frame(width: size, height: size)
            .help(status.label)
            .accessibilityLabel("Status: \(status.label)")
    }
}
