import Foundation

/// A folder previously used for a session.
public struct RecentProject: Codable, Equatable, Sendable {
    public var path: String
    public var lastOpened: Date

    public init(path: String, lastOpened: Date) {
        self.path = path
        self.lastOpened = lastOpened
    }

    public var name: String { SessionNaming.defaultName(for: path) }
    public var displayPath: String { Session.abbreviate(path) }
}

/// Recent projects list, persisted as `recents.json` in Application Support.
public struct RecentProjects: Codable, Equatable, Sendable {
    /// How many rows the New session sheet shows (⌘1…⌘9).
    public static let visibleLimit = 9
    /// Stored entries; more than shown so pruned folders can be backfilled.
    public static let storedLimit = 30

    public private(set) var entries: [RecentProject]

    public init(entries: [RecentProject] = []) {
        self.entries = entries
    }

    /// Records a project session start. Blank sessions in the home folder are not recorded.
    public mutating func record(path: String, at date: Date = Date(), home: String = NSHomeDirectory()) {
        let normalized = Self.normalize(path)
        guard normalized != Self.normalize(home) else { return }
        entries.removeAll { Self.normalize($0.path) == normalized }
        entries.insert(RecentProject(path: normalized, lastOpened: date), at: 0)
        entries.sort { $0.lastOpened > $1.lastOpened }
        if entries.count > Self.storedLimit { entries.removeLast(entries.count - Self.storedLimit) }
    }

    /// Drops entries whose folder no longer exists. Returns true if anything changed.
    @discardableResult
    public mutating func prune(exists: (String) -> Bool = RecentProjects.directoryExists) -> Bool {
        let before = entries.count
        entries.removeAll { !exists($0.path) }
        return entries.count != before
    }

    /// Newest first, at most 9, filtered by a case-insensitive substring of name or path.
    public func visible(filter: String = "") -> [RecentProject] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = entries.sorted { $0.lastOpened > $1.lastOpened }
        let hits = q.isEmpty ? sorted : sorted.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.path.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.displayPath.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return Array(hits.prefix(Self.visibleLimit))
    }

    public static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: Persistence

    public static func load(from url: URL) -> RecentProjects {
        guard let data = try? Data(contentsOf: url) else { return RecentProjects() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(RecentProjects.self, from: data)) ?? RecentProjects()
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Row meta

    /// "2 sessions · 1h ago", "1 session · today", "yesterday", "3d ago", "1w ago".
    public static func meta(sessionCount: Int, lastOpened: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = relativeDay(lastOpened, now: now, calendar: calendar)
        guard sessionCount > 0 else { return when }
        return "\(sessionCount) session\(sessionCount == 1 ? "" : "s") · \(when)"
    }

    static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 3 * 3600 { return "\(s / 3600)h ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "yesterday" }
        let days = s / 86400
        if days < 7 { return "\(max(days, 2))d ago" }
        return "\(days / 7)w ago"
    }
}
