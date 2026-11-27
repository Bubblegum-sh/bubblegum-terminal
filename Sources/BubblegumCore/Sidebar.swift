import Foundation

/// One line of the sidebar list.
public enum SidebarItem: Equatable, Identifiable {
    /// Search results heading ("Results · N", "No sessions match").
    case label(String)
    /// A user group's heading. `needsAttention` is only set while the group is collapsed:
    /// an expanded group shows no indicator (its rows show their own).
    case group(id: UUID, count: Int, isOpen: Bool, needsAttention: Bool)
    /// Fixed "Ungrouped · N" heading below the user groups.
    case ungrouped(count: Int)
    /// "New group…" button at the end of the group list.
    case newGroup
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
    public static func items(sessions: [Session], groups: [SessionGroup] = [], query: String, archivedOpen: Bool) -> [SidebarItem] {
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
        items.append(.ungrouped(count: loose.count))
        items += loose.map { .row($0.id) }
        items.append(.newGroup)

        let archived = sessions.filter { $0.isArchived }
        if !archived.isEmpty {
            items.append(.archivedToggle(count: archived.count, isOpen: archivedOpen))
            if archivedOpen { items += archived.map { .row($0.id) } }
        }
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
