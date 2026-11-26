import Foundation

/// Filesystem locations used by the app. Injectable so tests can use a temp folder.
public struct AppPaths: Sendable {
    public var supportDirectory: URL
    public var claudeDirectory: URL

    public init(supportDirectory: URL, claudeDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.claudeDirectory = claudeDirectory
    }

    /// The real locations. For development, `TF_SUPPORT_DIR` overrides the app's own folder;
    /// Claude's folder then defaults to `<TF_SUPPORT_DIR>/claude` (or `TF_CLAUDE_DIR`) so a
    /// dev run can never write hooks into the real ~/.claude.
    public static var standard: AppPaths {
        standard(environment: ProcessInfo.processInfo.environment)
    }

    public static func standard(environment env: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppPaths {
        let support = env["TF_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let claude = env["TF_CLAUDE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support?.appendingPathComponent("claude", isDirectory: true)
        return AppPaths(
            supportDirectory: support ?? home.appendingPathComponent("Library/Application Support/TerminalFlamingo", isDirectory: true),
            claudeDirectory: claude ?? home.appendingPathComponent(".claude", isDirectory: true)
        )
    }

    public var sessionsFile: URL { supportDirectory.appendingPathComponent("sessions.json") }
    public var recentsFile: URL { supportDirectory.appendingPathComponent("recents.json") }
    public var hookScript: URL { supportDirectory.appendingPathComponent("hook.sh") }
    public var eventsDirectory: URL { supportDirectory.appendingPathComponent("events", isDirectory: true) }
    public var claudeSettings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    public var claudeSettingsBackup: URL { claudeDirectory.appendingPathComponent("settings.json.tf-backup") }
}

public enum HookInstallError: LocalizedError, Equatable {
    case invalidSettingsJSON(String)
    case settingsNotAnObject
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSettingsJSON(let path):
            return "\(path) is not valid JSON. Fix or move the file, then try again. It was not changed."
        case .settingsNotAnObject:
            return "~/.claude/settings.json must contain a JSON object. It was not changed."
        case .io(let message):
            return message
        }
    }
}

/// Installs the hook script and merges hook entries into `~/.claude/settings.json` (spec section 6).
public struct HookInstaller: Sendable {
    public static let events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop"]
    /// Substring identifying our entries in settings.json.
    public static let marker = "TerminalFlamingo/hook.sh"

    public static let script = """
    #!/bin/sh
    [ -n "$TF_SESSION_ID" ] || exit 0
    DIR="$HOME/Library/Application Support/TerminalFlamingo/events"
    mkdir -p "$DIR" || exit 0
    PAYLOAD=$(cat)
    [ -n "$PAYLOAD" ] || PAYLOAD=null
    TMP="$DIR/.$$.tmp"
    printf '{"tf":"%s","payload":%s}\\n' "$TF_SESSION_ID" "$PAYLOAD" > "$TMP" && mv "$TMP" "$DIR/$(date +%s)-$$.json"
    exit 0

    """

    public var paths: AppPaths

    public init(paths: AppPaths = .standard) {
        self.paths = paths
    }

    /// The command string stored in settings.json. The path contains a space, so it is quoted.
    public var hookCommand: String { "\"\(paths.hookScript.path)\"" }

    // MARK: Status

    /// Installed = script exists and is executable AND all four events contain our entry.
    public func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: paths.hookScript.path),
              let data = try? Data(contentsOf: paths.claudeSettings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Self.containsAllEntries(obj, command: hookCommand)
    }

    static func containsAllEntries(_ settings: [String: Any], command: String? = nil) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0, command: command) }
            }
        }
    }

    /// Our entry: the command contains the standard marker, or is exactly this install's command.
    static func isOurs(_ hook: [String: Any], command: String? = nil) -> Bool {
        guard let c = hook["command"] as? String else { return false }
        return c.contains(marker) || (command != nil && c == command)
    }

    // MARK: Install

    public func install() throws {
        try writeScript()
        try mergeSettings()
    }

    func writeScript() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.eventsDirectory, withIntermediateDirectories: true)
            try Data(Self.script.utf8).write(to: paths.hookScript, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hookScript.path)
        } catch {
            throw HookInstallError.io("Could not write the hook script: \(error.localizedDescription)")
        }
    }

    func mergeSettings() throws {
        let fm = FileManager.default
        let url = paths.claudeSettings
        var settings: [String: Any] = [:]
        let exists = fm.fileExists(atPath: url.path)

        if exists {
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw HookInstallError.io("Could not read \(url.path): \(error.localizedDescription)")
            }
            if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                let parsed: Any
                do { parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
                    throw HookInstallError.invalidSettingsJSON(url.path)
                }
                guard let obj = parsed as? [String: Any] else { throw HookInstallError.settingsNotAnObject }
                settings = obj
            }
        }

        let merged = Self.merge(settings, command: hookCommand)
        let out: Data
        do {
            out = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw HookInstallError.io("Could not encode settings: \(error.localizedDescription)")
        }

        do {
            try fm.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
            if exists {
                if fm.fileExists(atPath: paths.claudeSettingsBackup.path) {
                    try fm.removeItem(at: paths.claudeSettingsBackup)
                }
                try fm.copyItem(at: url, to: paths.claudeSettingsBackup)
            }
            var data = out
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
        } catch {
            throw HookInstallError.io("Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Pure merge: for each event drop previous entries of ours, keep everything else, append ours.
    public static func merge(_ settings: [String: Any], command: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return group }
                let kept = inner.filter { !isOurs($0, command: command) }
                if kept.count == inner.count { return group }
                if kept.isEmpty { return nil }
                var g = group
                g["hooks"] = kept
                return g
            }
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }
}
