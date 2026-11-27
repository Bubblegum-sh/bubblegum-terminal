import Foundation

/// One line of the sidebar list.
public enum SidebarItem: Equatable, Identifiable {
    /// Search results heading ("Results · N", "No sessions match").
    case label(String)
    /// A user group's heading. `needsAttention` is only set while the group is collapsed:
    /// an expanded group shows no indicator (its rows show their own).
    case group(id: UUID, count: Int, isOpen: Bool, needsAttention: Bool)
    /// Fixed "Ungrouped · N" heading below the user groups. Collapsible like a group;
    /// `needsAttention` is only set while it is collapsed.
    case ungrouped(count: Int, isOpen: Bool = true, needsAttention: Bool = false)
    /// "New group…" button at the end of the group list.
    case newGroup
    /// Fixed "Archived · N" heading at the bottom, shown even when empty.
    case archivedToggle(count: Int, isOpen: Bool)
    case row(UUID)

    public var id: String {
        switch self {
        case .label(let s): return "label:" + s
        case .group(let id, _, _, _): return "group:" + id.uuidString
        case .ungrouped: return "ungrouped"
        case .newGroup: return "new-group"
        case .archivedToggle: return "archived-toggle"
        case .row(let id): return id.uuidString
        }
    }
}

public enum SidebarLayout {
    /// User groups (by order), then Ungrouped, the New group button, then Archived.
    /// Rows inside a group follow `Session.order`; archived rows keep creation order.
    /// With a query set, a flat list of results instead (F-1).
    public static func items(sessions: [Session], groups: [SessionGroup] = [], query: String, archivedOpen: Bool,
                             ungroupedOpen: Bool = true) -> [SidebarItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let hits = sessions.filter { matches($0, query: q) }
            var items: [SidebarItem] = [.label(hits.isEmpty ? "No sessions match" : "Results · \(hits.count)")]
            items += hits.map { .row($0.id) }
            return items
        }

        var items: [SidebarItem] = []
        for g in GroupOps.sorted(groups) {
            let members = GroupOps.members(of: g.id, in: sessions)
            let open = !g.isCollapsed
            let attention = !open && members.contains { $0.unread || $0.status == .waiting }
            items.append(.group(id: g.id, count: members.count, isOpen: open, needsAttention: attention))
            if open { items += members.map { .row($0.id) } }
        }
        let loose = GroupOps.members(of: nil, in: sessions)
        let looseAttention = !ungroupedOpen && loose.contains { $0.unread || $0.status == .waiting }
        items.append(.ungrouped(count: loose.count, isOpen: ungroupedOpen, needsAttention: looseAttention))
        if ungroupedOpen { items += loose.map { .row($0.id) } }
        items.append(.newGroup)

        // Shown even when empty, like Ungrouped, so a session can always be dragged onto it.
        let archived = sessions.filter { $0.isArchived }
        items.append(.archivedToggle(count: archived.count, isOpen: archivedOpen))
        if archivedOpen { items += archived.map { .row($0.id) } }
        return items
    }

    /// Session ids in the order they are visible (for ⌘1…⌘9 and next/previous).
    public static func visibleIds(_ items: [SidebarItem]) -> [UUID] {
        items.compactMap { if case .row(let id) = $0 { return id } else { return nil } }
    }

    /// Case-insensitive substring match on name, folder path, and the subtitle's own text
    /// (Claude's terminal title or question). Not the status words the subtitle falls back to
    /// ("Paused · …", "Session ended"): "pa" would otherwise match every paused session.
    public static func matches(_ s: Session, query: String) -> Bool {
        var haystack = [s.name, s.directory, s.displayPath]
        if s.status == .waiting, let m = s.lastMessage { haystack.append(m) }
        if s.status.isRunning, let t = Session.cleanTitle(s.terminalTitle) { haystack.append(t) }
        return haystack.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public enum QuickSwitcherFilter {
    public struct Match: Equatable {
        public var id: UUID
        /// Range of the matched characters in the session name, if the name matched.
        public var nameRange: Range<String.Index>?
    }

    /// Sessions whose name or folder path contains `query`; name matches first. Empty query = all non-archived.
    public static func matches(sessions: [Session], query: String) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return sessions.filter { !$0.isArchived }.map { Match(id: $0.id, nameRange: nil) }
        }
        var byName: [Match] = []
        var byOther: [Match] = []
        for s in sessions {
            if let r = s.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                byName.append(Match(id: s.id, nameRange: r))
            } else if s.displayPath.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                byOther.append(Match(id: s.id, nameRange: nil))
            }
        }
        return byName + byOther
    }
}

