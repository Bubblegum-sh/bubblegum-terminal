import AppKit
import SwiftUI
import BubblegumCore

/// Named design tokens (spec section 8). Views use these, never raw hex values.
struct Theme: Equatable {
    var window: NSColor
    var sidebar: NSColor
    var terminal: NSColor
    var elevated: NSColor
    var selectedRow: NSColor
    var border: NSColor
    var textPrimary: NSColor
    var textSecondary: NSColor
    var textTertiary: NSColor
    /// Unread dot, "Needs you", caret.
    var accent: NSColor
    /// Accent used for text (darker on light backgrounds for contrast).
    var accentText: NSColor
    /// Fill for primary buttons (white text on it passes 4.5:1). Same as the app's AccentColor asset.
    var accentFill: NSColor
    var statusWorking: NSColor
    var statusIdle: NSColor
    var isDark: Bool

    static let dark = Theme(
        window: .hex(0x1C1B20), sidebar: .hex(0x232228), terminal: .hex(0x131216), elevated: .hex(0x2B2A31),
        selectedRow: .hex(0x3A2531), border: .hex(0x34333A), textPrimary: .hex(0xF2F1F4), textSecondary: .hex(0xB3B0BB),
        textTertiary: .hex(0x8E8B96), accent: .hex(0xFF5C8A), accentText: .hex(0xFF5C8A), accentFill: .hex(0xE30066),
        statusWorking: .hex(0xF5A524), statusIdle: .hex(0x3DD68C), isDark: true
    )

    static let light = Theme(
        window: .hex(0xFFFFFF), sidebar: .hex(0xF4F3F6), terminal: .hex(0xFBFAFC), elevated: .hex(0xE9E7EC),
        selectedRow: .hex(0xFCE1EB), border: .hex(0xE1DFE5), textPrimary: .hex(0x1C1B20), textSecondary: .hex(0x55525D),
        textTertiary: .hex(0x6B6872), accent: .hex(0xFF5C8A), accentText: .hex(0xC7185A), accentFill: .hex(0xC7185A),
        statusWorking: .hex(0xB86E00), statusIdle: .hex(0x0E8A50), isDark: false
    )

    static func forAppearance(_ a: AppAppearance) -> Theme { a == .light ? .light : .dark }

    func statusColor(_ s: SessionStatus) -> NSColor {
        switch s {
        case .working: return statusWorking
        case .waiting: return accent
        case .idle: return statusIdle
        case .paused, .starting, .ended: return textTertiary
        }
    }

    // SwiftUI accessors
    var windowC: Color { Color(nsColor: window) }
    var sidebarC: Color { Color(nsColor: sidebar) }
    var terminalC: Color { Color(nsColor: terminal) }
    var elevatedC: Color { Color(nsColor: elevated) }
    var selectedRowC: Color { Color(nsColor: selectedRow) }
    var borderC: Color { Color(nsColor: border) }
    var text1: Color { Color(nsColor: textPrimary) }
    var text2: Color { Color(nsColor: textSecondary) }
    var text3: Color { Color(nsColor: textTertiary) }
    var accentC: Color { Color(nsColor: accent) }
    var accentTextC: Color { Color(nsColor: accentText) }
    var accentFillC: Color { Color(nsColor: accentFill) }
    func statusC(_ s: SessionStatus) -> Color { Color(nsColor: statusColor(s)) }
}

extension NSColor {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Fixed type scale from the spec.
enum TFFont {
    static let rowName = Font.system(size: 13, weight: .semibold)
    static let subtitle = Font.system(size: 11)
    static let groupLabel = Font.system(size: 10, weight: .semibold)
    static let toolbarTitle = Font.system(size: 13, weight: .semibold)
    static let path = Font.system(size: 11)
    static let time = Font.system(size: 11)
}

/// Terminal font: JetBrains Mono if installed, otherwise the system monospace.
func terminalFont(size: CGFloat) -> NSFont {
    NSFont(name: "JetBrainsMono-Regular", size: size)
        ?? NSFont(name: "JetBrains Mono", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}
