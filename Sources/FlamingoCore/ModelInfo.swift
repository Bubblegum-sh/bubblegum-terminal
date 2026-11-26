import Foundation

/// The model and reasoning effort a session last used, read from its Claude Code transcript.
public struct ModelInfo: Codable, Equatable, Sendable {
    /// Raw model id, e.g. "claude-opus-5-5".
    public var model: String
    /// "low" | "medium" | "high" | "xhigh" | "max", when the model reports one.
    public var effort: String?

    public init(model: String, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }

    // MARK: Display

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5",
    /// "claude-3-5-sonnet-20241022" → "Sonnet 3.5", "claude-opus-5-5[1m]" → "Opus 5.5 (1M)".
    public var displayModel: String { Self.displayName(for: model) }

    public static func displayName(for id: String) -> String {
        var raw = id.lowercased()
        var suffix = ""
        if let r = raw.range(of: #"\[(.+)\]$"#, options: .regularExpression) {
            suffix = " (" + raw[r].dropFirst().dropLast().uppercased() + ")"
            raw.removeSubrange(r)
        }
        var parts = raw.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Drop a trailing date stamp (8 digits).
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }
        let numbers = parts.filter { $0.allSatisfy(\.isNumber) }
        guard !words.isEmpty else { return id }
        let family = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return numbers.isEmpty ? family + suffix : family + " " + numbers.joined(separator: ".") + suffix
    }

    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// 1…5 for the effort bars, nil when unknown.
    public var effortLevel: Int? {
        guard let e = effort?.lowercased(), let i = Self.effortLevels.firstIndex(of: e) else { return nil }
        return i + 1
    }

    public var effortLabel: String? {
        guard let e = effort?.lowercased() else { return nil }
        switch e {
        case "xhigh": return "Extra high"
        default: return e.prefix(1).uppercased() + e.dropFirst()
        }
    }

    // MARK: Transcript

    /// Reads the end of a transcript (JSONL) and returns the most recent model/effort.
    /// Only the last `tailBytes` are read, so large transcripts stay cheap.
    public static func latest(inTranscript url: URL, tailBytes: Int = 256 * 1024) -> ModelInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return latest(inTranscriptTail: data)
    }

    /// Scans JSONL lines from the end for an assistant record (or an API request) with a model.
    public static func latest(inTranscriptTail data: Data) -> ModelInfo? {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "assistant":
                guard let model = (obj["message"] as? [String: Any])?["model"] as? String, model != "<synthetic>" else { continue }
                return ModelInfo(model: model, effort: (obj["effort"] as? String) ?? (obj["perTurnEffort"] as? String))
            case "api-request":
                guard let params = obj["params"] as? [String: Any], let model = params["model"] as? String else { continue }
                let effort = (params["output_config"] as? [String: Any])?["effort"] as? String
                return ModelInfo(model: model, effort: effort)
            default:
                continue
            }
        }
        return nil
    }
}
