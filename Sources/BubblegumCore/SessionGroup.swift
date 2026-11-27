import Foundation

/// The 8 group colours. Each has a dark and a light theme value (see the app's Theme).
public enum GroupColor: String, Codable, CaseIterable, Sendable {
    case pink, orange, yellow, green, teal, blue, purple, gray

    public var name: String { rawValue.capitalized }

    /// Colour preselected in the Create group sheet.
    public static let `default` = GroupColor.teal
}

/// A named, coloured group of sessions in the sidebar. Sessions point at it with `Session.groupId`.
public struct SessionGroup: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var color: GroupColor
    /// Position among the user's groups (manual order).
    public var order: Int
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, color: GroupColor = .default, order: Int = 0, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
        self.isCollapsed = isCollapsed
    }

    enum CodingKeys: String, CodingKey { case id, name, color, order, isCollapsed }

    /// Only id and name are required; an unknown colour (from a newer version) falls back to the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = (try? c.decodeIfPresent(GroupColor.self, forKey: .color)) ?? .default
        order = (try? c.decodeIfPresent(Int.self, forKey: .order)) ?? 0
        isCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
    }
}

// MARK: - Naming

public enum GroupNaming {
    public enum Validation: Equatable {
        case valid(String)
        case empty
        case taken
    }

    /// Group names are required and unique (case-insensitive, trimmed).
    /// `excluding` is the group being renamed, so keeping its own name is allowed.
    public static func validate(_ input: String, groups: [SessionGroup], excluding: UUID? = nil) -> Validation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let taken = groups.contains {
            $0.id != excluding && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
        return taken ? .taken : .valid(trimmed)
    }

    /// Sidebar and dialog wording: "Work group".
    public static func title(_ name: String) -> String { name + " group" }
}

// MARK: - Operations

/// Pure edits on sessions and groups. The app's SessionStore calls these and persists the result.
public enum GroupOps {
    /// Groups in sidebar order (by `order`; ties keep array order).
    public static func sorted(_ groups: [SessionGroup]) -> [SessionGroup] {
        groups.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
    }

    /// Non-archived sessions of a group (nil = Ungrouped) in their manual order.
    public static func members(of groupId: UUID?, in sessions: [Session]) -> [Session] {
        sessions.enumerated()
            .filter { !$0.element.isArchived && $0.element.groupId == groupId }
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }

    /// Order value that puts a session at the end of a group.
    public static func nextOrder(in groupId: UUID?, sessions: [Session]) -> Int {
        (sessions.filter { $0.groupId == groupId }.map(\.order).max() ?? -1) + 1
    }

    /// Adds a group at the end of the group list. The name must already be validated.
    @discardableResult
    public static func create(name: String, color: GroupColor, groups: inout [SessionGroup]) -> SessionGroup {
        let g = SessionGroup(name: name, color: color, order: (groups.map(\.order).max() ?? -1) + 1)
        groups.append(g)
        return g
    }

    /// Moves a session into `groupId` (nil = Ungrouped), just before `before` (nil = at the end).
    /// An archived session is unarchived. The target group's orders are renumbered 0…n-1.
    public static func move(_ id: UUID, to groupId: UUID?, before: UUID? = nil, sessions: inout [Session]) {
        guard before != id, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].isArchived = false
        var list = members(of: groupId, in: sessions).map(\.id).filter { $0 != id }
        let at = before.flatMap { list.firstIndex(of: $0) } ?? list.count
        list.insert(id, at: at)
        sessions[i].groupId = groupId
        for (n, sid) in list.enumerated() {
            if let k = sessions.firstIndex(where: { $0.id == sid }) { sessions[k].order = n }
        }
    }

    /// Moves a group just before `before` (nil = last, still above Ungrouped). Orders become 0…n-1.
    public static func moveGroup(_ id: UUID, before: UUID? = nil, groups: inout [SessionGroup]) {
        guard before != id, groups.contains(where: { $0.id == id }) else { return }
        var list = sorted(groups).map(\.id).filter { $0 != id }
        let at = before.flatMap { list.firstIndex(of: $0) } ?? list.count
        list.insert(id, at: at)
        for (n, gid) in list.enumerated() {
            if let k = groups.firstIndex(where: { $0.id == gid }) { groups[k].order = n }
        }
    }

    /// Every session of the group (archived ones too), in its group order.
    public static func allMembers(of groupId: UUID, in sessions: [Session]) -> [Session] {
        sessions.enumerated()
            .filter { $0.element.groupId == groupId }
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }

    /// "Delete group, move sessions to Ungrouped": members keep their order, after the ungrouped ones.
    public static func ungroupAll(_ groupId: UUID, sessions: inout [Session]) {
        var next = nextOrder(in: nil, sessions: sessions)
        for s in allMembers(of: groupId, in: sessions) {
            guard let k = sessions.firstIndex(where: { $0.id == s.id }) else { continue }
            sessions[k].groupId = nil
            sessions[k].order = next
            next += 1
        }
    }
}
