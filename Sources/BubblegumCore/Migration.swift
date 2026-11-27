import Foundation

/// One-time migration from the app's previous names, "Flamingo" and "Terminal Flamingo".
public enum LegacyMigration {
    public struct Result: Equatable {
        public var movedData = false
        public var rewroteHooks = false
    }

    /// 1. Moves the newest existing old folder (`Application Support/Flamingo`, else
    ///    `…/TerminalFlamingo`) to `…/Bubblegum` when the new folder does not exist yet.
    /// 2. If ~/.claude/settings.json still points at an old hook script, reinstalls the hooks
    ///    (backup first, unrelated keys untouched) so statuses keep working.
    @discardableResult
    public static func run(paths: AppPaths) -> Result {
        var result = Result()
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.supportDirectory.path),
           let legacy = paths.legacySupportDirectories.first(where: { fm.fileExists(atPath: $0.path) }) {
            do {
                try fm.createDirectory(at: paths.supportDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: legacy, to: paths.supportDirectory)
                result.movedData = true
            } catch {
                NSLog("Bubblegum: could not move \(legacy.path): \(error)")
            }
        }
        let installer = HookInstaller(paths: paths)
        if installer.hasStaleEntries() {
            do {
                try installer.install()
                result.rewroteHooks = true
            } catch {
                NSLog("Bubblegum: could not update hooks: \(error)")
            }
        }
        return result
    }
}
