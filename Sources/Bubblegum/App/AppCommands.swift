import SwiftUI

/// All shortcuts are menu items (spec section 7) so they show in the menu bar
/// and take precedence over the terminal view.
struct AppCommands: Commands {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Bubblegum") { About.show() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Session…") { store.showNewSessionSheet() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Open Project…") { store.openProjectWithPicker() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Blank Session") { store.startBlankSession() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find Session") { store.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Session") {
            let s = store.selected
            Button("Rename…") { store.beginRename() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(s == nil)
            Button("Session Info") { store.toggleSessionInfo() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(s == nil)
            Button(s?.isArchived == true ? "Unarchive" : "Archive") { store.toggleArchive() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(s == nil)
            Divider()
            Button("Restart Session") { store.requestRestart() }
                .disabled(s == nil)
            Button("Export…") { store.exportSession() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(s == nil)
            Button("Delete Session…") { if let id = s?.id { store.requestDelete(id) } }
                .disabled(s == nil)
            Divider()
            Button("Quick Switcher…") { store.toggleQuickSwitcher() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(store.sessions.isEmpty)
            Button("Next Session") { store.selectNext(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Session") { store.selectNext(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Session \(n)") { store.selectVisible(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }

        CommandGroup(before: .toolbar) {
            Button("Bigger") { settings.increaseFont() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { settings.decreaseFont() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { settings.resetFont() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}
