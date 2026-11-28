import Foundation
import Testing
@testable import BubblegumCore

/// A fake `~/.claude/projects` with one project folder.
private struct Fixture {
    let projects: URL
    let folder: URL
    let sessionId = "11111111-2222-3333-4444-555555555555"

    init() throws {
        projects = FileManager.default.temporaryDirectory.appendingPathComponent("bubblegum-info-\(UUID().uuidString)/projects", isDirectory: true)
        folder = projects.appendingPathComponent("-Users-me-code-parser", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var main: URL { folder.appendingPathComponent(sessionId + ".jsonl") }
    var subagents: URL { folder.appendingPathComponent(sessionId).appendingPathComponent("subagents", isDirectory: true) }
    var provider: ClaudeSessionInfoProvider { ClaudeSessionInfoProvider(projectsDirectory: projects) }

    func write(_ lines: [String], to url: URL? = nil) throws {
        let url = url ?? main
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    func append(_ text: String, to url: URL? = nil) throws {
        let h = try FileHandle(forWritingTo: url ?? main)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    func info() -> SessionInfo? {
        let p = provider
        guard let loc = p.locate(sessionId: sessionId) else { return nil }
        var state = p.makeState()
        return p.parse(loc, state: &state)
    }
}

private func user(_ ts: String) -> String {
    #"{"type":"user","timestamp":"\#(ts)","message":{"role":"user","content":"hi"}}"#
}

private func assistant(_ ts: String, id: String?, model: String = "claude-opus-5-5",
                       input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) -> String {
    let idPart = id.map { #""id":"\#($0)","# } ?? ""
    return #"{"type":"assistant","timestamp":"\#(ts)","message":{"model":"\#(model)",\#(idPart)"role":"assistant","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output)}}}"#
}

private func date(_ s: String) -> Date { ClaudeSessionInfoProvider.parseTimestamp(s)! }

@Suite struct SessionInfoParseTests {
    @Test func duplicateUsageLinesCountOnce() throws {
        let f = try Fixture()
        // One reply written as three lines (thinking, text, tool use) repeating the same usage.
        try f.write([
            user("2026-11-28T10:00:00.000Z"),
            assistant("2026-11-28T10:00:05.000Z", id: "msg_1", input: 10, cacheWrite: 1000, cacheRead: 5000, output: 200),
            assistant("2026-11-28T10:00:06.000Z", id: "msg_1", input: 10, cacheWrite: 1000, cacheRead: 5000, output: 200),
            assistant("2026-11-28T10:00:07.000Z", id: "msg_1", input: 10, cacheWrite: 1000, cacheRead: 5000, output: 200),
            assistant("2026-11-28T10:01:00.000Z", id: "msg_2", input: 5, cacheRead: 6000, output: 50),
        ])
        let tokens = try #require(f.info()?.tokens)
        #expect(tokens == TokenUsage(input: 1015, output: 250, cacheRead: 11000))
        #expect(tokens.total == 1265) // cache read is not in the total
    }

    @Test func subagentTranscriptsAreAdded() throws {
        let f = try Fixture()
        try f.write([
            user("2026-11-28T10:00:00.000Z"),
            assistant("2026-11-28T10:00:05.000Z", id: "msg_1", input: 100, output: 10),
        ])
        // Subagent ids can repeat the main transcript's; they are still separate replies.
        try f.write([
            assistant("2026-11-28T10:00:02.000Z", id: "msg_1", model: "claude-haiku-4-5", input: 40, output: 4),
            assistant("2026-11-28T10:00:03.000Z", id: "msg_1", model: "claude-haiku-4-5", input: 40, output: 4),
        ], to: f.subagents.appendingPathComponent("agent-a.jsonl"))
        try f.write([assistant("2026-11-28T11:00:00.000Z", id: "msg_9", model: "claude-haiku-4-5", input: 1, output: 1)],
                    to: f.subagents.appendingPathComponent("agent-b.jsonl"))
        try f.write(["{}"], to: f.subagents.appendingPathComponent("agent-a.meta.json")) // not a transcript

        let info = try #require(f.info())
        #expect(info.tokens == TokenUsage(input: 141, output: 15))
        // Model and time come from the session's own transcript only.
        #expect(info.model == "claude-opus-5-5")
        #expect(info.lastActivityAt == date("2026-11-28T10:00:05.000Z"))
    }

    @Test func modelSwitchMidSessionShowsTheLastOne() throws {
        let f = try Fixture()
        try f.write([
            assistant("2026-11-28T10:00:00.000Z", id: "a", model: "claude-sonnet-5-5", output: 1),
            assistant("2026-11-28T10:01:00.000Z", id: "b", model: "claude-opus-5-5", output: 1),
            assistant("2026-11-28T10:01:30.000Z", id: "c", model: "<synthetic>", output: 0),
            #"{"type":"system","timestamp":"2026-11-28T10:02:00.000Z"}"#,
        ])
        let info = try #require(f.info())
        #expect(info.model == "claude-opus-5-5")
        #expect(info.startedAt == date("2026-11-28T10:00:00.000Z"))
        #expect(info.lastActivityAt == date("2026-11-28T10:02:00.000Z"))
    }

    @Test func missingTranscript() throws {
        let f = try Fixture()
        #expect(f.provider.locate(sessionId: f.sessionId) == nil)
        #expect(f.info() == nil)
    }

    @Test func noAssistantYetHasTimeButNoTokens() throws {
        let f = try Fixture()
        try f.write([user("2026-11-28T10:00:00Z")]) // no fractional seconds
        let info = try #require(f.info())
        #expect(info.tokens == nil)
        #expect(info.model == nil)
        #expect(info.startedAt == date("2026-11-28T10:00:00.000Z"))
    }

    @Test func malformedLinesAreSkipped() throws {
        let f = try Fixture()
        try f.write(["not json", "", assistant("2026-11-28T10:00:00.000Z", id: "a", output: 7), "{\"type\":"])
        // Bad JSON, empty lines and a truncated record are skipped, the rest still counts.
        #expect(f.info()?.tokens == TokenUsage(output: 7))
    }

    @Test func activeTimeSkipsLongGaps() throws {
        let f = try Fixture()
        try f.write([
            user("2026-11-28T10:00:00.000Z"),
            assistant("2026-11-28T10:04:00.000Z", id: "a", output: 1),  // +4 min: active
            user("2026-11-28T11:00:00.000Z"),                           // +56 min: idle
            assistant("2026-11-28T11:05:00.000Z", id: "b", output: 1),  // +5 min exactly: active
        ])
        let info = try #require(f.info())
        #expect(info.activeDuration == TimeInterval(9 * 60))
        #expect(info.totalDuration == TimeInterval(65 * 60))
    }
}

@Suite struct SessionInfoIncrementalTests {
    @Test func readsOnlyWhatWasAppendedAndWaitsForWholeLines() async throws {
        let f = try Fixture()
        try f.write([assistant("2026-11-28T10:00:00.000Z", id: "a", input: 1, output: 1)])
        let reader = SessionInfoReader(provider: f.provider, sessionId: f.sessionId)
        #expect(await reader.refresh()?.tokens == TokenUsage(input: 1, output: 1))

        // A line still being written is not counted until its newline arrives.
        let next = assistant("2026-11-28T10:00:30.000Z", id: "b", input: 2, output: 2)
        try f.append(String(next.prefix(40)))
        #expect(await reader.refresh()?.tokens == TokenUsage(input: 1, output: 1))
        try f.append(String(next.dropFirst(40)) + "\n")
        #expect(await reader.refresh()?.tokens == TokenUsage(input: 3, output: 3))

        // The same reply streamed again (same id) does not add up.
        try f.append(assistant("2026-11-28T10:00:31.000Z", id: "b", input: 2, output: 2) + "\n")
        #expect(await reader.refresh()?.tokens == TokenUsage(input: 3, output: 3))
        #expect(await reader.refresh()?.lastActivityAt == date("2026-11-28T10:00:31.000Z"))
    }

    @Test func subagentAddedLaterIsPickedUp() async throws {
        let f = try Fixture()
        try f.write([assistant("2026-11-28T10:00:00.000Z", id: "a", output: 10)])
        let reader = SessionInfoReader(provider: f.provider, sessionId: f.sessionId)
        #expect(await reader.refresh()?.tokens?.output == 10)
        try f.write([assistant("2026-11-28T10:00:10.000Z", id: "s", output: 5)], to: f.subagents.appendingPathComponent("agent-x.jsonl"))
        #expect(await reader.refresh()?.tokens?.output == 15)
    }

    @Test func transcriptAppearingLaterOrRemoved() async throws {
        let f = try Fixture()
        let reader = SessionInfoReader(provider: f.provider, sessionId: f.sessionId)
        #expect(await reader.refresh() == nil)
        try f.write([assistant("2026-11-28T10:00:00.000Z", id: "a", output: 3)])
        #expect(await reader.refresh()?.tokens?.output == 3)
        try FileManager.default.removeItem(at: f.main)
        #expect(await reader.refresh() == nil)
    }

    @Test func rewrittenShorterTranscriptStartsOver() async throws {
        let f = try Fixture()
        try f.write([
            assistant("2026-11-28T10:00:00.000Z", id: "a", output: 100),
            assistant("2026-11-28T10:00:01.000Z", id: "b", output: 100),
        ])
        let reader = SessionInfoReader(provider: f.provider, sessionId: f.sessionId)
        #expect(await reader.refresh()?.tokens?.output == 200)
        try f.write([assistant("2026-11-28T10:00:00.000Z", id: "c", output: 1)])
        #expect(await reader.refresh()?.tokens?.output == 1)
    }
}

@Suite struct SessionInfoFormatTests {
    @Test func tokens() {
        #expect(SessionInfoFormat.tokens(0) == "0")
        #expect(SessionInfoFormat.tokens(842) == "842")
        #expect(SessionInfoFormat.tokens(1000) == "1K")
        #expect(SessionInfoFormat.tokens(42_149) == "42.1K")
        #expect(SessionInfoFormat.tokens(184_213) == "184.2K")
        #expect(SessionInfoFormat.tokens(999_960) == "1M")
        #expect(SessionInfoFormat.tokens(2_300_000) == "2.3M")
        #expect(SessionInfoFormat.tokens(1_500_000_000) == "1.5B")
    }

    @Test func duration() {
        #expect(SessionInfoFormat.duration(30) == "<1m")
        #expect(SessionInfoFormat.duration(12 * 60 + 59) == "12m")
        #expect(SessionInfoFormat.duration(60 * 60) == "1h")
        #expect(SessionInfoFormat.duration(84 * 60) == "1h 24m")
        #expect(SessionInfoFormat.duration(51 * 3600) == "2d 3h")
    }

    @Test func relative() {
        let now = Date()
        #expect(SessionInfoFormat.relative(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(SessionInfoFormat.relative(now.addingTimeInterval(-5 * 60), now: now) == "5 min ago")
        #expect(SessionInfoFormat.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(SessionInfoFormat.relative(now.addingTimeInterval(-30 * 3600), now: now) == "1 day ago")
        #expect(SessionInfoFormat.relative(now.addingTimeInterval(10), now: now) == "just now") // clock skew
    }

    @Test func day() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = date("2026-11-28T18:00:00.000Z")
        #expect(SessionInfoFormat.day(date("2026-11-28T14:02:00.000Z"), now: now, calendar: cal, locale: locale) == "Today, 14:02")
        #expect(SessionInfoFormat.day(date("2026-11-27T09:10:00.000Z"), now: now, calendar: cal, locale: locale) == "Yesterday, 09:10")
        #expect(SessionInfoFormat.day(date("2026-11-03T14:02:00.000Z"), now: now, calendar: cal, locale: locale).hasSuffix(", 14:02"))
        #expect(SessionInfoFormat.day(date("2025-11-03T14:02:00.000Z"), now: now, calendar: cal, locale: locale).contains("2025"))
    }

    @Test func activeTimeIgnoresOrder() {
        let t0 = Date(timeIntervalSince1970: 0)
        let ts = [t0.addingTimeInterval(120), t0, t0.addingTimeInterval(60), t0.addingTimeInterval(1000)]
        #expect(SessionInfo.activeTime(ts) == 120)
        #expect(SessionInfo.activeTime([]) == 0)
    }
}

@Suite struct NewSessionIdLaunchTests {
    @Test func newConversationIsNamedUpFront() {
        let id = "0b3f6c5e-8f43-4e43-9b8e-2a1d5c7e9f10"
        #expect(LaunchCommand.script(directory: "/x", resumeId: nil, newSessionId: id).contains("exec claude --session-id '\(id)'"))
        // Resume wins; a non-UUID is never passed.
        let resumed = LaunchCommand.script(directory: "/x", resumeId: "abc", newSessionId: id)
        #expect(resumed.contains("--resume 'abc'") && !resumed.contains("--session-id"))
        #expect(!LaunchCommand.script(directory: "/x", resumeId: nil, newSessionId: "x; rm -rf ~").contains("--session-id"))
    }
}
