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

    @Published var fontSize: Int {
        didSet {
            // Assigning inside didSet does not re-trigger the observer.
            fontSize = min(max(fontSize, Self.fontRange.lowerBound), Self.fontRange.upperBound)
            defaults.set(fontSize, forKey: Keys.fontSize)
        }
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

    func increaseFont() { fontSize = min(fontSize + 1, Self.fontRange.upperBound) }
    func decreaseFont() { fontSize = max(fontSize - 1, Self.fontRange.lowerBound) }
    func resetFont() { fontSize = Self.defaultFontSize }

    /// Menus, alerts and sheets follow the app theme too.
    func applyAppAppearance() {
        NSApp?.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
}
