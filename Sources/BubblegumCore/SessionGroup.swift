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
