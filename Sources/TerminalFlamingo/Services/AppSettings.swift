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
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        let stored = defaults.integer(forKey: Keys.fontSize)
        fontSize = Self.fontRange.contains(stored) ? stored : Self.defaultFontSize
    }

    func increaseFont() { fontSize = min(fontSize + 1, Self.fontRange.upperBound) }
    func decreaseFont() { fontSize = max(fontSize - 1, Self.fontRange.lowerBound) }
    func resetFont() { fontSize = Self.defaultFontSize }

    /// Menus, alerts and sheets follow the app theme too.
    func applyAppAppearance() {
        NSApp?.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
}
