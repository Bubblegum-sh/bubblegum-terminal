import SwiftUI
import BubblegumCore

/// Create group sheet: name (required, unique), colour, live sidebar preview, and, when opened
/// for a session, "Move <session> into this group". Opened from the sidebar's "New group…",
/// the session header's group chip, or after the first session in a new folder.
struct GroupSheetView: View {
    let request: GroupSheetRequest

    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var color = GroupColor.default
    @State private var moveSession = true
    @FocusState private var nameFocused: Bool

    private var session: Session? { store.session(request.sessionId) }
    private var hasMove: Bool { request.mode != .scratch && session != nil }
    private var validation: GroupNaming.Validation { GroupNaming.validate(name, groups: store.groups) }
    private var canCreate: Bool { if case .valid = validation { return true } else { return false } }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(theme.isDark ? 0.55 : 0.28)
                .onTapGesture { cancel() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    nameField
                    colorPicker
                    preview
                    if hasMove, let s = session {
                        Toggle("Move “\(s.name)” into this group", isOn: $moveSession)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 20)

                footer
            }
            .frame(width: 440)
            .background(theme.windowC)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).stroke(theme.borderC))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 24)
            .padding(.top, 52)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            name = request.suggestedName
            DispatchQueue.main.async { nameFocused = true }
        }
        .onExitCommand { cancel() }
    }

    private var title: String {
        request.mode == .newFolder ? "Put this session in a new group?" : "New group"
    }

    @ViewBuilder
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            if request.mode == .newFolder, let s = session {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text(s.displayPath).font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Text("· first session here").font(.system(size: 11, weight: .medium)).fixedSize()
                }
                .foregroundStyle(theme.text3)
                .padding(.bottom, 4)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(request.mode == .newFolder
                 ? "Group sessions to keep the sidebar tidy. You can add more later from the group’s menu."
                 : "Give it a name and a colour. You can change both later from the group’s menu.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text2)
            TextField("e.g. Client work", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($nameFocused)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.terminalC))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(nameFocused ? theme.accentC : theme.borderC))
                .background(RoundedRectangle(cornerRadius: 9).stroke(theme.accentC.opacity(nameFocused ? 0.22 : 0), lineWidth: 3).padding(-1.5))
                .accessibilityLabel("Group name")
                .onSubmit { create() }
            if validation == .taken {
                Text("A group with this name already exists")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warningC)
            }
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Colour · \(color.name)").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text2)
            HStack(spacing: 12) {
                ForEach(GroupColor.allCases, id: \.self) { c in
                    Button { color = c } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.groupC(c))
                            .frame(width: 28, height: 28)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.groupC(c), lineWidth: c == color ? 2 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(c.name)
                    .accessibilityLabel(c.name)
                    .accessibilityAddTraits(c == color ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Colour")
        }
    }

    private var preview: some View {
        let moving = hasMove && moveSession
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Sidebar preview").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.text3)
                    GroupSwatch(color: color)
                    Text("\((label.isEmpty ? "Untitled group" : label).uppercased()) · \(moving ? 1 : 0)")
                        .lineLimit(1)
                        .foregroundStyle(theme.groupC(color))
                }
                .font(TFFont.groupLabel)
                .tracking(0.6)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                if moving, let s = session {
                    HStack(spacing: 10) {
                        StatusDot(status: s.status)
                        Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.selectedRowC))
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.sidebarC))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderC))
            .accessibilityHidden(true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(request.mode == .newFolder ? "Cancel keeps it in Ungrouped" : "esc · ↩")
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
            Spacer(minLength: 0)
            Button { cancel() } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text1)
                    .padding(.vertical, 7).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.elevatedC))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Button { create() } label: {
                Text("Create group")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .hex(0x1C1B20)))
                    .padding(.vertical, 7).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.accentC))
                    .opacity(canCreate ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.sidebarC)
        .overlay(alignment: .top) { Rectangle().fill(theme.borderC).frame(height: 1) }
    }

    private func create() {
        guard canCreate else { NSSound.beep(); return }
        store.createGroup(name: name, color: color, moving: hasMove && moveSession ? request.sessionId : nil)
    }

    private func cancel() { store.closeGroupSheet() }
}

/// Session header chip for a grouped session, right after its name: colour + name. Clicking
/// opens the Create group sheet with "Move <session> into this group".
struct GroupChip: View {
    let group: SessionGroup
    let sessionId: UUID
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        Button {
            store.showGroupSheet(movingSession: sessionId)
        } label: {
            HStack(spacing: 5) {
                GroupSwatch(color: group.color, size: 7)
                Text(group.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .padding(.vertical, 1)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .background(Capsule().fill(hover ? theme.elevatedC : .clear))
            .overlay(Capsule().stroke(theme.borderC))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .help("Move to a new group")
        .accessibilityLabel("Group \(group.name), move to a new group")
    }
}
