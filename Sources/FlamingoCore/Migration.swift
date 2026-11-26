import Foundation

/// One-time migration from the app's previous name, "Terminal Flamingo".
public enum LegacyMigration {
    public struct Result: Equatable {
        public var movedData = false
        public var rewroteHooks = false
    }

    /// 1. Moves `Application Support/TerminalFlamingo` to `…/Flamingo` when only the old folder exists.
    /// 2. If ~/.claude/settings.json still points at an old hook script, reinstalls the hooks
    ///    (backup first, unrelated keys untouched) so statuses keep working.
    @discardableResult
    public static func run(paths: AppPaths) -> Result {
        var result = Result()
        let fm = FileManager.default
        if let legacy = paths.legacySupportDirectory,
           fm.fileExists(atPath: legacy.path),
           !fm.fileExists(atPath: paths.supportDirectory.path) {
            do {
                try fm.createDirectory(at: paths.supportDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: legacy, to: paths.supportDirectory)
                result.movedData = true
            } catch {
                NSLog("Flamingo: could not move \(legacy.path): \(error)")
            }
        }
        let installer = HookInstaller(paths: paths)
        if installer.hasStaleEntries() {
            do {
                try installer.install()
                result.rewroteHooks = true
            } catch {
                NSLog("Flamingo: could not update hooks: \(error)")
            }
        }
        return result
    }
}
