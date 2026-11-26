import SwiftUI

/// P-1: exactly two settings, Theme and Font size, with a live terminal preview. Applies immediately (P-2).
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = settings.theme
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Text("Theme")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text2)
                    .frame(width: 120, alignment: .leading)
                Picker("Theme", selection: $settings.appearance) {
                    Text("Dark").tag(AppAppearance.dark)
                    Text("Light").tag(AppAppearance.light)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 16) {
                Text("Font size")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text2)
                    .frame(width: 120, alignment: .leading)
                HStack(spacing: 4) {
                    stepButton("−", label: "Smaller (⌘−)", enabled: settings.fontSize > AppSettings.fontRange.lowerBound) {
                        settings.decreaseFont()
                    }
                    Text("\(settings.fontSize) pt")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 54)
                        .accessibilityLabel("Font size \(settings.fontSize) points")
                    stepButton("+", label: "Larger (⌘+)", enabled: settings.fontSize < AppSettings.fontRange.upperBound) {
                        settings.increaseFont()
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevatedC))
                Text("⌘+ / ⌘−")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3)
                Spacer()
            }

            preview(theme)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(width: 480)
        .background(theme.windowC)
        .foregroundStyle(theme.text1)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func stepButton(_ title: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
    }

    private func preview(_ theme: Theme) -> some View {
        let size = CGFloat(settings.fontSize)
        let mono = Font(terminalFont(size: size))
        return VStack(alignment: .leading, spacing: size * 0.5) {
            (Text("> ").foregroundColor(theme.accentTextC).bold() + Text("run the tests"))
            (Text("● ").foregroundColor(theme.statusC(.idle)) + Text("Bash").bold() + Text("(npm test)").foregroundColor(theme.text2))
            Text("  └  42 passed").foregroundColor(theme.text3)
        }
        .font(mono)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.terminalC))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderC))
        .clipped()
        .accessibilityLabel("Terminal preview")
    }
}
