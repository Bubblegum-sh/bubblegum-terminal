import Foundation

/// Builds the command that starts `claude` for a session (S-2).
public enum LaunchCommand {
    /// Exit code the launch script uses when `claude` is not on PATH.
    public static let claudeNotFoundExitCode: Int32 = 127

    /// Single-quotes a string for POSIX shells.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `-c` script run by the login + interactive shell.
    public static func script(directory: String, resumeId: String?) -> String {
        var claude = "exec claude"
        if let resumeId, !resumeId.isEmpty { claude += " --resume " + shellQuote(resumeId) }
        let notFound = "printf '\\r\\n\\033[1mclaude was not found in your PATH.\\033[0m\\r\\n"
            + "Install Claude Code, or check that ~/.zshrc (or ~/.zprofile) adds it to PATH.\\r\\n'; "
            + "exit \(claudeNotFoundExitCode)"
        return "cd \(shellQuote(directory)) && { command -v claude >/dev/null 2>&1 || { \(notFound); }; \(claude); }"
    }

    /// Arguments for `$SHELL`: login + interactive, so ~/.zprofile and ~/.zshrc apply.
    public static func arguments(directory: String, resumeId: String?) -> [String] {
        ["-l", "-i", "-c", script(directory: directory, resumeId: resumeId)]
    }

    /// The user's shell, falling back to zsh.
    public static func shell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let sh = environment["SHELL"], !sh.isEmpty, FileManager.default.isExecutableFile(atPath: sh) { return sh }
        if let pw = getpwuid(getuid()), let p = pw.pointee.pw_shell {
            let s = String(cString: p)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    /// Variables a running Claude Code sets for its own child processes.
    public static let inheritedSessionMarkers = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_CHILD_NOTES_DIR", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SSE_PORT", "BUBBLEGUM_SESSION_ID", "FLAMINGO_SESSION_ID",
    ]

    /// Environment for the child: the app's environment plus terminal and session variables.
    public static func environment(sessionId: UUID, base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = base
        // Don't leak a parent claude session's markers into ours (e.g. when the app
        // was launched from a terminal running Claude Code).
        for key in inheritedSessionMarkers { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Bubblegum"
        env["BUBBLEGUM_SESSION_ID"] = sessionId.uuidString
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

/// sessions.json contents.
public struct PersistedState: Codable, Equatable {
    public var sessions: [Session]
    public var groups: [SessionGroup]
    public var selectedId: UUID?
    public var archivedOpen: Bool

    public init(sessions: [Session] = [], groups: [SessionGroup] = [], selectedId: UUID? = nil, archivedOpen: Bool = true) {
        self.sessions = sessions
        self.groups = groups
        self.selectedId = selectedId
        self.archivedOpen = archivedOpen
    }

    enum CodingKeys: String, CodingKey { case sessions, groups, selectedId, archivedOpen }

    /// Sessions that can't be decoded are skipped (counted in `skippedSessions`) rather than
    /// failing the whole file; the top level only needs a `sessions` array.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = try c.nestedUnkeyedContainer(forKey: .sessions)
        var sessions: [Session] = []
        var skipped = 0
        while !list.isAtEnd {
            if let s = try? list.decode(Session.self) {
                sessions.append(s)
            } else {
                skipped += 1
                _ = try? list.decode(Skip.self) // advance past the bad element
            }
        }
        // Groups are optional (files from before groups have none); a bad group is dropped.
        var groups: [SessionGroup] = []
        if var g = try? c.nestedUnkeyedContainer(forKey: .groups) {
            while !g.isAtEnd {
                if let group = try? g.decode(SessionGroup.self) { groups.append(group) } else { _ = try? g.decode(Skip.self) }
            }
        }
        self.groups = groups
        // A session whose group is gone goes back to Ungrouped, after the sessions already there.
        let known = Set(groups.map(\.id))
        var next = GroupOps.nextOrder(in: nil, sessions: sessions)
        for i in sessions.indices where sessions[i].groupId.map({ !known.contains($0) }) == true {
            sessions[i].groupId = nil
            sessions[i].order = next
            next += 1
        }
        self.sessions = sessions
        self.skippedSessions = skipped
        selectedId = try? c.decodeIfPresent(UUID.self, forKey: .selectedId)
        archivedOpen = (try? c.decodeIfPresent(Bool.self, forKey: .archivedOpen)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(groups, forKey: .groups)
        try c.encodeIfPresent(selectedId, forKey: .selectedId)
        try c.encode(archivedOpen, forKey: .archivedOpen)
    }

    /// Not persisted: how many sessions in the loaded file could not be read.
    public private(set) var skippedSessions = 0

    /// Accepts any JSON value, so the container moves on to the next element.
    private struct Skip: Decodable { init(from decoder: Decoder) {} }

    public static func == (a: PersistedState, b: PersistedState) -> Bool {
        a.sessions == b.sessions && a.groups == b.groups && a.selectedId == b.selectedId && a.archivedOpen == b.archivedOpen
    }

    /// Parses sessions.json. nil when the file is missing or unreadable; never touches the file.
    public static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    static func decode(_ data: Data) throws -> PersistedState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(PersistedState.self, from: data)
    }

    public struct LoadResult {
        public var state: PersistedState?
        /// Where a copy of an unreadable (or partly unreadable) file was kept, if one was.
        public var backup: URL?
    }

    /// Loads sessions.json for the app. The next save overwrites the file, so when it can't be
    /// read (or some sessions can't), the original is kept as `sessions.json.unreadable-<date>`
    /// first instead of being lost.
    public static func loadForApp(from url: URL, now: Date = Date()) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return LoadResult() }
        let state = try? decode(data)
        guard state == nil || state!.skippedSessions > 0 else { return LoadResult(state: state) }
        return LoadResult(state: state, backup: keepCopy(of: url, now: now))
    }

    static func keepCopy(of url: URL, now: Date) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".unreadable-" + f.string(from: now))
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            NSLog("Bubblegum: could not keep a copy of \(url.path): \(error)")
            return nil
        }
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