// MARK: - Drag and drop

/// What is being dragged in the sidebar.
public enum SidebarDragItem: Equatable, Sendable {
    case session(UUID)
    case group(UUID)
}

public enum SidebarDropAction: Equatable {
    /// Into a group (nil = Ungrouped), before a row (nil = at the end).
    case moveSession(UUID, toGroup: UUID?, before: UUID?)
    case archive(UUID)
    /// Before another group (nil = last, above Ungrouped).
    case moveGroup(UUID, before: UUID?)
}

/// Where the sidebar shows the drop: a line above or below an item, or a highlighted heading.
/// Values are `SidebarItem.id`s.
public enum SidebarDropMark: Equatable {
    case lineAbove(String)
    case lineBelow(String)
    case highlight(String)
}

public struct SidebarDrop: Equatable {
    public var action: SidebarDropAction
    public var mark: SidebarDropMark
}

public enum SidebarDropRules {
    /// What dropping `drag` on `target` does. `upperHalf`: the pointer is in the top half of the
    /// target, so rows and group headings insert before it, otherwise after. nil = not a valid drop.
    /// Ungrouped and Archived are fixed: groups can't go below Ungrouped.
    public static func resolve(_ drag: SidebarDragItem, onto target: SidebarItem, upperHalf: Bool,
                               sessions: [Session], groups: [SessionGroup]) -> SidebarDrop? {
        switch (drag, target) {
        case (.session(let id), .row(let rowId)):
            guard let row = sessions.first(where: { $0.id == rowId }) else { return nil }
            if row.isArchived {
                return archive(id, sessions: sessions)
            }
            guard rowId != id else { return nil }
            if upperHalf {
                return SidebarDrop(action: .moveSession(id, toGroup: row.groupId, before: rowId), mark: .lineAbove(target.id))
            }
            let members = GroupOps.members(of: row.groupId, in: sessions).map(\.id)
            let next = members.firstIndex(of: rowId).flatMap { $0 + 1 < members.count ? members[$0 + 1] : nil }
            return SidebarDrop(action: .moveSession(id, toGroup: row.groupId, before: next), mark: .lineBelow(target.id))

        case (.session(let id), .group(let gid, _, _, _)):
            return SidebarDrop(action: .moveSession(id, toGroup: gid, before: nil), mark: .highlight(target.id))

        case (.session(let id), .ungrouped):
            return SidebarDrop(action: .moveSession(id, toGroup: nil, before: nil), mark: .highlight(target.id))

        case (.session(let id), .archivedToggle):
            return archive(id, sessions: sessions)

        case (.group(let id), .group(let gid, _, let isOpen, _)):
            guard gid != id else { return nil }
            if upperHalf {
                return SidebarDrop(action: .moveGroup(id, before: gid), mark: .lineAbove(target.id))
            }
            let order = GroupOps.sorted(groups).map(\.id)
            let next = order.firstIndex(of: gid).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil }
            // The group lands after this one's rows, so draw the line under its last visible row.
            let lastRow = isOpen ? GroupOps.members(of: gid, in: sessions).last.map { SidebarItem.row($0.id).id } : nil
            return SidebarDrop(action: .moveGroup(id, before: next), mark: .lineBelow(lastRow ?? target.id))

        case (.group(let id), .ungrouped), (.group(let id), .newGroup):
            return SidebarDrop(action: .moveGroup(id, before: nil), mark: .lineAbove(SidebarItem.ungrouped(count: 0).id))

        default:
            return nil
        }
    }

    private static func archive(_ id: UUID, sessions: [Session]) -> SidebarDrop? {
        guard sessions.first(where: { $0.id == id })?.isArchived == false else { return nil }
        return SidebarDrop(action: .archive(id), mark: .highlight(SidebarItem.archivedToggle(count: 0, isOpen: true).id))
    }
}
