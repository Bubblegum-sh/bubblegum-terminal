import Foundation
import Testing
@testable import FlamingoCore

private func tempPaths() -> AppPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-tests-\(UUID().uuidString)", isDirectory: true)
    // Mimic the real layout so the marker substring appears in the hook path.
    return AppPaths(
        supportDirectory: base.appendingPathComponent("Application Support/Flamingo", isDirectory: true),
        claudeDirectory: base.appendingPathComponent(".claude", isDirectory: true)
    )
}

private func readJSON(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

@Suite struct HookInstallerTests {
    @Test func installsIntoMissingSettings() throws {
        let p = tempPaths()
        let inst = HookInstaller(paths: p)
        #expect(!inst.isInstalled())
        try inst.install()
        #expect(inst.isInstalled())
        #expect(FileManager.default.isExecutableFile(atPath: p.hookScript.path))
        #expect(!FileManager.default.fileExists(atPath: p.claudeSettingsBackup.path))
        let hooks = try readJSON(p.claudeSettings)["hooks"] as! [String: Any]
        for e in HookInstaller.events {
            let groups = hooks[e] as! [[String: Any]]
            #expect(groups.count == 1)
            let cmd = (groups[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
            #expect(cmd.hasPrefix("\"") && cmd.hasSuffix("\""))
        }
    }

    @Test func preservesUnrelatedKeysAndBacksUp() throws {
        let p = tempPaths()
        try FileManager.default.createDirectory(at: p.claudeDirectory, withIntermediateDirectories: true)
        let original = """
        {"model":"opus","permissions":{"allow":["Bash(ls)"]},
         "hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],
                  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]}}
        """
        try Data(original.utf8).write(to: p.claudeSettings)
        let inst = HookInstaller(paths: p)
        try inst.install()
        try inst.install() // idempotent

        #expect(try Data(contentsOf: p.claudeSettingsBackup).count > 0)
        let s = try readJSON(p.claudeSettings)
        #expect(s["model"] as? String == "opus")
        #expect((s["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
        let hooks = s["hooks"] as! [String: Any]
        #expect((hooks["PreToolUse"] as! [[String: Any]]).count == 1)
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 2) // user's + ours, ours not duplicated
        #expect(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as! String) == "say done")
        #expect(inst.isInstalled())
    }

    @Test func invalidJSONIsLeftUntouched() throws {
        let p = tempPaths()
        try FileManager.default.createDirectory(at: p.claudeDirectory, withIntermediateDirectories: true)
        let bad = Data("{ not json".utf8)
        try bad.write(to: p.claudeSettings)
        #expect(throws: HookInstallError.invalidSettingsJSON(p.claudeSettings.path)) {
            try HookInstaller(paths: p).install()
        }
        #expect(try Data(contentsOf: p.claudeSettings) == bad)
        #expect(!FileManager.default.fileExists(atPath: p.claudeSettingsBackup.path))
    }

    @Test func reinstallFromNonStandardPathDoesNotDuplicate() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-odd-\(UUID().uuidString)")
        let p = AppPaths(supportDirectory: base.appendingPathComponent("support"), claudeDirectory: base.appendingPathComponent(".claude"))
        let inst = HookInstaller(paths: p)
        #expect(!inst.hookCommand.contains(HookInstaller.marker))
        try inst.install()
        try inst.install()
        #expect(inst.isInstalled())
        let hooks = try readJSON(p.claudeSettings)["hooks"] as! [String: Any]
        for e in HookInstaller.events { #expect((hooks[e] as! [[String: Any]]).count == 1) }
    }

    @Test func devSupportDirNeverTargetsRealClaudeFolder() {
        let home = URL(fileURLWithPath: "/Users/me")
        let dev = AppPaths.standard(environment: ["FLAMINGO_SUPPORT_DIR": "/tmp/tf"], home: home)
        #expect(dev.claudeSettings.path == "/tmp/tf/claude/settings.json")
        let real = AppPaths.standard(environment: [:], home: home)
        #expect(real.claudeSettings.path == "/Users/me/.claude/settings.json")
        #expect(real.hookScript.path == "/Users/me/Library/Application Support/Flamingo/hook.sh")
    }

    @Test func notInstalledWhenAnEventIsMissing() throws {
        let p = tempPaths()
        let inst = HookInstaller(paths: p)
        try inst.install()
        var s = try readJSON(p.claudeSettings)
        var hooks = s["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "Notification")
        s["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: s).write(to: p.claudeSettings)
        #expect(!inst.isInstalled())
    }

    @Test func scriptWritesEventOnlyWithSessionId() throws {
        let p = tempPaths()
        try HookInstaller(paths: p).writeScript()
        let home = p.supportDirectory.deletingLastPathComponent().deletingLastPathComponent()
        // The script hardcodes $HOME/Library/Application Support/...; point HOME at a fake layout.
        let fakeSupport = home.appendingPathComponent("Library/Application Support/Flamingo/events")
        func run(_ env: [String: String]) throws {
            let proc = Process()
            proc.executableURL = p.hookScript
            proc.environment = env.merging(["HOME": home.path, "PATH": "/usr/bin:/bin"]) { $1 }
            let pipe = Pipe()
            proc.standardInput = pipe
            try proc.run()
            pipe.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"abc"}"#.utf8))
            try pipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0)
        }
        try run([:])
        #expect(HookEventWatcher.drain(directory: fakeSupport).isEmpty)
        let id = UUID()
        try run(["FLAMINGO_SESSION_ID": id.uuidString])
        let events = HookEventWatcher.drain(directory: fakeSupport)
        #expect(events == [HookEvent(appSessionId: id, kind: .stop, claudeSessionId: "abc")])
        #expect(HookEventWatcher.drain(directory: fakeSupport).isEmpty) // files deleted
    }
}

@Suite struct ReducerTests {
    func session(_ status: SessionStatus) -> Session {
        Session(name: "API migration", directory: "/tmp/api", status: status)
    }

    @Test func statusTransitions() {
        var s = session(.starting)
        SessionReducer.apply(HookEvent(appSessionId: s.id, kind: .sessionStart, claudeSessionId: "c1"), to: &s, isFocused: true)
        #expect(s.status == .idle)
        #expect(s.claudeSessionId == "c1")
        SessionReducer.apply(HookEvent(appSessionId: s.id, kind: .userPromptSubmit), to: &s, isFocused: true)
        #expect(s.status == .working)
        let a = SessionReducer.apply(HookEvent(appSessionId: s.id, kind: .notification, message: "Claude needs your permission to use Bash"), to: &s, isFocused: false)
        #expect(s.status == .waiting)
        #expect(s.unread)
        #expect(a?.subtitle == "Needs your answer")
        #expect(a?.body == "Claude needs your permission to use Bash")
        #expect(s.subtitle == "Claude needs your permission to use Bash")
        let b = SessionReducer.apply(HookEvent(appSessionId: s.id, kind: .stop), to: &s, isFocused: false)
        #expect(s.status == .idle)
        #expect(b?.subtitle == "Done")
    }

    @Test func noAlertWhenFocused() {
        var s = session(.working)
        #expect(SessionReducer.apply(HookEvent(appSessionId: s.id, kind: .stop), to: &s, isFocused: true) == nil)
        #expect(!s.unread)
    }

    @Test func idleReminderDoesNotNotifyAgain() {
        var s = session(.idle)
        let a = SessionReducer.apply(HookEvent(appSessionId: s.id, kind: .notification, message: "Claude is waiting for your input"), to: &s, isFocused: false)
        #expect(a == nil)
        #expect(s.status == .idle)
        #expect(s.lastMessage == "Claude is waiting for your input")
        #expect(!s.unread)
    }

    @Test func sessionStartDoesNotChangeRunningStatus() {
        var s = session(.working)
        SessionReducer.apply(HookEvent(appSessionId: s.id, kind: .sessionStart), to: &s, isFocused: true)
        #expect(s.status == .working)
    }

    @Test func parsesEventFile() {
        let id = UUID()
        let json = #"{"flamingo":"\#(id.uuidString)","payload":{"hook_event_name":"Notification","session_id":"s9","cwd":"/x","message":"hi"}}"#
        let e = HookEvent.parse(Data(json.utf8))
        #expect(e == HookEvent(appSessionId: id, kind: .notification, claudeSessionId: "s9", cwd: "/x", message: "hi"))
        #expect(HookEvent.parse(Data(#"{"tf":"nope","payload":null}"#.utf8)) == nil)
        #expect(HookEvent.parse(Data(#"{"tf":"\#(id.uuidString)","payload":null}"#.utf8))?.kind == nil)
    }
}

@Suite struct SidebarTests {
    let a = Session(name: "Flamingo", directory: "/code/tf")
    let b = Session(name: "Parser refactor", directory: "/code/parser")
    let c = Session(name: "Landing page", directory: "/code/landing")
    let d = Session(name: "Rust experiment", directory: "/code/rust", isArchived: true)

    @Test func groups() {
        let items = SidebarLayout.items(sessions: [a, b, c, d], query: "", archivedOpen: true)
        #expect(items == [.label("Sessions · 3"), .row(a.id), .row(b.id), .row(c.id), .archivedToggle(count: 1, isOpen: true), .row(d.id)])
        let closed = SidebarLayout.items(sessions: [b], query: "", archivedOpen: false)
        #expect(closed == [.label("Sessions · 1"), .row(b.id)])
    }

    @Test func searchIncludesArchived() {
        let items = SidebarLayout.items(sessions: [a, b, c, d], query: "RUST", archivedOpen: false)
        #expect(items == [.label("Results · 1"), .row(d.id)])
        #expect(SidebarLayout.items(sessions: [a], query: "zzz", archivedOpen: true) == [.label("No sessions match")])
    }

    @Test func quickSwitcherHighlightsName() {
        let m = QuickSwitcherFilter.matches(sessions: [a, b, c, d], query: "pa")
        #expect(m.map(\.id) == [b.id, c.id])
        #expect(String(b.name[m[0].nameRange!]) == "Pa")
        #expect(String(c.name[m[1].nameRange!]) == "pa")
    }
}

@Suite struct MiscTests {
    @Test func uniqueNames() {
        #expect(SessionNaming.unique("api", existing: ["web"]) == "api")
        #expect(SessionNaming.unique("api", existing: ["api", "api 2"]) == "api 3")
        #expect(SessionNaming.validatedRename("   ") == nil)
        #expect(SessionNaming.validatedRename(" New ") == "New")
    }

    @Test func relativeTime() {
        let now = Date()
        #expect(RelativeTime.short(from: now.addingTimeInterval(-5), now: now) == "now")
        #expect(RelativeTime.short(from: now.addingTimeInterval(-60), now: now) == "1m")
        #expect(RelativeTime.short(from: now.addingTimeInterval(-12 * 60), now: now) == "12m")
        #expect(RelativeTime.short(from: now.addingTimeInterval(-3 * 86400), now: now) == "3d")
        #expect(RelativeTime.short(from: now.addingTimeInterval(-8 * 86400), now: now) == "1w")
    }

    @Test func launchScriptQuotes() {
        let s = LaunchCommand.script(directory: "/tmp/it's here", resumeId: "abc")
        #expect(s.hasPrefix("cd '/tmp/it'\\''s here' && "))
        #expect(s.contains("exec claude --resume 'abc'"))
        #expect(!LaunchCommand.script(directory: "/x", resumeId: nil).contains("--resume"))
    }

    @Test func launchScriptRunsInShell() throws {
        // With an empty PATH, claude is not found → exit 127 and a hint.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", LaunchCommand.script(directory: "/tmp", resumeId: nil)]
        proc.environment = ["PATH": "/nonexistent"]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == LaunchCommand.claudeNotFoundExitCode)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains("claude was not found"))
    }

    @Test func environmentStripsParentSessionMarkers() {
        let id = UUID()
        let env = LaunchCommand.environment(sessionId: id, base: ["PATH": "/bin", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "x", "CLAUDE_CODE_USE_BEDROCK": "1"])
        #expect(env.contains("FLAMINGO_SESSION_ID=\(id.uuidString)"))
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("COLORTERM=truecolor"))
        #expect(env.contains("CLAUDE_CODE_USE_BEDROCK=1"))
        #expect(!env.contains { $0.hasPrefix("CLAUDECODE=") || $0.hasPrefix("CLAUDE_CODE_CHILD_SESSION=") })
    }

    @Test func persistenceRoundTripDropsRuntimeFields() throws {
        var s = Session(name: "x", directory: "/x", claudeSessionId: "c", isArchived: true, status: .working)
        s.terminalTitle = "title"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-\(UUID()).json")
        try PersistedState(sessions: [s], selectedId: s.id, archivedOpen: false).save(to: url)
        let loaded = try #require(PersistedState.load(from: url))
        #expect(loaded.sessions[0].status == .paused)
        #expect(loaded.sessions[0].terminalTitle == nil)
        #expect(loaded.sessions[0].claudeSessionId == "c")
        #expect(loaded.sessions[0].isArchived)
        #expect(loaded.selectedId == s.id)
        #expect(!loaded.archivedOpen)
    }

    @Test func loadsSessionsSavedWithPinnedFlag() throws {
        let id = UUID()
        let legacy = #"{"archivedOpen":true,"sessions":[{"id":"\#(id.uuidString)","name":"api","directory":"/code/api","isPinned":true,"isArchived":false,"createdAt":"2026-11-26T10:00:00Z","lastActivity":"2026-11-26T10:00:00Z","unread":false}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-legacy-\(UUID()).json")
        try Data(legacy.utf8).write(to: url)
        let loaded = try #require(PersistedState.load(from: url))
        #expect(loaded.sessions.map(\.id) == [id])
        #expect(SidebarLayout.items(sessions: loaded.sessions, query: "", archivedOpen: true) == [.label("Sessions · 1"), .row(id)])
    }

    @Test func titleCleanup() {
        #expect(Session.cleanTitle("✳ Fix the tests") == "Fix the tests")
        #expect(Session.cleanTitle("⠂ ") == nil)
    }
}

