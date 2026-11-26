import Foundation

/// One line of the sidebar list.
public enum SidebarItem: Equatable, Identifiable {
    case label(String)
    case archivedToggle(count: Int, isOpen: Bool)
    case row(UUID)

    public var id: String {
        switch self {
        case .label(let s): return "label:" + s
        case .archivedToggle: return "archived-toggle"
        case .row(let id): return id.uuidString
        }
    }
}

public enum SidebarLayout {
    /// L-1 groups (Pinned, Sessions · N, Archived · N), or F-1 results when a query is set.
    /// Order inside groups is the order of `sessions` (creation order, L-8).
    public static func items(sessions: [Session], query: String, archivedOpen: Bool) -> [SidebarItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let hits = sessions.filter { matches($0, query: q) }
            var items: [SidebarItem] = [.label(hits.isEmpty ? "No sessions match" : "Results · \(hits.count)")]
            items += hits.map { .row($0.id) }
            return items
        }

        let pinned = sessions.filter { $0.isPinned && !$0.isArchived }
        let rest = sessions.filter { !$0.isPinned && !$0.isArchived }
        let archived = sessions.filter { $0.isArchived }

        var items: [SidebarItem] = []
        if !pinned.isEmpty {
            items.append(.label("Pinned"))
            items += pinned.map { .row($0.id) }
        }
        items.append(.label("Sessions · \(rest.count)"))
        items += rest.map { .row($0.id) }
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

    /// Case-insensitive substring match on name, subtitle and folder path.
    public static func matches(_ s: Session, query: String) -> Bool {
        let haystack = [s.name, s.subtitle, s.directory, s.displayPath]
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
