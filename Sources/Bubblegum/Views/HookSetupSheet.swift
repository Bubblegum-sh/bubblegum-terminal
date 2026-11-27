import SwiftUI

/// H-1: one-time sheet offering to install the Claude Code hooks.
struct HookSetupSheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Claude Code")
                .font(.system(size: 17, weight: .semibold))
            Text("Bubblegum learns when a session is working, needs you, or is done through Claude Code’s official hooks. Without them, statuses and notifications won’t update.")
                .font(.system(size: 13))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Adds a small hook script to Application Support/Bubblegum", systemImage: "doc.badge.plus")
                Label("Adds four hook entries to ~/.claude/settings.json (backed up to settings.json.bubblegum-backup first)", systemImage: "gearshape.2")
                Label("The hook does nothing outside Bubblegum sessions", systemImage: "checkmark.shield")
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.text2)
            HStack {
                Spacer()
                Button("Not Now") { store.showHookSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Install hooks") { store.installHooks() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 460)
    }
}