@Suite struct RecentProjectsTests {
    let home = "/Users/me"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordsNewestFirstWithoutDuplicates() {
        var r = RecentProjects()
        r.record(path: "/code/api", at: now.addingTimeInterval(-100), home: home)
        r.record(path: "/code/parser", at: now.addingTimeInterval(-50), home: home)
        r.record(path: "/code/api/", at: now, home: home)
        #expect(r.visible().map(\.path) == ["/code/api", "/code/parser"])
    }

    @Test func homeFolderIsNotRecorded() {
        var r = RecentProjects()
        r.record(path: home, at: now, home: home)
        r.record(path: home + "/", at: now, home: home)
        #expect(r.entries.isEmpty)
    }

    @Test func showsAtMostNineAndFilters() {
        var r = RecentProjects()
        for i in 0..<12 { r.record(path: "/p/proj\(i)", at: now.addingTimeInterval(Double(i)), home: home) }
        #expect(r.visible().count == 9)
        #expect(r.visible().first?.path == "/p/proj11")
        #expect(r.visible(filter: "PROJ1").map(\.path) == ["/p/proj11", "/p/proj10", "/p/proj1"])
        #expect(r.visible(filter: "zzz").isEmpty)
    }

    @Test func prunesMissingFolders() {
        var r = RecentProjects()
        r.record(path: "/keep", at: now, home: home)
        r.record(path: "/gone", at: now, home: home)
        let changed = r.prune(exists: { $0 == "/keep" })
        #expect(changed)
        #expect(r.entries.map(\.path) == ["/keep"])
        let changedAgain = r.prune(exists: { _ in true })
        #expect(!changedAgain)
    }

