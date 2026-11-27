import AppKit
import SwiftUI
import BubblegumCore

private let monoFont = Font(terminalFont(size: 12))
private let warnText = Color(nsColor: .hex(0xE8C79A))

/// Where the branch pill sits, so the switcher can open under it.
struct BranchPillAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Toolbar pill: branch (or detached commit), uncommitted-change count, chevron.
/// Not shown when the session's folder isn't a git work tree.
struct BranchPill: View {
    @ObservedObject var git: GitMonitor
    @Binding var isOpen: Bool
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        if let s = git.status {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    BranchGlyph()
                        .stroke(theme.text2, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(s.displayName)
                        .font(Font(terminalFont(size: 11)))
                        .foregroundStyle(theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if s.changes > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(theme.statusC(.working)).frame(width: 6, height: 6)
                            Text("\(s.changes)")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text3)
                        .help("\(s.changes) uncommitted change\(s.changes == 1 ? "" : "s")")
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.text3)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(maxWidth: 230)
                .background(Capsule().fill(hover || isOpen ? theme.elevatedC : .clear))
                .overlay(Capsule().stroke(theme.borderC, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { hover = $0 }
            .help("Switch branch")
            .accessibilityLabel("Git branch \(s.displayName)\(s.changes > 0 ? ", \(s.changes) uncommitted changes" : ""), switch branch")
            .anchorPreference(key: BranchPillAnchorKey.self, value: .bounds) { $0 }
        }
    }
}

/// The branch popover (design: BranchSwitcher artboard). ↑↓ select, ↩ switch, esc close.
struct BranchSwitcherPanel: View {
    @ObservedObject var git: GitMonitor
    let close: () -> Void

    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var branches: [GitBranch] = []
    @State private var recentNames: [String] = []
    @State private var loaded = false
    @State private var index = 0
    @State private var hovered: String?
    @State private var error: String?
    @State private var creating = false
    @State private var newName = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var newFocused: Bool

    private enum Item: Identifiable {
        case label(String)
        case branch(GitBranch, current: Bool, selectable: Int?)

        var id: String {
            switch self {
            case .label(let t): return "label:" + t
            case .branch(let b, let current, _): return (current ? "current:" : "") + b.id
            }
        }
    }

    private var currentName: String { git.status?.displayName ?? "HEAD" }

    /// Rows in display order plus the branches ↑↓ moves through.
    private var model: (items: [Item], choices: [GitBranch]) {
        var items: [Item] = []
        var choices: [GitBranch] = []
        func add(_ b: GitBranch, current: Bool = false) {
            if current {
                items.append(.branch(b, current: true, selectable: nil))
            } else {
                items.append(.branch(b, current: false, selectable: choices.count))
                choices.append(b)
            }
        }
        let current = git.status?.branch
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let hits = Git.filter(branches, query: query)
            items.append(.label(hits.isEmpty ? "NO BRANCHES MATCH" : "RESULTS · \(hits.count)"))
            for b in hits { add(b, current: !b.isRemote && b.name == current) }
            return (items, choices)
        }
        let s = Git.sections(branches, current: current, recentNames: recentNames)
        items.append(.label("CURRENT"))
        let status = git.status
        add(s.current ?? GitBranch(name: currentName, isRemote: false,
                                    subject: status?.branch == nil ? "Detached HEAD" : "No commits yet",
                                    ahead: status?.ahead ?? 0, behind: status?.behind ?? 0),
            current: true)
        if !s.recent.isEmpty { items.append(.label("RECENT")); s.recent.forEach { add($0) } }
        if !s.otherLocal.isEmpty { items.append(.label("OTHER LOCAL")); s.otherLocal.forEach { add($0) } }
        if !s.remote.isEmpty { items.append(.label("REMOTE · \(s.remote.count)")); s.remote.forEach { add($0) } }
        return (items, choices)
    }

