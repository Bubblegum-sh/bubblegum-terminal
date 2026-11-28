import Foundation

/// Which agent CLI a session runs. v1 only launches Claude Code; the others are here so the
/// Session Info data model doesn't have to change when they are added.
public enum SessionProviderKind: String, Codable, Equatable, Sendable {
    case claude, codex, gemini

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

/// Token counts for a session. `total` is input + output; cache read is shown separately.
public struct TokenUsage: Equatable, Sendable {
    /// Fresh input: `input_tokens` + `cache_creation_input_tokens` (cache writes).
    public var input: Int
    public var output: Int
    /// `cache_read_input_tokens`: not part of `total`.
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output }
    public var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead)
    }
}

/// What the Session Info popover shows. Every field is optional: a provider fills what its
/// transcript has, and the popover hides what is missing.
public struct SessionInfo: Equatable, Sendable {
    public var provider: SessionProviderKind
    /// Raw model id of the last answer, e.g. "claude-opus-5-5".
    public var model: String?
    /// First and last timestamp in the transcript.
    public var startedAt: Date?
    public var lastActivityAt: Date?
    /// Time between entries, not counting gaps longer than `SessionInfo.idleGap`.
    public var activeDuration: TimeInterval?
    public var tokens: TokenUsage?

    public init(provider: SessionProviderKind, model: String? = nil, startedAt: Date? = nil, lastActivityAt: Date? = nil,
                activeDuration: TimeInterval? = nil, tokens: TokenUsage? = nil) {
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.activeDuration = activeDuration
        self.tokens = tokens
    }

    /// Wall-clock time from the first entry to the last.
    public var totalDuration: TimeInterval? {
        guard let a = startedAt, let b = lastActivityAt else { return nil }
        return max(0, b.timeIntervalSince(a))
    }

    /// Gaps between entries longer than this are idle time.
    public static let idleGap: TimeInterval = 5 * 60

    /// Sum of the gaps between consecutive timestamps that are at most `idleGap` long.
    public static func activeTime(_ timestamps: [Date], idleGap: TimeInterval = idleGap) -> TimeInterval {
        let sorted = timestamps.sorted()
        var total: TimeInterval = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.timeIntervalSince(a)
            if gap <= idleGap { total += gap }
        }
        return total
    }
}

/// The files that make up one session's transcript.
public struct TranscriptLocation: Equatable, Sendable {
    /// The session's own transcript.
    public var main: URL
    /// Transcripts that count towards the session's totals (Claude: subagents).
    public var extra: [URL]

    public init(main: URL, extra: [URL] = []) {
        self.main = main
        self.extra = extra
    }
}

/// Reads Session Info for one agent CLI. `parse` is incremental: `State` remembers how far each
/// file was read, so a growing transcript is only read from that point.
public protocol SessionInfoProvider: Sendable {
    associatedtype State: Sendable
    var kind: SessionProviderKind { get }
    /// The transcript files for a session id, or nil when none was saved.
    func locate(sessionId: String) -> TranscriptLocation?
    func makeState() -> State
    func parse(_ location: TranscriptLocation, state: inout State) -> SessionInfo
}

/// Keeps a provider's parse state for one session, off the main thread.
public actor SessionInfoReader<Provider: SessionInfoProvider> {
    private let provider: Provider
    private let sessionId: String
    private var location: TranscriptLocation?
    private var state: Provider.State

    public init(provider: Provider, sessionId: String) {
        self.provider = provider
        self.sessionId = sessionId
        self.state = provider.makeState()
    }

    /// The main transcript found by the last `refresh`, for watching it.
    public var mainFile: URL? { location?.main }

    /// Reads whatever was added since the last call. nil while the session has no transcript.
    public func refresh() -> SessionInfo? {
        if let loc = location, !FileManager.default.fileExists(atPath: loc.main.path) {
            location = nil
            state = provider.makeState()
        }
        // Found once, but subagent files can appear at any time, so the list is refreshed.
        guard let loc = provider.locate(sessionId: sessionId) else { return nil }
        if location?.main != loc.main { state = provider.makeState() }
        location = loc
        return provider.parse(loc, state: &state)
    }
}

// MARK: - Claude Code

/// Claude Code transcripts: `<projects>/<encoded cwd>/<session id>.jsonl`, plus subagent
/// transcripts in `<session id>/subagents/*.jsonl` next to it.
public struct ClaudeSessionInfoProvider: SessionInfoProvider {
    public let projectsDirectory: URL