    @Test func persistenceRoundTrip() throws {
        var r = RecentProjects()
        r.record(path: "/code/api", at: now, home: home)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-recents-\(UUID()).json")
        try r.save(to: url)
        #expect(RecentProjects.load(from: url) == r)
        #expect(RecentProjects.load(from: url.appendingPathExtension("missing")).entries.isEmpty)
    }

    @Test func meta() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_800_014_400) // 2027-01-15 12:00 UTC... any midday
        let n = cal.date(bySettingHour: 12, minute: 0, second: 0, of: noon)!
        #expect(RecentProjects.meta(sessionCount: 2, lastOpened: n.addingTimeInterval(-3600), now: n, calendar: cal) == "2 sessions · 1h ago")
        #expect(RecentProjects.meta(sessionCount: 1, lastOpened: n.addingTimeInterval(-5 * 3600), now: n, calendar: cal) == "1 session · today")
        #expect(RecentProjects.meta(sessionCount: 0, lastOpened: n.addingTimeInterval(-24 * 3600), now: n, calendar: cal) == "yesterday")
        #expect(RecentProjects.meta(sessionCount: 0, lastOpened: n.addingTimeInterval(-3 * 86400), now: n, calendar: cal) == "3d ago")
        #expect(RecentProjects.meta(sessionCount: 0, lastOpened: n.addingTimeInterval(-8 * 86400), now: n, calendar: cal) == "1w ago")
        #expect(RecentProjects.meta(sessionCount: 0, lastOpened: n.addingTimeInterval(-20), now: n, calendar: cal) == "just now")
    }

    @Test func blankSessionNames() {
        #expect(SessionNaming.unique(SessionNaming.blankSessionName, existing: ["Blank session"]) == "Blank session 2")
    }
}

