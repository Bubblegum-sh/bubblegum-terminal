import SwiftUI
import TerminalFlamingoCore

/// F-2: ⌘K palette. ↑↓ select, ↩ open, ⌘R rename, esc close.
struct QuickSwitcherView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var matches: [QuickSwitcherFilter.Match] {
        QuickSwitcherFilter.matches(sessions: store.sessions, query: query)
    }

    var body: some View {
        let list = matches
        ZStack(alignment: .top) {
            Color.black.opacity(0.42)
                .onTapGesture { store.closeQuickSwitcher() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.text2)
                        .accessibilityHidden(true)
                    TextField("Go to session", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .accessibilityLabel("Go to session")
                        .onKeyPress(.upArrow) { move(-1, count: list.count); return .handled }
                        .onKeyPress(.downArrow) { move(1, count: list.count); return .handled }
                        .onKeyPress(.escape) { store.closeQuickSwitcher(); return .handled }
                        .onSubmit { open(list) }
                    Text("\(list.count) of \(store.sessions.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle().fill(theme.borderC).frame(height: 1)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            if list.isEmpty {
                                Text("No sessions match")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.text3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                                if let s = store.session(m.id) {
                                    row(s, match: m, highlighted: i == index)
                                        .id(m.id)
                                        .onTapGesture { index = i; open(list) }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: index) { _, i in
                        if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                    }
                }

                HStack(spacing: 16) {
                    Text("↑↓ select"); Text("↩ open"); Text("⌘R rename"); Text("esc close")
                    Spacer()
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.sidebarC)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.elevatedC))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.borderC))
            .shadow(color: .black.opacity(0.5), radius: 25, y: 20)
            .padding(.top, 150)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Go to session")
        }
        .onAppear {
            query = ""
            index = 0
            DispatchQueue.main.async { focused = true }
            syncHighlight(list)
        }
        .onChange(of: query) { _, _ in
            index = 0
            syncHighlight(matches)
        }
        .onChange(of: index) { _, _ in syncHighlight(matches) }
    }

    private func row(_ s: Session, match: QuickSwitcherFilter.Match, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            StatusDot(status: s.status)
            VStack(alignment: .leading, spacing: 2) {
                highlightedName(s.name, range: match.nameRange)
                    .font(TFFont.rowName)
                    .lineLimit(1)
                Text(s.subtitle)
                    .font(TFFont.subtitle)
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text("\(s.isArchived ? "Archived" : s.status.label) · \(RelativeTime.short(from: s.lastActivity))")
                if s.unread {
                    Circle().fill(theme.accentC).frame(width: 8, height: 8).accessibilityLabel("Unread")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.text3)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(highlighted ? theme.selectedRowC : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    private func highlightedName(_ name: String, range: Range<String.Index>?) -> Text {
        guard let range else { return Text(name).foregroundColor(theme.text1) }
        return Text(name[name.startIndex..<range.lowerBound]).foregroundColor(theme.text1)
            + Text(name[range]).foregroundColor(theme.accentTextC)
            + Text(name[range.upperBound...]).foregroundColor(theme.text1)
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        index = (index + delta + count) % count
    }

    private func syncHighlight(_ list: [QuickSwitcherFilter.Match]) {
        store.quickSwitcherHighlight = list.indices.contains(index) ? list[index].id : nil
    }

    private func open(_ list: [QuickSwitcherFilter.Match]) {
        guard list.indices.contains(index) else { return }
        let id = list[index].id
        store.showQuickSwitcher = false
        store.query = ""
        if store.session(id)?.isArchived == true { store.archivedOpen = true }
        store.select(id)
    }
}
