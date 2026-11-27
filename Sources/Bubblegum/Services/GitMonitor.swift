import AppKit
import Combine
import BubblegumCore

/// Git state of the selected session's folder: polled while the app is active, refreshed
/// on selection and hook events. Git runs off the main thread.
@MainActor
final class GitMonitor: ObservableObject {
    /// Status of `directory`; nil when it isn't a git work tree (or not read yet).
    @Published private(set) var status: GitStatus?
    @Published private(set) var directory: String?
    /// Set while a switch or create is running.
    @Published private(set) var busy = false

    private var timer: Timer?
    private var generation = 0

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, NSApp.isActive else { return }
                self.refresh()
            }
        }
    }

    /// Follows the selected session's folder.
    func track(_ dir: String?) {
        guard dir != directory else { return }
        directory = dir
        status = nil
        refresh()
    }

    func refresh() {
        guard let dir = directory, !busy else { return }
        generation += 1
        let gen = generation
        Task.detached(priority: .utility) {
            let s = Git.status(in: dir)
            await MainActor.run {
                guard gen == self.generation, dir == self.directory, s != self.status else { return }
                self.status = s
            }
        }
    }

    /// Branches grouped for the switcher.
    func loadBranches() async -> [GitBranch] {
        guard let dir = directory else { return [] }
        return await Task.detached(priority: .userInitiated) { Git.branches(in: dir) }.value
    }

    func recentNames() async -> [String] {
        guard let dir = directory else { return [] }
        return await Task.detached(priority: .userInitiated) { Git.recentlyCheckedOut(in: dir) }.value
    }

    func switchTo(_ branch: GitBranch, localNames: Set<String>) async throws {
        try await perform { dir in try Git.switchTo(branch, localNames: localNames, in: dir) }
    }

    func createBranch(_ name: String) async throws {
        try await perform { dir in try Git.createBranch(name, in: dir) }
    }

    private func perform(_ op: @escaping @Sendable (String) throws -> Void) async throws {
        guard let dir = directory else { return }
        busy = true
        defer { busy = false; refresh() }
        try await Task.detached(priority: .userInitiated) { try op(dir) }.value
    }
}
