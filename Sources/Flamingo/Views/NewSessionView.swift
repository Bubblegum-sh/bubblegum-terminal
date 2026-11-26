import SwiftUI
import FlamingoCore

/// S-1: the New session sheet (⌘T / "+"): Open project…, Blank session, Recent projects.
struct NewSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @FocusState private var filterFocused: Bool

    var body: some View {
        let list = store.visibleRecents
        ZStack(alignment: .top) {
            Color.black.opacity(0.42)
                .onTapGesture { store.closeNewSessionSheet() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Text("New session")
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("⌘T").font(.system(size: 11)).foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 4)

                HStack(spacing: 10) {
                    OptionCard(
                        icon: "folder",
                        iconTint: theme.accentC,
                        title: "Open project…",
                        detail: "Choose a folder to work in",
                        hint: "⌘O",
                        monoHint: false
                    ) { store.openProjectWithPicker() }
                    OptionCard(
                        icon: "apple.terminal",
                        iconTint: theme.text2,
                        title: "Blank session",
                        detail: "No project — starts in your home folder",
                        hint: "~ · ⌘N",
                        monoHint: true
                    ) { store.startBlankSession() }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 16)

                Rectangle().fill(theme.borderC).frame(height: 1)

                HStack(spacing: 10) {
                    GroupLabel(text: "Recent projects")
                    Spacer()
                    filterField
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)

                recentList(list)

                HStack(spacing: 16) {
                    Text("↑↓ select")
                    Text("↩ open")
                    Text(list.count > 1 ? "⌘1–⌘\(list.count) quick open" : "⌘1 quick open")
                    Spacer()
                    Text("esc cancel")
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(theme.sidebarC)
            }
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.elevatedC))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.borderC))
            .shadow(color: .black.opacity(0.5), radius: 25, y: 20)
            .padding(.top, 110)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("New session")
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { DispatchQueue.main.async { filterFocused = true } }
        .onChange(of: store.newSessionFilter) { _, _ in store.newSessionIndex = 0 }
        .onExitCommand { store.closeNewSessionSheet() }
    }

    // MARK: Filter field (keyboard focus lives here so typing filters)

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.text3)
                .accessibilityHidden(true)
            TextField("Filter recent", text: $store.newSessionFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .accessibilityLabel("Filter recent projects")
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { store.closeNewSessionSheet(); return .handled }
                .onSubmit { store.openRecent(at: store.newSessionIndex) }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.sidebarC))
    }

    // MARK: Recent list

    @ViewBuilder
    private func recentList(_ list: [RecentProject]) -> some View {
        VStack(spacing: 2) {
            if list.isEmpty {
                Text(store.newSessionFilter.isEmpty
                     ? "No recent projects yet — open a project to start"
                     : "No recent projects match")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
            }
            ForEach(Array(list.enumerated()), id: \.element.path) { i, project in
                RecentRow(
                    project: project,
                    meta: RecentProjects.meta(sessionCount: store.sessionCount(inFolder: project.path), lastOpened: project.lastOpened),
                    shortcut: "⌘\(i + 1)",
                    focused: i == store.newSessionIndex
                ) {
                    store.openRecent(at: i)
                }
                .onHover { if $0 { store.newSessionIndex = i } }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent projects")
    }

    private func move(_ delta: Int) {
        let count = store.visibleRecents.count
        guard count > 0 else { return }
        store.newSessionIndex = (store.newSessionIndex + delta + count) % count
    }
}

private struct OptionCard: View {
    let icon: String
    let iconTint: Color
    let title: String
    let detail: String
    let hint: String
    let monoHint: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(iconTint)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(theme.text2)
                    Text(hint)
                        .font(monoHint ? .system(size: 11, design: .monospaced) : .system(size: 11))
                        .foregroundStyle(theme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? theme.selectedRowC : theme.sidebarC))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.borderC))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(title) (\(hint.replacingOccurrences(of: "~ · ", with: "")))")
    }
}

private struct RecentRow: View {
    let project: RecentProject
    let meta: String
    let shortcut: String
    let focused: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text3)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text1)
                        .lineLimit(1)
                    Text(project.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                    .fixedSize()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(focused ? theme.selectedRowC : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(project.name), \(project.displayPath), \(meta)")
        .accessibilityHint("Opens a new session in this folder. Shortcut \(shortcut)")
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}
