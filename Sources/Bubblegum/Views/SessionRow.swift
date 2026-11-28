import SwiftUI
import BubblegumCore

/// One sidebar row (L-2, L-3): status dot, name, subtitle, and time/unread.
/// Hovering (or tabbing to it) swaps the time/unread for a "…" menu with the row's actions.
struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let isRenaming: Bool
    let now: Date
    /// Shown as a small colour square after the name where rows are not under their
    /// group heading (search results, Archived).
    var groupTag: SessionGroup? = nil

    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var hover = false
    @FocusState private var menuFocused: Bool
    @FocusState private var rowFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                renameField
            } else {
                // A tap gesture, not a Button: on macOS a Button keeps the mouse press to itself,
                // so the sidebar's drag (onDrag on this row) would never start.
                // Focusable like a button: Tab reaches it (per the system's keyboard navigation
                // setting), Return or Space opens the session.
                content
                    .onTapGesture { store.select(session.id) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { store.beginRename(session.id) })
                    .focusable(interactions: .activate)
                    .focused($rowFocused)
                    .focusEffectDisabled()
                    .onKeyPress(keys: [.return, .space]) { _ in store.select(session.id); return .handled }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { store.select(session.id) }
            }

            if !isRenaming {
                meta
                    .opacity(showsMenu ? 0 : 1)
                    .overlay(alignment: .trailing) { menuButton }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.selectedRowC : (hover ? theme.elevatedC.opacity(0.5) : .clear))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accentC, lineWidth: 2).opacity(rowFocused ? 1 : 0))
        .opacity(session.isArchived ? 0.72 : 1)
        .onHover { hover = $0 }
        .contextMenu { SessionMenuItems(session: session) }
        .anchorPreference(key: SessionInfoAnchorKey.self, value: .bounds) { store.infoSessionId == session.id ? $0 : nil }
    }

    private var showsMenu: Bool { hover || menuFocused }

    /// Same spot as a group heading's "…": 3 + 22/2 = 14 pt from the edge, over the unread dot.
    private var menuButton: some View {
        Menu {
            SessionMenuItems(session: session)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .focused($menuFocused)
        .opacity(showsMenu ? 1 : 0)
        .padding(.trailing, 3)
        .help("\(session.name) actions")
        .accessibilityLabel("\(session.name) actions")
    }

    private var content: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.name)
                        .font(TFFont.rowName)
                        .foregroundStyle(theme.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let g = groupTag {
                        GroupSwatch(color: g.color, size: 7).help(GroupNaming.title(g.name))
                    }
                }
                Text(session.subtitle)
                    .font(TFFont.subtitle)
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .contentShape(Rectangle())
    }

    private var meta: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(RelativeTime.short(from: session.lastActivity, now: now))
                .font(TFFont.time)
                .foregroundStyle(theme.text3)
            if session.unread {
                Circle().fill(theme.accentC).frame(width: 8, height: 8)
                    .help("Unread")
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.trailing, 10)
        .allowsHitTesting(false)
    }

    // MARK: Rename (L-5)

    private var renameField: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 4) {
                RenameField(initial: session.name) { name in
                    store.commitRename(session.id, to: name)
                } onCancel: {
                    store.cancelRename()
                }
                Text("↩ save · esc cancel")
                    .font(TFFont.subtitle)
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    private var accessibilityText: String {
        var parts = [session.name, session.status.label, session.subtitle]
        if let g = groupTag { parts.append(GroupNaming.title(g.name)) }
        if session.unread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

/// Inline text field: Enter saves, Esc cancels, an invalid name is rejected.
/// Clicking outside the field (or moving focus away) saves; an invalid name is reverted.
/// Used for session rows and group headings.
struct RenameField: View {
    let initial: String
    var label = "Session name"
    var font = TFFont.rowName
    let onCommit: (String) -> Bool
    let onCancel: () -> Void

    @State private var text = ""
    @State private var rejected = false
    @State private var done = false
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(theme.text1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.terminalC))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(rejected ? Color.red : theme.accentC, lineWidth: 1))
            .focused($focused)
            .accessibilityLabel(label)
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
                installClickMonitor()
            }
            .onDisappear { removeClickMonitor() }
            .onSubmit {
                guard !done else { return }
                if onCommit(text) {
                    done = true
                } else {
                    rejected = true
                    NSSound.beep()
                    focused = true
                }
            }
            .onExitCommand { cancel() }
            .onChange(of: focused) { was, isNow in
                if was && !isNow { commitOrRevert() }
            }
            .onChange(of: text) { _, _ in rejected = false }
    }

    private func cancel() {
        guard !done else { return }
        done = true
        onCancel()
    }

    /// Leaving the field saves the name; an invalid (empty) one falls back to the old name.
    private func commitOrRevert() {
        guard !done else { return }
        done = true
        if !onCommit(text) { onCancel() }
    }

    /// Mouse-downs elsewhere don't always take focus from the field (e.g. empty sidebar
    /// space or plain buttons), so watch clicks directly.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if !Self.isInsideEditingField(event) { commitOrRevert() }
            return event
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    private static func isInsideEditingField(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let hit = window.contentView?.hitTest(event.locationInWindow)
        else { return false }
        return hit === editor || hit.isDescendant(of: editor)
            || (editor.delegate as? NSView).map { hit === $0 || hit.isDescendant(of: $0) } ?? false
    }
}

/// A session's actions (L-7): the row's "…" menu and its right-click menu.
struct SessionMenuItems: View {
    let session: Session
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        if session.isArchived {
            Button { store.toggleArchive(session.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
            Button { store.beginRename(session.id) } label: { Label("Rename…", systemImage: "pencil") }
            sessionInfo
            Button { store.exportSession(session.id) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
        } else {
            Button { store.beginRename(session.id) } label: { Label("Rename…", systemImage: "pencil") }
            sessionInfo
            Button { store.toggleArchive(session.id) } label: { Label("Archive", systemImage: "archivebox") }
            Divider()
            Button { store.requestRestart(session.id) } label: { Label("Restart Session", systemImage: "arrow.clockwise") }
            Button { store.exportSession(session.id) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
        }
        Divider()
        Button(role: .destructive) { store.requestDelete(session.id) } label: { Label("Delete Session…", systemImage: "trash") }
    }

    /// Shows ⌘I in the menu; the shortcut itself is the menu bar's Session › Session Info.
    private var sessionInfo: some View {
        Button { store.toggleSessionInfo(session.id) } label: { Label("Session Info", systemImage: "info.circle") }
            .keyboardShortcut("i", modifiers: .command)
    }
}
