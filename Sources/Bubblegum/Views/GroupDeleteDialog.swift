import SwiftUI
import BubblegumCore

/// "Delete <Group> group?": move its sessions to Ungrouped (default), delete them too, or cancel.
/// An empty group only offers Delete group and Cancel.
struct GroupDeleteDialog: View {
    let group: SessionGroup
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        let count = store.sessionCount(inGroup: group.id)
        ZStack(alignment: .top) {
            Color.black.opacity(theme.isDark ? 0.55 : 0.28)
                .onTapGesture { cancel() }
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.groupC(group.color).opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay(GroupSwatch(color: group.color, size: 16))
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Delete “\(group.name)” group?")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(body(count))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2)
                        .lineSpacing(2)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    if count > 0 {
                        DialogButton(title: "Delete group, move sessions to Ungrouped",
                                     fill: theme.accentC, text: Color(nsColor: .hex(0x1C1B20)), bold: true) {
                            store.deleteGroup(group.id, deleteSessions: false)
                        }
                        .keyboardShortcut(.defaultAction)
                        DialogButton(title: "Delete group and its \(count == 1 ? "session" : "\(count) sessions")",
                                     fill: theme.dangerC.opacity(theme.isDark ? 0.14 : 0.10), text: theme.dangerC) {
                            store.deleteGroup(group.id, deleteSessions: true)
                        }
                    } else {
                        DialogButton(title: "Delete group", fill: theme.dangerC.opacity(theme.isDark ? 0.14 : 0.10), text: theme.dangerC) {
                            store.deleteGroup(group.id, deleteSessions: false)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    DialogButton(title: "Cancel", fill: theme.elevatedC, text: theme.text1) { cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.windowC))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.borderC))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 24)
            .padding(.top, 140)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onExitCommand { cancel() }
    }

    private func body(_ count: Int) -> String {
        switch count {
        case 0: return "This group is empty."
        case 1: return "This group has 1 session. Choose what happens to it."
        default: return "This group has \(count) sessions. Choose what happens to them."
        }
    }

    private func cancel() {
        store.confirmDeleteGroupId = nil
        store.focusTerminal()
    }
}

/// Full-width dialog button (Delete group dialog, Create group sheet footer uses its own).
struct DialogButton: View {
    let title: String
    let fill: Color
    let text: Color
    var bold = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: bold ? .semibold : .medium))
                .foregroundStyle(text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
