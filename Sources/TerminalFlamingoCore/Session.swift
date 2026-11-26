import Foundation

/// Runtime status of a session. Never persisted: restored sessions start as `.paused`.
public enum SessionStatus: String, Equatable, Sendable, CaseIterable {
    /// Saved session whose process is not running (e.g. after app relaunch).
    case paused
    /// Process launched, no hook event yet.
    case starting
    /// `UserPromptSubmit` hook.
    case working
    /// `Notification` hook (permission prompt or question).
    case waiting
    /// `Stop` hook.
    case idle
    /// The claude process exited while the app was running.
    case ended

    public var label: String {
        switch self {
        case .paused: return "Paused"
        case .starting: return "Starting…"
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .idle: return "Your turn"
        case .ended: return "Ended"
        }
    }

    /// Whether a terminal process is expected to be alive in this status.
    public var isRunning: Bool {
        switch self {
        case .starting, .working, .waiting, .idle: return true
        case .paused, .ended: return false
        }
    }
}

public struct Session: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var directory: String
    public var claudeSessionId: String?
    public var isPinned: Bool
    public var isArchived: Bool
    public var createdAt: Date
    public var lastActivity: Date
    public var unread: Bool

    // Runtime only (excluded from CodingKeys).
    public var terminalTitle: String?
    public var lastMessage: String?
    public var status: SessionStatus = .paused
    /// Set when the launch failed because `claude` is not on PATH.
    public var claudeNotFound: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, directory, claudeSessionId, isPinned, isArchived, createdAt, lastActivity, unread
    }

    public init(
        id: UUID = UUID(),
        name: String,
        directory: String,
        claudeSessionId: String? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        lastActivity: Date? = nil,
        unread: Bool = false,
        status: SessionStatus = .paused
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.claudeSessionId = claudeSessionId
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.lastActivity = lastActivity ?? createdAt
        self.unread = unread
        self.status = status
    }

    /// Folder path with the home directory abbreviated to `~`.
    public var displayPath: String {
        Self.abbreviate(directory)
    }

    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Row subtitle: the status message when Claude needs the user, otherwise the
    /// terminal title Claude sets, otherwise a status-based fallback.
    public var subtitle: String {
        if status == .waiting, let m = lastMessage, !m.isEmpty { return m }
        if status == .ended { return claudeNotFound ? "claude not found" : "Session ended" }
        if status.isRunning, let t = Self.cleanTitle(terminalTitle), !t.isEmpty { return t }
        switch status {
        case .paused: return "Paused · " + displayPath
        case .starting: return "Starting… · " + displayPath
        case .working: return "Working · " + displayPath
        case .waiting: return "Needs your answer"
        case .idle: return "Your turn · " + displayPath
        case .ended: return "Session ended"
        }
    }

    /// Claude prefixes its terminal title with spinner glyphs (e.g. "✳ Fix tests"). Strip them.
    public static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.drop { ch in
            !(ch.isLetter || ch.isNumber)
        }
        let s = String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// MARK: - Naming

public enum SessionNaming {
    /// Default name for a folder: its last path component.
    public static func defaultName(for directory: String) -> String {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    /// Returns `base`, or `base 2`, `base 3`, … so it does not clash with `existing`.
    public static func unique(_ base: String, existing: [String]) -> String {
        let taken = Set(existing)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    public static let blankSessionName = "Blank session"

    /// Validates a rename. Returns the trimmed name, or nil when it must be rejected.
    public static func validatedRename(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Relative time

public enum RelativeTime {
    /// "now", "1m", "12m", "3h", "3d", "1w".
    public static func short(from date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 7 { return "\(d)d" }
        return "\(d / 7)w"
    }
}
