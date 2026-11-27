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
    public var selectedId: UUID?
    public var archivedOpen: Bool

    public init(sessions: [Session] = [], selectedId: UUID? = nil, archivedOpen: Bool = true) {
        self.sessions = sessions
        self.selectedId = selectedId
        self.archivedOpen = archivedOpen
    }

    public static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PersistedState.self, from: data)
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
