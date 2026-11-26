import SwiftUI
import TerminalFlamingoCore

/// One sidebar row (L-2, L-3): status dot, name, subtitle, and time/unread or inline actions.
struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let isRenaming: Bool
    let now: Date

    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                renameField
            } else {
                Button {
                    store.select(session.id)
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { store.beginRename(session.id) })
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }

            if isSelected && !isRenaming {
                actions
            } else if !isRenaming {
                meta
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.selectedRowC : (hover ? theme.elevatedC.opacity(0.5) : .clear))
        )
        .opacity(session.isArchived ? 0.72 : 1)
        .onHover { hover = $0 }
        .contextMenu { contextMenu }
    }

    private var content: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(TFFont.rowName)
                    .foregroundStyle(theme.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

    private var actions: some View {
        HStack(spacing: 2) {
            if session.isArchived {
                IconButton(systemImage: "tray.and.arrow.up", label: "Unarchive (⇧⌘A)") {
                    store.toggleArchive(session.id)
                }
            } else {
                IconButton(systemImage: "archivebox", label: "Archive (⇧⌘A)") {
                    store.toggleArchive(session.id)
                }
            }
        }
        .padding(.trailing, 6)
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

    // MARK: Context menu (L-7)

    @ViewBuilder
    private var contextMenu: some View {
        if session.isArchived {
            Button("Unarchive") { store.toggleArchive(session.id) }
            Button("Rename…") { store.beginRename(session.id) }
            Divider()
            Button("Delete Session…", role: .destructive) { store.requestDelete(session.id) }
        } else {
            Button("Rename…") { store.beginRename(session.id) }
            Button("Archive") { store.toggleArchive(session.id) }
            Divider()
            Button("Restart Session") { store.requestRestart(session.id) }
            Button("Show in Finder") { store.showInFinder(session.id) }
            Divider()
            Button("Delete Session…", role: .destructive) { store.requestDelete(session.id) }
        }
    }

    private var accessibilityText: String {
        var parts = [session.name, session.status.label, session.subtitle]
        if session.unread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

/// Inline text field: Enter saves, Esc cancels, empty name is rejected.
private struct RenameField: View {
    let initial: String
    let onCommit: (String) -> Bool
    let onCancel: () -> Void

    @State private var text = ""
    @State private var rejected = false
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        TextField("Session name", text: $text)
            .textFieldStyle(.plain)
            .font(TFFont.rowName)
            .foregroundStyle(theme.text1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.terminalC))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(rejected ? Color.red : theme.accentC, lineWidth: 1))
            .focused($focused)
            .accessibilityLabel("Session name")
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit {
                if !onCommit(text) {
                    rejected = true
                    NSSound.beep()
                    focused = true
                }
            }
            .onExitCommand { onCancel() }
            .onChange(of: text) { _, _ in rejected = false }
    }
}
