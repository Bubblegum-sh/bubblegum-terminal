import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BubblegumCore

/// Makes a sidebar item draggable (session rows, group headings) and a drop target, and draws
/// the drop mark (a line above/below, or a highlight) from `SidebarDropRules`.
struct SidebarDragDrop: ViewModifier {
    let item: SidebarItem
    /// What this item drags as; nil = not draggable (Ungrouped, Archived, New group).
    let drag: SidebarDragItem?

    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var height: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay { mark }
            .modifier(DragSource(drag: drag, enabled: drag != nil && store.query.isEmpty) { store.sidebarDrag = $0 })
            .onDrop(of: [.bubblegumSidebarItem], delegate: SidebarDropDelegate(item: item, height: height, store: store))
    }

    @ViewBuilder
    private var mark: some View {
        switch store.dropMark {
        case .lineAbove(let id) where id == item.id:
            line.frame(maxHeight: .infinity, alignment: .top).offset(y: -2)
        case .lineBelow(let id) where id == item.id:
            line.frame(maxHeight: .infinity, alignment: .bottom).offset(y: 2)
        case .highlight(let id) where id == item.id:
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.accentC.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accentC, lineWidth: 1.5))
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private var line: some View {
        Capsule().fill(theme.accentC).frame(height: 2).padding(.horizontal, 4).allowsHitTesting(false)
    }
}

private struct DragSource: ViewModifier {
    let drag: SidebarDragItem?
    let enabled: Bool
    let begin: (SidebarDragItem) -> Void

    func body(content: Content) -> some View {
        if enabled, let drag {
            content.onDrag {
                begin(drag)
                let id: UUID
                switch drag {
                case .session(let s): id = s
                case .group(let g): id = g
                }
                // Our own type, visible only inside the app: other apps' drags (text, files)
                // never land here and can't replay a drag that was cancelled.
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.bubblegumSidebarItem.identifier, visibility: .ownProcess) { done in
                    done(Data(id.uuidString.utf8), nil)
                    return nil
                }
                return provider
            }
        } else {
            content
        }
    }
}

extension UTType {
    /// A session row or group heading dragged inside the sidebar (declared in Info.plist).
    static let bubblegumSidebarItem = UTType(exportedAs: "dev.bubblegum.sidebar-item")
}

/// The drag payload lives in the store (`sidebarDrag`); the item provider only marks the drag as ours.
private struct SidebarDropDelegate: DropDelegate {
    let item: SidebarItem
    let height: CGFloat
    let store: SessionStore

    private func resolve(_ info: DropInfo) -> SidebarDrop? {
        guard store.query.isEmpty, let drag = store.sidebarDrag else { return nil }
        return SidebarDropRules.resolve(drag, onto: item, upperHalf: info.location.y < height / 2,
                                        sessions: store.sessions, groups: store.groups)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.bubblegumSidebarItem]) && store.sidebarDrag != nil && store.query.isEmpty
    }

    func dropEntered(info: DropInfo) { store.dropMark = resolve(info)?.mark }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let drop = resolve(info)
        if store.dropMark != drop?.mark { store.dropMark = drop?.mark }
        return DropProposal(operation: drop == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        if let mark = resolve(info)?.mark, store.dropMark == mark { store.dropMark = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let drop = resolve(info)
        store.dropMark = nil
        store.sidebarDrag = nil
        guard let drop else { return false }
        store.perform(drop.action)
        return true
    }
}
