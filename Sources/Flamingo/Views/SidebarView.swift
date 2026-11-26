import SwiftUI
import FlamingoCore

struct SidebarView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Top row (design: 14 pt top padding, 26 pt row, 6 pt below). The traffic
            // lights sit on the left of this row; WindowChrome centers them on it.
            HStack(spacing: 0) {
                WindowDragArea()
                IconButton(systemImage: "plus", label: "New session (⌘T)", size: 14) {
                    store.showNewSessionSheet()
                }
            }
            .frame(height: 26)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .padding(.trailing, 2)
            .background(WindowDragArea())

            searchField

            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.sidebarItems) { item in
                            itemView(item, now: context.date)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .accessibilityLabel("Sessions")

            footer
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .background(theme.sidebarC)
        .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
    }

    // MARK: Search (F-1)

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.text3)
                .accessibilityHidden(true)
            TextField("Search sessions", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .accessibilityLabel("Search sessions (⌘F)")
                .onExitCommand {
                    store.query = ""
                    searchFocused = false
                    store.focusTerminal()
                }
                .onSubmit {
                    if let first = store.visibleIds.first { store.select(first) }
                }
            if store.query.isEmpty {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.text3)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.sidebarC))
                    .accessibilityHidden(true)
            } else {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.text3)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.elevatedC))
        .padding(.horizontal, 2)
    }

    // MARK: List items (L-1)

    @ViewBuilder
    private func itemView(_ item: SidebarItem, now: Date) -> some View {
        switch item {
        case .label(let text):
            GroupLabel(text: text)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .padding(.horizontal, 8)
        case .archivedToggle(let count, let isOpen):
            Button {
                store.archivedOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    GroupLabel(text: "Archived · \(count)")
                    Spacer()
                }
                .foregroundStyle(theme.text3)
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .accessibilityLabel("Archived, \(count) sessions")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
        case .row(let id):
            if let s = store.session(id) {
                SessionRow(
                    session: s,
                    isSelected: store.selectedId == id,
                    isRenaming: store.renamingId == id,
                    now: now
                )
            }
        }
    }

    // MARK: Footer (H-2)

    private var footer: some View {
        HStack(spacing: 8) {
            if store.hooksInstalled {
                Circle().fill(theme.statusC(.idle)).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("Hooks connected")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.statusC(.working))
                    .accessibilityHidden(true)
                Text("Hooks not installed")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                Button("Install") { store.installHooks() }
                    .controlSize(.small)
                    .help("Install Claude Code hooks so statuses and notifications work")
            }
            Spacer(minLength: 0)
            IconButton(systemImage: "gearshape", label: "Settings (⌘,)") { openSettings() }
        }
        .padding(.top, 8)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .overlay(alignment: .top) { Rectangle().fill(theme.borderC).frame(height: 1) }
    }
}

struct GroupLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(TFFont.groupLabel)
            .tracking(0.6)
            .foregroundStyle(theme.text3)
            .accessibilityAddTraits(.isHeader)
    }
}