@Suite struct MigrationTests {
    func layout() -> (home: URL, paths: AppPaths) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-home-\(UUID().uuidString)")
        return (home, AppPaths.standard(environment: [:], home: home))
    }

    @Test func movesDataAndRewritesOldHookEntries() throws {
        let (home, paths) = layout()
        let fm = FileManager.default
        let legacy = try #require(paths.legacySupportDirectory)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("sessions.json"))
        // settings.json as the old app wrote it, plus an unrelated user hook and key.
        let oldCommand = "\"\(legacy.appendingPathComponent("hook.sh").path)\""
        var hooks: [String: Any] = [:]
        for e in HookInstaller.events { hooks[e] = [["hooks": [["type": "command", "command": oldCommand]]]] }
        hooks["Stop"] = (hooks["Stop"] as! [[String: Any]]) + [["hooks": [["type": "command", "command": "say done"]]]]
        try fm.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hooks": hooks, "model": "opus"]).write(to: paths.claudeSettings)

        let installer = HookInstaller(paths: paths)
        #expect(installer.hasStaleEntries())
        #expect(!installer.isInstalled()) // old path does not count as installed

        let r = LegacyMigration.run(paths: paths)
        #expect(r == LegacyMigration.Result(movedData: true, rewroteHooks: true))
        #expect(!fm.fileExists(atPath: legacy.path))
        #expect(fm.fileExists(atPath: paths.sessionsFile.path))
        #expect(installer.isInstalled())
        #expect(!installer.hasStaleEntries())
        let s = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
        #expect(s["model"] as? String == "opus")
        let h = s["hooks"] as! [String: Any]
        for e in HookInstaller.events {
            let cmds = (h[e] as! [[String: Any]]).flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
            #expect(!cmds.contains(oldCommand))
            #expect(cmds.filter { $0 == installer.hookCommand }.count == 1)
        }
        #expect(String(decoding: try Data(contentsOf: paths.hookScript), as: UTF8.self).contains("FLAMINGO_SESSION_ID"))
        _ = home
    }

    @Test func doesNothingWhenAlreadyMigrated() {
        let (_, paths) = layout()
        #expect(LegacyMigration.run(paths: paths) == LegacyMigration.Result())
    }

    @Test func parsesEventsFromBeforeTheRename() {
        let id = UUID()
        let e = HookEvent.parse(Data(#"{"tf":"\#(id.uuidString)","payload":{"hook_event_name":"Stop"}}"#.utf8))
        #expect(e?.appSessionId == id)
        #expect(e?.kind == .stop)
    }
}

@Suite struct ModelInfoTests {
    @Test func displayNames() {
        #expect(ModelInfo.displayName(for: "claude-opus-5-5") == "Opus 5.5")
        #expect(ModelInfo.displayName(for: "claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(ModelInfo.displayName(for: "claude-fable-5-2") == "Fable 5.2")
        #expect(ModelInfo.displayName(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelInfo.displayName(for: "claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ModelInfo.displayName(for: "claude-opus-5-5[1m]") == "Opus 5.5 (1M)")
        #expect(ModelInfo.displayName(for: "claude-opus-4-20250514") == "Opus 4")
    }

    @Test func effortLevels() {
        #expect(ModelInfo(model: "m", effort: "low").effortLevel == 1)
        #expect(ModelInfo(model: "m", effort: "high").effortLevel == 3)
        #expect(ModelInfo(model: "m", effort: "high").effortLabel == "High")
        #expect(ModelInfo(model: "m", effort: "xhigh").effortLabel == "Extra high")
        #expect(ModelInfo(model: "m", effort: "max").effortLevel == 5)
        #expect(ModelInfo(model: "m").effortLevel == nil)
    }

    @Test func readsLatestFromTranscriptTail() throws {
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5"},"effort":"low"}"#,
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5"},"effort":"high","perTurnEffort":"high"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>"}}"#,
            #"{"type":"last-prompt"}"#,
            "not json",
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-transcript-\(UUID()).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        #expect(ModelInfo.latest(inTranscript: url) == ModelInfo(model: "claude-opus-5-5", effort: "high"))
        // A small tail window that starts mid-line still finds a complete record.
        #expect(ModelInfo.latest(inTranscript: url, tailBytes: 200)?.model == "claude-opus-5-5")
        #expect(ModelInfo.latest(inTranscript: url.appendingPathExtension("missing")) == nil)
    }

    @Test func apiRequestRecordAlsoWorks() {
        let tail = Data(#"{"type":"api-request","params":{"model":"claude-opus-5-5","output_config":{"effort":"medium"}}}"#.utf8)
        #expect(ModelInfo.latest(inTranscriptTail: tail) == ModelInfo(model: "claude-opus-5-5", effort: "medium"))
    }

    @Test func hookEventCarriesTranscriptAndUpdatesSession() {
        let id = UUID()
        let e = HookEvent.parse(Data(#"{"flamingo":"\#(id.uuidString)","payload":{"hook_event_name":"Stop","transcript_path":"/tmp/t.jsonl"}}"#.utf8))
        #expect(e?.transcriptPath == "/tmp/t.jsonl")
        var s = Session(id: id, name: "x", directory: "/x", status: .working)
        var ev = e!
        ev.modelInfo = ModelInfo(model: "claude-opus-5-5", effort: "high")
        SessionReducer.apply(ev, to: &s, isFocused: true)
        #expect(s.modelInfo?.displayModel == "Opus 5.5")
        // Events without model info keep the last known value.
        SessionReducer.apply(HookEvent(appSessionId: id, kind: .userPromptSubmit), to: &s, isFocused: true)
        #expect(s.modelInfo?.effort == "high")
    }

    @Test func modelInfoIsPersisted() throws {
        var s = Session(name: "x", directory: "/x")
        s.modelInfo = ModelInfo(model: "claude-opus-5-5", effort: "high")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-mi-\(UUID()).json")
        try PersistedState(sessions: [s]).save(to: url)
        #expect(PersistedState.load(from: url)?.sessions.first?.modelInfo == s.modelInfo)
    }
}

@Suite struct SessionStartModelTests {
    @Test func sessionStartShowsModelBeforeFirstAnswer() {
        let id = UUID()
        // Real SessionStart payload shape (captured from Claude Code).
        let json = #"{"flamingo":"\#(id.uuidString)","payload":{"session_id":"72700620","transcript_path":"/nope.jsonl","cwd":"/x","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5-5"}}"#
        let e = HookEvent.parse(Data(json.utf8))!
        #expect(e.payloadModel == "claude-opus-5-5")
        var s = Session(id: id, name: "x", directory: "/x", status: .starting)
        SessionReducer.apply(e, to: &s, isFocused: true)
        #expect(s.modelInfo == ModelInfo(model: "claude-opus-5-5", effort: nil))
    }

    @Test func effortIsKeptOnlyForTheSameModel() {
        let id = UUID()
        var s = Session(id: id, name: "x", directory: "/x", status: .idle)
        s.modelInfo = ModelInfo(model: "claude-opus-5-5", effort: "high")
        SessionReducer.apply(HookEvent(appSessionId: id, kind: .sessionStart, payloadModel: "claude-opus-5-5"), to: &s, isFocused: true)
        #expect(s.modelInfo?.effort == "high")
        SessionReducer.apply(HookEvent(appSessionId: id, kind: .sessionStart, payloadModel: "claude-sonnet-5-5"), to: &s, isFocused: true)
        #expect(s.modelInfo == ModelInfo(model: "claude-sonnet-5-5", effort: nil))
        // A resumed transcript with that model supplies the effort.
        var e = HookEvent(appSessionId: id, kind: .sessionStart, payloadModel: "claude-sonnet-5-5")
        e.modelInfo = ModelInfo(model: "claude-sonnet-5-5", effort: "low")
        SessionReducer.apply(e, to: &s, isFocused: true)
        #expect(s.modelInfo?.effort == "low")
    }

    @Test func transcriptExistence() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-projects-\(UUID())")
        let dir = projects.appendingPathComponent("-Users-me-code-api")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("abc.jsonl"))
        #expect(ClaudeTranscripts.exists(sessionId: "abc", in: projects))
        #expect(!ClaudeTranscripts.exists(sessionId: "never-messaged", in: projects))
        #expect(!ClaudeTranscripts.exists(sessionId: "", in: projects))
        #expect(!ClaudeTranscripts.exists(sessionId: "../x", in: projects))
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ClaudeTranscripts.projectsDirectory(environment: [:], home: home).path == "/Users/me/.claude/projects")
        #expect(ClaudeTranscripts.projectsDirectory(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home).path == "/cfg/projects")
    }
}