    public init(projectsDirectory: URL = ClaudeTranscripts.projectsDirectory()) {
        self.projectsDirectory = projectsDirectory
    }

    public var kind: SessionProviderKind { .claude }

    public func locate(sessionId: String) -> TranscriptLocation? {
        guard let main = ClaudeTranscripts.url(sessionId: sessionId, in: projectsDirectory) else { return nil }
        let subagents = main.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let extra = ((try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return TranscriptLocation(main: main, extra: extra)
    }

    public struct State: Sendable {
        /// Bytes already read, per file path. Always just after a newline.
        var offsets: [String: UInt64] = [:]
        /// One reply is written across several lines that repeat the same usage, so usage is
        /// kept per message id (per file, as ids are only unique within a conversation).
        var usageByMessage: [String: TokenUsage] = [:]
        /// Usage from assistant entries without a message id (counted once each).
        var unkeyedUsage = TokenUsage()
        var model: String?
        /// Main transcript only.
        var timestamps: [Date] = []

        public init() {}
    }

    public func makeState() -> State { State() }

    public func parse(_ location: TranscriptLocation, state: inout State) -> SessionInfo {
        // A main transcript that got shorter was rewritten: start over.
        if let size = Self.fileSize(location.main), let read = state.offsets[location.main.path], size < read {
            state = State()
        }
        Self.read(location.main, isMain: true, state: &state)
        for url in location.extra { Self.read(url, isMain: false, state: &state) }

        let usage = state.usageByMessage.values.reduce(state.unkeyedUsage, +)
        return SessionInfo(
            provider: .claude,
            model: state.model,
            startedAt: state.timestamps.min(),
            lastActivityAt: state.timestamps.max(),
            activeDuration: state.timestamps.isEmpty ? nil : SessionInfo.activeTime(state.timestamps),
            tokens: usage.isEmpty ? nil : usage
        )
    }

    /// Reads the complete lines added to `url` since the last call.
    static func read(_ url: URL, isMain: Bool, state: inout State) {
        let key = url.path
        let offset = state.offsets[key] ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        // A line still being written (no newline yet) is read next time.
        let complete = data[data.startIndex...lastNewline]
        state.offsets[key] = offset + UInt64(complete.count)
        for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            consume(Data(line), file: key, isMain: isMain, state: &state)
        }
    }

    static func consume(_ line: Data, file: String, isMain: Bool, state: inout State) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if isMain, let raw = obj["timestamp"] as? String, let date = parseTimestamp(raw) {
            state.timestamps.append(date)
        }
        guard obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any] else { return }
        if isMain, let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>" {
            state.model = model
        }
        guard let u = message["usage"] as? [String: Any] else { return }
        let usage = TokenUsage(
            input: int(u["input_tokens"]) + int(u["cache_creation_input_tokens"]),
            output: int(u["output_tokens"]),
            cacheRead: int(u["cache_read_input_tokens"])
        )
        if let id = message["id"] as? String, !id.isEmpty {
            state.usageByMessage[file + "#" + id] = usage
        } else {
            state.unkeyedUsage = state.unkeyedUsage + usage
        }
    }

    private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    static func parseTimestamp(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}

// MARK: - Formatting

public enum SessionInfoFormat {
    /// 842 → "842", 184_213 → "184.2K", 2_300_000 → "2.3M".
    public static func tokens(_ n: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if n < 1000 { return "\(n)" }
        // 999_950 would round to "1000.0K".
        if n < 999_950 { return short(Double(n) / 1000, "K") }
        if n < 999_950_000 { return short(Double(n) / 1_000_000, "M") }
        return short(Double(n) / 1_000_000_000, "B")
    }

    /// "<1m", "12m", "1h 24m", "2d 3h".
    public static func duration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d \(h % 24)h"
    }

    /// "just now", "5 min ago", "3 h ago", "2 days ago".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        if h < 24 { return "\(h) h ago" }
        let d = h / 24
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }

    /// "Today, 14:02", "Yesterday, 09:10", "Mon 3 Nov, 14:02" (in the user's locale).
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today, " + time }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday, " + time }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style) + ", " + time
    }

    /// Full date and time for tooltips.
    public static func exact(_ date: Date) -> String {
        date.formatted(date: .complete, time: .standard)
    }
}