    var body: some View {
        let m = model
        VStack(spacing: 0) {
            searchField(choices: m.choices)

            if let error {
                banner(text: error, dot: Color.red, fg: theme.isDark ? Color(nsColor: .hex(0xFFB4B4)) : .red, bg: Color.red.opacity(0.14))
            } else if let n = git.status?.changes, n > 0 {
                banner(text: "\(n) uncommitted change\(n == 1 ? "" : "s") will move with you",
                       dot: theme.statusC(.working),
                       fg: theme.isDark ? warnText : theme.statusC(.working),
                       bg: theme.statusC(.working).opacity(0.12))
            }

            list(m)

            footer(choices: m.choices)
        }
        .frame(width: 370)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.elevatedC))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.borderC, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch branch")
        .task { await load() }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: query) { _, _ in index = 0; error = nil }
    }

    // MARK: Parts

    private func searchField(choices: [GitBranch]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .accessibilityHidden(true)
            TextField("Find a branch…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.text1)
                .focused($searchFocused)
                .accessibilityLabel("Find a branch")
                .onKeyPress(.upArrow) { move(-1, count: choices.count); return .handled }
                .onKeyPress(.downArrow) { move(1, count: choices.count); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onSubmit {
                    if choices.indices.contains(index) { pick(choices[index]) }
                    else if !query.isEmpty { startCreating() }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.windowC))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(searchFocused ? theme.accentC : theme.borderC, lineWidth: 1))
        .padding(10)
    }

    private func banner(text: String, dot: Color, fg: Color, bg: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(dot).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(bg))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func list(_ m: (items: [Item], choices: [GitBranch])) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !loaded {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
                    }
                    ForEach(m.items) { item in
                        switch item {
                        case .label(let t):
                            Text(t)
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(theme.text3)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        case .branch(let b, let current, let sel):
                            row(b, current: current, highlighted: sel == index && sel != nil)
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: index) { _, i in
                if m.choices.indices.contains(i) { proxy.scrollTo(m.choices[i].id) }
            }
        }
    }

    private func row(_ b: GitBranch, current: Bool, highlighted: Bool) -> some View {
        let rowId = (current ? "current:" : "") + b.id
        return Button { if !current { pick(b) } } label: {
            HStack(spacing: 10) {
                Group {
                    if current {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.accentC)
                            .accessibilityLabel("Current branch")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name)
                        .font(monoFont)
                        .foregroundStyle(theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !b.subject.isEmpty {
                        Text(b.subject)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(meta(b, current: current))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7).fill(
                current ? theme.selectedRowC : (highlighted || hovered == rowId ? theme.borderC : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(git.busy)
        .onHover { hovered = $0 ? rowId : (hovered == rowId ? nil : hovered) }
        .accessibilityAddTraits(highlighted || current ? .isSelected : [])
    }

    private func meta(_ b: GitBranch, current: Bool) -> String {
        var parts: [String] = []
        let ahead = current ? (git.status?.ahead ?? b.ahead) : b.ahead
        let behind = current ? (git.status?.behind ?? b.behind) : b.behind
        var track = ""
        if ahead > 0 { track += "↑\(ahead)" }
        if behind > 0 { track += (track.isEmpty ? "" : " ") + "↓\(behind)" }
        if !track.isEmpty { parts.append(track) }
        if b.date != .distantPast { parts.append(Git.age(b.date)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func footer(choices: [GitBranch]) -> some View {
        HStack(spacing: 8) {
            if creating {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .accessibilityHidden(true)
                TextField("new-branch-name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(monoFont)
                    .foregroundStyle(theme.text1)
                    .focused($newFocused)
                    .accessibilityLabel("New branch name")
                    .onSubmit { create() }
                    .onKeyPress(.escape) { stopCreating(); return .handled }
                    .onChange(of: newName) { _, _ in error = nil }
                if git.busy { ProgressView().controlSize(.mini) }
                Text("↩ create · esc").foregroundStyle(theme.text3)
            } else {
                Button { startCreating() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text2)
                        Text("New branch from ").foregroundStyle(theme.text1)
                            + Text(currentName).font(monoFont).foregroundColor(theme.accentTextC)
                            + Text("…").foregroundColor(theme.text1)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(git.busy)
                Spacer(minLength: 4)
                if git.busy { ProgressView().controlSize(.mini) }
                Text("↩ switch · esc").foregroundStyle(theme.text3).fixedSize()
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, creating ? 14 : 6)
        .padding(.vertical, creating ? 10 : 6)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.sidebarC)
        .overlay(alignment: .top) { Rectangle().fill(theme.borderC).frame(height: 1) }
    }

    // MARK: Actions

    private func load() async {
        async let b = git.loadBranches()
        async let r = git.recentNames()
        branches = await b
        recentNames = await r
        loaded = true
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        index = (index + delta + count) % count
    }

    private func pick(_ b: GitBranch) {
        guard !git.busy else { return }
        error = nil
        let locals = Set(branches.filter { !$0.isRemote }.map(\.name))
        Task {
            do {
                try await git.switchTo(b, localNames: locals)
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func startCreating() {
        newName = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        creating = true
        error = nil
        DispatchQueue.main.async { newFocused = true }
    }

    private func stopCreating() {
        creating = false
        error = nil
        DispatchQueue.main.async { searchFocused = true }
    }

    private func create() {
        guard !git.busy else { return }
        let name = newName
        Task {
            do {
                try await git.createBranch(name)
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Branch icon: two commits on a line and a third branching off.
private struct BranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var p = Path()
        for (x, y) in [(4.5, 3.5), (4.5, 12.5), (11.5, 5.5)] {
            p.addEllipse(in: CGRect(x: rect.minX + (x - 1.8) * s, y: rect.minY + (y - 1.8) * s, width: 3.6 * s, height: 3.6 * s))
        }
        p.move(to: pt(4.5, 5.3)); p.addLine(to: pt(4.5, 10.7))
        p.move(to: pt(11.5, 7.3)); p.addCurve(to: pt(4.5, 10.7), control1: pt(11.5, 9.8), control2: pt(9.5, 10.3))
        return p
    }
}
