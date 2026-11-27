import Foundation

/// The checked-out state of a git work tree.
public struct GitStatus: Equatable, Sendable {
    /// Branch name, nil when HEAD is detached.
    public var branch: String?
    /// Abbreviated HEAD commit ("" in a repository with no commits yet).
    public var head: String
    /// Changed, staged and untracked files.
    public var changes: Int
    public var ahead: Int
    public var behind: Int

    public init(branch: String?, head: String, changes: Int = 0, ahead: Int = 0, behind: Int = 0) {
        self.branch = branch
        self.head = head
        self.changes = changes
        self.ahead = ahead
        self.behind = behind
    }

    /// What the toolbar shows: the branch, or the short commit when detached.
    public var displayName: String { branch ?? (head.isEmpty ? "detached" : head) }
}

/// A local or remote-tracking branch.
public struct GitBranch: Equatable, Sendable, Identifiable {
    /// Short name: "main", "feat/x", or "origin/feat/x" for a remote one.
    public var name: String
    public var isRemote: Bool
    /// Subject of the tip commit.
    public var subject: String
    public var date: Date
    public var ahead: Int
    public var behind: Int

    public init(name: String, isRemote: Bool, subject: String = "", date: Date = .distantPast, ahead: Int = 0, behind: Int = 0) {
        self.name = name
        self.isRemote = isRemote
        self.subject = subject
        self.date = date
        self.ahead = ahead
        self.behind = behind
    }

    public var id: String { (isRemote ? "remote:" : "local:") + name }

    /// The local branch a remote one checks out as: "origin/feat/x" → "feat/x".
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

/// The branch list as the switcher shows it.
public struct GitBranchSections: Equatable, Sendable {
    public var current: GitBranch?
    public var recent: [GitBranch]
    public var otherLocal: [GitBranch]
    public var remote: [GitBranch]

    public var all: [GitBranch] { (current.map { [$0] } ?? []) + recent + otherLocal + remote }
}

public struct GitError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Git {
    // MARK: Running git

    /// git from Homebrew, or Apple's when the developer tools are installed. Apple's
    /// `/usr/bin/git` is only a stub otherwise, and running it opens an install dialog.
    public static let executable: String? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return path
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 && fm.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil
    }()

    struct Output { var status: Int32; var out: String; var err: String }

    static func run(_ args: [String], in directory: String) -> Output? {
        guard let git = executable else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0" // don't fight Claude's own git commands for index.lock
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read before waiting so a full pipe can't block git.
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }

    // MARK: Queries

