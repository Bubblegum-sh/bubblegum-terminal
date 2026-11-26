import Foundation
import Testing
@testable import TerminalFlamingoCore

private func tempPaths() -> AppPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("tf-tests-\(UUID().uuidString)", isDirectory: true)
    // Mimic the real layout so the marker substring appears in the hook path.
    return AppPaths(
        supportDirectory: base.appendingPathComponent("Application Support/TerminalFlamingo", isDirectory: true),
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
        let fakeSupport = home.appendingPathComponent("Library/Application Support/TerminalFlamingo/events")
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
        try run(["TF_SESSION_ID": id.uuidString])
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
        let json = #"{"tf":"\#(id.uuidString)","payload":{"hook_event_name":"Notification","session_id":"s9","cwd":"/x","message":"hi"}}"#
        let e = HookEvent.parse(Data(json.utf8))
        #expect(e == HookEvent(appSessionId: id, kind: .notification, claudeSessionId: "s9", cwd: "/x", message: "hi"))
        #expect(HookEvent.parse(Data(#"{"tf":"nope","payload":null}"#.utf8)) == nil)
        #expect(HookEvent.parse(Data(#"{"tf":"\#(id.uuidString)","payload":null}"#.utf8))?.kind == nil)
    }
}

@Suite struct SidebarTests {
    let a = Session(name: "Terminal Flamingo", directory: "/code/tf", isPinned: true)
    let b = Session(name: "Parser refactor", directory: "/code/parser")
    let c = Session(name: "Landing page", directory: "/code/landing")
    let d = Session(name: "Rust experiment", directory: "/code/rust", isArchived: true)

    @Test func groups() {
        let items = SidebarLayout.items(sessions: [a, b, c, d], query: "", archivedOpen: true)
        #expect(items == [.label("Pinned"), .row(a.id), .label("Sessions · 2"), .row(b.id), .row(c.id), .archivedToggle(count: 1, isOpen: true), .row(d.id)])
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
        #expect(env.contains("TF_SESSION_ID=\(id.uuidString)"))
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("COLORTERM=truecolor"))
        #expect(env.contains("CLAUDE_CODE_USE_BEDROCK=1"))
        #expect(!env.contains { $0.hasPrefix("CLAUDECODE=") || $0.hasPrefix("CLAUDE_CODE_CHILD_SESSION=") })
    }

    @Test func persistenceRoundTripDropsRuntimeFields() throws {
        var s = Session(name: "x", directory: "/x", claudeSessionId: "c", isPinned: true, status: .working)
        s.terminalTitle = "title"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tf-\(UUID()).json")
        try PersistedState(sessions: [s], selectedId: s.id, archivedOpen: false).save(to: url)
        let loaded = try #require(PersistedState.load(from: url))
        #expect(loaded.sessions[0].status == .paused)
        #expect(loaded.sessions[0].terminalTitle == nil)
        #expect(loaded.sessions[0].claudeSessionId == "c")
        #expect(loaded.sessions[0].isPinned)
        #expect(loaded.selectedId == s.id)
        #expect(!loaded.archivedOpen)
    }

    @Test func titleCleanup() {
        #expect(Session.cleanTitle("✳ Fix the tests") == "Fix the tests")
        #expect(Session.cleanTitle("⠂ ") == nil)
    }
}
