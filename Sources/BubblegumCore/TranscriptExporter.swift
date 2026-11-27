import Foundation

/// Turns a Claude Code transcript (JSONL) into a readable Markdown document.
public enum TranscriptExporter {
    public struct Metadata: Equatable {
        public var title: String
        public var directory: String?
        public var model: ModelInfo?
        public var claudeSessionId: String?
        public var exportedAt: Date

        public init(title: String, directory: String? = nil, model: ModelInfo? = nil, claudeSessionId: String? = nil, exportedAt: Date = Date()) {
            self.title = title
            self.directory = directory
            self.model = model
            self.claudeSessionId = claudeSessionId
            self.exportedAt = exportedAt
        }
    }

    /// Longest tool input / output kept per tool call; longer text is cut with a note.
    public static let maxToolText = 4_000

    public static func markdown(transcript data: Data, metadata: Metadata,
                                timeZone: TimeZone = .current) -> String {
        let records = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }

        // Tool results arrive in later "user" records; index them by tool_use_id.
        var results: [String: (text: String, isError: Bool)] = [:]
        for r in records where r["type"] as? String == "user" {
            for block in contentBlocks(r) where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String {
                    results[id] = (toolResultText(block["content"]), (block["is_error"] as? Bool) ?? false)
                }
            }
        }

        var out = header(metadata, timeZone: timeZone)
        var role: String?
        var turns = 0

        func startTurn(_ newRole: String, _ record: [String: Any]) {
            guard role != newRole else { return }
            role = newRole
            turns += 1
            let time = (record["timestamp"] as? String).flatMap(parseDate).map { formatTime($0, timeZone) }
            out += "\n## " + (newRole == "user" ? "You" : "Claude") + (time.map { " · " + $0 } ?? "") + "\n\n"
        }

        for r in records {
            if (r["isSidechain"] as? Bool) == true || (r["isMeta"] as? Bool) == true { continue }
            switch r["type"] as? String {
            case "user":
                let parts = userParts(r)
                guard !parts.isEmpty else { continue }
                startTurn("user", r)
                out += parts.joined(separator: "\n\n") + "\n"
            case "assistant":
                for block in contentBlocks(r) {
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        startTurn("assistant", r)
                        out += text + "\n\n"
                    case "tool_use":
                        startTurn("assistant", r)
                        let id = block["id"] as? String ?? ""
                        out += toolSection(name: block["name"] as? String ?? "tool", input: block["input"], result: results[id])
                    default:
                        continue // thinking, redacted thinking, …
                    }
                }
            default:
                continue
            }
        }

        if turns == 0 { out += "\n_No messages in this session yet._\n" }
        return out.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    }

    /// The transcript's own title (Claude Code's `ai-title`), if any.
    public static func aiTitle(transcript data: Data) -> String? {
        var title: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let r = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  r["type"] as? String == "ai-title", let t = r["aiTitle"] as? String, !t.isEmpty else { continue }
            title = t
        }
        return title
    }

    // MARK: Pieces

    static func header(_ m: Metadata, timeZone: TimeZone) -> String {
        var s = "# \(m.title)\n\n"
        if let dir = m.directory { s += "- **Folder:** `\(Session.abbreviate(dir))`\n" }
        if let model = m.model {
            s += "- **Model:** \(model.displayModel)" + (model.effortLabel.map { " · \($0) effort" } ?? "") + "\n"
        }
        if let id = m.claudeSessionId { s += "- **Claude session:** `\(id)`\n" }
        s += "- **Exported:** \(formatDateTime(m.exportedAt, timeZone)) from Bubblegum\n\n---\n"
        return s
    }

    static func contentBlocks(_ record: [String: Any]) -> [[String: Any]] {
        (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// The human-written parts of a user record (not tool results).
    static func userParts(_ record: [String: Any]) -> [String] {
        let content = (record["message"] as? [String: Any])?["content"]
        if let text = content as? String { return cleanUserText(text).map { [$0] } ?? [] }
        var parts: [String] = []
        for block in content as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let t = cleanUserText(block["text"] as? String ?? "") { parts.append(t) }
            case "image":
                parts.append("_[image]_")
            default:
                continue
            }
        }
        return parts
    }

    /// Turns slash-command wrappers into readable text and drops harness-only caveats.
    static func cleanUserText(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("<local-command-caveat>") || text.hasPrefix("<system-reminder>") { return nil }
        if let name = tag("command-name", in: text) {
            let args = tag("command-args", in: text).map { " " + $0 } ?? ""
            return "`\(name)\(args)`"
        }
        if let stdout = tag("local-command-stdout", in: text) {
            return stdout.isEmpty ? nil : fence(stdout)
        }
        return text
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.map { b in
            if b["type"] as? String == "text" { return b["text"] as? String ?? "" }
            return "[\(b["type"] as? String ?? "content")]"
        }.joined(separator: "\n")
    }

    static func toolSection(name: String, input: Any?, result: (text: String, isError: Bool)?) -> String {
        let summary = toolSummary(name: name, input: input)
        var s = "<details>\n<summary>\(escapeHTML(summary))</summary>\n\n"
        if let input, let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let json = String(data: data, encoding: .utf8), json != "{\n\n}", json != "{}" {
            s += "**Input**\n\n" + fence(truncate(json), language: "json") + "\n\n"
        }
        if let result {
            s += (result.isError ? "**Error**" : "**Output**") + "\n\n" + fence(truncate(result.text)) + "\n\n"
        }
        return s + "</details>\n\n"
    }

    /// "Bash: npm test", "Read: Sources/App.swift", or just the tool name.
    static func toolSummary(name: String, input: Any?) -> String {
        let i = input as? [String: Any] ?? [:]
        let detail = ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"]
            .lazy.compactMap { i[$0] as? String }.first { !$0.isEmpty }
        guard var d = detail?.replacingOccurrences(of: "\n", with: " ") else { return name }
        if d.count > 80 { d = String(d.prefix(79)) + "…" }
        return "\(name): \(d)"
    }

    static func truncate(_ text: String) -> String {
        guard text.count > maxToolText else { return text }
        let cut = text.count - maxToolText
        return String(text.prefix(maxToolText)) + "\n… (\(cut) more characters)"
    }

    /// A code fence longer than any backtick run inside the text.
    static func fence(_ text: String, language: String = "") -> String {
        var longest = 0, run = 0
        for ch in text { run = ch == "`" ? run + 1 : 0; longest = max(longest, run) }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return "\(ticks)\(language)\n\(text)\n\(ticks)"
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func formatTime(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func formatDateTime(_ d: Date, _ tz: TimeZone) -> String { formatTime(d, tz) }

    /// A safe default file name: "API migration.md".
    public static func suggestedFileName(for title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Session" : cleaned) + ".md"
    }
}

extension ClaudeTranscripts {
    /// The saved transcript for a Claude session id, if any.
    public static func url(sessionId: String, in projects: URL = projectsDirectory()) -> URL? {
        guard !sessionId.isEmpty, !sessionId.contains("/"),
              let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        return dirs.lazy.map { $0.appendingPathComponent(sessionId + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