    /// nil when `directory` is not inside a git work tree (or git isn't available).
    public static func status(in directory: String) -> GitStatus? {
        guard let r = run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: directory),
              r.status == 0 else { return nil }
        return parseStatus(r.out)
    }

    /// Local and remote branches, most recent commit first.
    public static func branches(in directory: String) -> [GitBranch] {
        let format = "%(refname)%09%(committerdate:unix)%09%(upstream:track,nobracket)%09%(subject)"
        guard let r = run(["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"], in: directory),
              r.status == 0 else { return [] }
        return parseBranches(r.out)
    }

    /// Local branches in the order they were last checked out, newest first.
    public static func recentlyCheckedOut(in directory: String) -> [String] {
        guard let r = run(["reflog", "-n", "500", "--format=%gs"], in: directory), r.status == 0 else { return [] }
        return parseReflog(r.out)
    }

    // MARK: Actions

    /// Checks out `branch`. A remote branch switches to its local branch, creating a tracking one if needed.
    public static func switchTo(_ branch: GitBranch, localNames: Set<String>, in directory: String) throws {
        let args: [String]
        if !branch.isRemote || localNames.contains(branch.localName) {
            args = ["switch", branch.localName]
        } else {
            args = ["switch", "--track", branch.name]
        }
        try check(run(args, in: directory))
    }

    /// Creates `name` from HEAD and switches to it.
    public static func createBranch(_ name: String, in directory: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GitError("Enter a branch name.") }
        try check(run(["check-ref-format", "--branch", name], in: directory), fallback: "“\(name)” isn’t a valid branch name.")
        try check(run(["switch", "-c", name], in: directory))
    }

    private static func check(_ r: Output?, fallback: String? = nil) throws {
        guard let r else { throw GitError("git couldn’t be run. Install the Xcode command line tools or git from Homebrew.") }
        guard r.status == 0 else {
            if let fallback { throw GitError(fallback) }
            let text = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(text.isEmpty ? "git exited with status \(r.status)." : text)
        }
    }

    // MARK: Parsing (pure, tested)

    /// Parses `git status --porcelain=v2 --branch`.
    public static func parseStatus(_ text: String) -> GitStatus {
        var s = GitStatus(branch: nil, head: "")
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                let oid = line.dropFirst("# branch.oid ".count)
                s.head = oid == "(initial)" ? "" : String(oid.prefix(7))
            } else if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                s.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { s.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { s.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                s.changes += 1
            }
        }
        return s
    }

    /// Parses `for-each-ref` lines: refname, unix date, upstream track, subject (tab separated).
    public static func parseBranches(_ text: String) -> [GitBranch] {
        var result: [GitBranch] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            let ref = f[0]
            let isRemote: Bool
            let name: String
            if ref.hasPrefix("refs/heads/") {
                isRemote = false
                name = String(ref.dropFirst("refs/heads/".count))
            } else if ref.hasPrefix("refs/remotes/") {
                isRemote = true
                name = String(ref.dropFirst("refs/remotes/".count))
                if name.hasSuffix("/HEAD") || !name.contains("/") { continue }
            } else { continue }
            var b = GitBranch(name: name, isRemote: isRemote,
                              subject: f.count > 3 ? f[3] : "",
                              date: Date(timeIntervalSince1970: TimeInterval(f[1]) ?? 0))
            if f.count > 2 {
                for part in f[2].split(separator: ",") {
                    let words = part.split(separator: " ")
                    guard words.count == 2, let n = Int(words[1]) else { continue }
                    if words[0] == "ahead" { b.ahead = n }
                    if words[0] == "behind" { b.behind = n }
                }
            }
            result.append(b)
        }
        return result
    }

    /// Branch names from reflog subjects like "checkout: moving from main to feat/x", newest first.
    public static func parseReflog(_ text: String) -> [String] {
        var seen = Set<String>(), order: [String] = []
        let prefix = "checkout: moving from "
        for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let r = rest.range(of: " to ") else { continue }
            for name in [String(rest[r.upperBound...]), String(rest[..<r.lowerBound])] where seen.insert(name).inserted {
                order.append(name)
            }
        }
        return order
    }

    /// Groups branches for the switcher. "Recent" follows checkout history, then commit dates.
    public static func sections(_ branches: [GitBranch], current: String?, recentNames: [String], recentCount: Int = 3) -> GitBranchSections {
        let local = branches.filter { !$0.isRemote }
        let others = local.filter { $0.name != current }
        let byName = Dictionary(others.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var recent: [GitBranch] = []
        for name in recentNames where recent.count < recentCount {
            if let b = byName[name], !recent.contains(b) { recent.append(b) }
        }
        for b in others where recent.count < recentCount && !recent.contains(b) { recent.append(b) }
        return GitBranchSections(
            current: local.first { $0.name == current },
            recent: recent,
            otherLocal: others.filter { !recent.contains($0) },
            remote: branches.filter(\.isRemote)
        )
    }

    /// Case-insensitive substring match on the name; local branches first.
    public static func filter(_ branches: [GitBranch], query: String) -> [GitBranch] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return branches }
        let hits = branches.filter { $0.name.lowercased().contains(q) }
        return hits.filter { !$0.isRemote } + hits.filter(\.isRemote)
    }

    /// "now", "12m", "3h", "yesterday", "4d", "2w".
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let short = RelativeTime.short(from: date, now: now)
        return short == "1d" ? "yesterday" : short
    }
}