@Suite struct TranscriptExporterTests {
    let utc = TimeZone(identifier: "UTC")!

    func jsonl(_ records: [[String: Any]]) -> Data {
        Data(records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n").utf8)
    }

    var sample: Data {
        jsonl([
            ["type": "ai-title", "aiTitle": "Fix the tests"],
            ["type": "user", "timestamp": "2026-11-27T10:41:00.000Z", "message": ["role": "user", "content": "run the tests please"]],
            ["type": "user", "isMeta": true, "message": ["content": [["type": "text", "text": "meta stuff"]]]],
            ["type": "assistant", "timestamp": "2026-11-27T10:41:05.000Z", "message": ["content": [["type": "thinking", "thinking": "secret"]]]],
            ["type": "assistant", "timestamp": "2026-11-27T10:41:06.000Z", "message": ["content": [["type": "text", "text": "Running them now."]]]],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "npm test"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "42 passed ```inner```", "is_error": false]]]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "All **42** tests pass."]]]],
            ["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "subagent chatter"]]]],
            ["type": "user", "timestamp": "2026-11-27T10:45:00.000Z", "message": ["content": "<command-name>/model</command-name>\n<command-args>opus</command-args>"]],
            ["type": "user", "message": ["content": "<local-command-caveat>Caveat: ignore</local-command-caveat>"]],
            ["type": "user", "message": ["content": [["type": "text", "text": "thanks"], ["type": "image", "source": [:]]]]],
        ])
    }

    @Test func rendersConversation() {
        let md = TranscriptExporter.markdown(
            transcript: sample,
            metadata: .init(title: "API migration", directory: "/tmp/api", model: ModelInfo(model: "claude-opus-5-5", effort: "high"),
                            claudeSessionId: "abc", exportedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            timeZone: utc)
        #expect(md.hasPrefix("# API migration\n"))
        #expect(md.contains("- **Model:** Opus 5.5 · High effort"))
        #expect(md.contains("- **Claude session:** `abc`"))
        #expect(md.contains("## You · 2026-11-27 10:41\n\nrun the tests please"))
        #expect(md.contains("## Claude · 2026-11-27 10:41\n\nRunning them now."))
        #expect(md.contains("<summary>Bash: npm test</summary>"))
        #expect(md.contains("**Output**\n\n````\n42 passed ```inner```\n````"))  // fence longer than inner backticks
        #expect(md.contains("All **42** tests pass."))
        #expect(md.contains("`/model opus`"))
        #expect(md.contains("thanks\n\n_[image]_"))
        #expect(!md.contains("secret"))
        #expect(!md.contains("meta stuff"))
        #expect(!md.contains("subagent chatter"))
        #expect(!md.contains("Caveat"))
        // One Claude heading for the whole answer (text + tool + text), then the next user turn.
        #expect(md.components(separatedBy: "## Claude").count == 2)
        #expect(md.components(separatedBy: "## You").count == 3)
        #expect(TranscriptExporter.aiTitle(transcript: sample) == "Fix the tests")
    }

    @Test func emptyTranscript() {
        let md = TranscriptExporter.markdown(transcript: Data(), metadata: .init(title: "x"), timeZone: utc)
        #expect(md.contains("_No messages in this session yet._"))
    }

    @Test func truncatesLongToolOutput() {
        let long = String(repeating: "a", count: TranscriptExporter.maxToolText + 10)
        let data = jsonl([
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t", "name": "Read", "input": ["file_path": "/x"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t", "content": [["type": "text", "text": long]], "is_error": true]]]],
        ])
        let md = TranscriptExporter.markdown(transcript: data, metadata: .init(title: "x"), timeZone: utc)
        #expect(md.contains("**Error**"))
        #expect(md.contains("… (10 more characters)"))
        #expect(md.contains("<summary>Read: /x</summary>"))
    }

    @Test func fileNamesAndLookup() throws {
        #expect(TranscriptExporter.suggestedFileName(for: "API: v2/beta") == "API- v2-beta.md")
        #expect(TranscriptExporter.suggestedFileName(for: "  ") == "Session.md")
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-proj-\(UUID())")
        let dir = projects.appendingPathComponent("-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("s1.jsonl"))
        #expect(ClaudeTranscripts.url(sessionId: "s1", in: projects)?.lastPathComponent == "s1.jsonl")
        #expect(ClaudeTranscripts.url(sessionId: "s2", in: projects) == nil)
    }
}
