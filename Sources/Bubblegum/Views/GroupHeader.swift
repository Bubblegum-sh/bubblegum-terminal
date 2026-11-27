import AppKit
import SwiftUI
import BubblegumCore

/// A user group's sidebar heading: chevron, colour square, name in the group colour, count.
/// Clicking toggles collapse. Hovering (or tabbing to it) shows the "…" menu.
struct GroupHeader: View {
    let group: SessionGroup
    let count: Int
    let isOpen: Bool
    let needsAttention: Bool
    let isRenaming: Bool

    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var hover = false
    @FocusState private var menuFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if isRenaming {
                renameField
            } else {
                toggle
                menuButton
            }
        }
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover && !isRenaming ? theme.text3.opacity(0.08) : .clear))
        .onHover { hover = $0 }
        .contextMenu { if !isRenaming { GroupMenuItems(group: group) } }
        .padding(.top, 6)
    }

    private var toggle: some View {
        Button {
            store.toggleCollapsed(group.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.text3)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                GroupSwatch(color: group.color)
                Text(group.name.uppercased())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(theme.groupC(group.color))
                Text("· \(count)")
                    .foregroundStyle(theme.groupC(group.color))
                    .fixedSize()
                Spacer(minLength: 0)
                if needsAttention {
                    Circle().fill(theme.accentC).frame(width: 8, height: 8)
                        .padding(.trailing, 2)
                        .help("A session in this group needs your attention")
                }
            }
            .font(TFFont.groupLabel)
            .tracking(0.6)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(GroupNaming.title(group.name)), \(count) \(count == 1 ? "session" : "sessions")"
                            + (needsAttention ? ", needs attention" : ""))
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isHeader)
    }

    private var menuButton: some View {
        Menu {
            GroupMenuItems(group: group)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .focused($menuFocused)
        .opacity(hover || menuFocused ? 1 : 0)
        .help("\(GroupNaming.title(group.name)) actions")
        .accessibilityLabel("\(GroupNaming.title(group.name)) actions")
    }

    private var renameField: some View {
        HStack(spacing: 6) {
            GroupSwatch(color: group.color)
            RenameField(initial: group.name, label: "Group name", font: .system(size: 12, weight: .semibold)) { name in
                store.commitRenameGroup(group.id, to: name)
            } onCancel: {
                store.cancelRenameGroup()
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 22)
        .padding(.trailing, 4)
    }
}

/// The group heading menu ("…" and right-click): Add new session, Rename, Change colour, Delete.
struct GroupMenuItems: View {
    let group: SessionGroup
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            store.showNewSessionSheet(inGroup: group.id)
        } label: {
            Label("Add new session", systemImage: "plus")
        }
        Button {
            store.beginRenameGroup(group.id)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Picker(selection: colorBinding) {
            ForEach(GroupColor.allCases, id: \.self) { c in
                Label {
                    Text(c.name)
                } icon: {
                    Image(nsImage: swatchImage(theme.groupColor(c)))
                }
                .tag(c)
            }
        } label: {
            Label("Change colour", systemImage: "paintpalette")
        }
        .pickerStyle(.menu)
        Divider()
        Button(role: .destructive) {
            store.requestDeleteGroup(group.id)
        } label: {
            Label("Delete group…", systemImage: "trash")
        }
    }

    private var colorBinding: Binding<GroupColor> {
        Binding(get: { store.group(group.id)?.color ?? group.color },
                set: { store.setGroupColor(group.id, $0) })
    }
}

/// Coloured rounded square for menus (NSMenu draws SwiftUI shapes as templates, losing colour).
func swatchImage(_ color: NSColor, size: CGFloat = 12) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        color.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: size / 4, yRadius: size / 4).fill()
        return true
    }
    image.isTemplate = false
    return image
}

/// Fixed "Ungrouped · N" heading. No menu; hovering shows a + that opens New session.
struct UngroupedHeader: View {
    let count: Int
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var hover = false
    @FocusState private var plusFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            GroupLabel(text: "Ungrouped · \(count)")
            Spacer(minLength: 0)
            Button {
                store.showNewSessionSheet()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.text3.opacity(0.18)).opacity(hover ? 1 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($plusFocused)
            .opacity(hover || plusFocused ? 1 : 0)
            .help("New ungrouped session")
            .accessibilityLabel("New ungrouped session")
        }
        .frame(minHeight: 28)
        .padding(.top, 6)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? theme.text3.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// "New group…" at the end of the group list.
struct NewGroupButton: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button {
            store.showGroupSheet()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("New group…").font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hover ? theme.text2 : theme.text3)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.top, 4)
        .help("Create a group")
    }
}
