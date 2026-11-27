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

    /// Group colours (Main window: groups artboard). Light values are darker so group names
    /// in the sidebar stay readable on the light sidebar.
    func groupColor(_ c: GroupColor) -> NSColor {
        switch (c, isDark) {
        case (.pink, true): return .hex(0xFF5C8A)
        case (.orange, true): return .hex(0xFF9F43)
        case (.yellow, true): return .hex(0xF5C842)
        case (.green, true): return .hex(0x3DD68C)
        case (.teal, true): return .hex(0x2EC4C4)
        case (.blue, true): return .hex(0x5B9BFF)
        case (.purple, true): return .hex(0xB36BFF)
        case (.gray, true): return .hex(0x8E8B96)
        case (.pink, false): return .hex(0xD81B60)
        case (.orange, false): return .hex(0xE07000)
        case (.yellow, false): return .hex(0xB58B00)
        case (.green, false): return .hex(0x0E8A50)
        case (.teal, false): return .hex(0x00838F)
        case (.blue, false): return .hex(0x2F6FE0)
        case (.purple, false): return .hex(0x8A3FD9)
        case (.gray, false): return .hex(0x6B6872)
        }
    }

    /// Text and icons on destructive actions (Delete group).
    var danger: NSColor { isDark ? .hex(0xFF6B6B) : .hex(0xC62828) }
    /// Inline validation messages ("A group with this name already exists").
    var warning: NSColor { isDark ? .hex(0xFF9F43) : .hex(0xB05A00) }

    // SwiftUI accessors
    func groupC(_ c: GroupColor) -> Color { Color(nsColor: groupColor(c)) }
    var dangerC: Color { Color(nsColor: danger) }
    var warningC: Color { Color(nsColor: warning) }
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

/// Group colour mark: a rounded square, so it isn't confused with the round status dots.
struct GroupSwatch: View {
    let color: GroupColor
    var size: CGFloat = 9
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: size / 3)
            .fill(theme.groupC(color))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
