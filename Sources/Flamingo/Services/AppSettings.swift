import AppKit
import Combine
import Foundation

enum AppAppearance: String, CaseIterable {
    case dark, light
}

/// The two user settings (P-1), stored in UserDefaults and applied immediately (P-2).
@MainActor
final class AppSettings: ObservableObject {
    static let fontRange = 10...24
    static let defaultFontSize = 13

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppAppearance()
        }
    }

    /// Always within `fontRange`: change it through `setFontSize` / increase / decrease / reset.
    /// (Clamping inside `didSet` would re-enter the `@Published` setter and recurse forever.)
    @Published private(set) var fontSize: Int {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    func setFontSize(_ size: Int) {
        let clamped = min(max(size, Self.fontRange.lowerBound), Self.fontRange.upperBound)
        if clamped != fontSize { fontSize = clamped }
    }

    var theme: Theme { Theme.forAppearance(appearance) }

    private let defaults: UserDefaults
    private enum Keys {
        static let appearance = "theme"
        static let fontSize = "terminalFontSize"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyDefaults(into: defaults)
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        let stored = defaults.integer(forKey: Keys.fontSize)
        fontSize = Self.fontRange.contains(stored) ? stored : Self.defaultFontSize
    }

    /// The app used to be "Terminal Flamingo": bundle id dev.terminalflamingo.app, or the domain
    /// "TerminalFlamingo" when run as a bare executable (e.g. from Xcode). Copy its preferences
    /// once so theme, font size and the hook-sheet flag carry over.
    private static func migrateLegacyDefaults(into defaults: UserDefaults) {
        let done = "migratedFromTerminalFlamingo"
        guard !defaults.bool(forKey: done) else { return }
        for domain in ["dev.terminalflamingo.app", "TerminalFlamingo"] {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for key in [Keys.appearance, Keys.fontSize, "didOfferHookInstall"] where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: done)
    }

    func increaseFont() { setFontSize(fontSize + 1) }
    func decreaseFont() { setFontSize(fontSize - 1) }
    func resetFont() { setFontSize(Self.defaultFontSize) }

    /// Menus, alerts and sheets follow the app theme too.
    func applyAppAppearance() {
        NSApp?.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
}
