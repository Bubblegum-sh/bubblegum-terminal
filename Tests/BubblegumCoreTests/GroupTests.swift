import Foundation
import Testing
@testable import BubblegumCore

@Suite struct GroupModelTests {
    @Test func namesAreRequiredAndUniqueIgnoringCaseAndSpaces() {
        let work = SessionGroup(name: "Work", color: .blue)
        let groups = [work, SessionGroup(name: "Side projects", color: .pink, order: 1)]
        #expect(GroupNaming.validate("  Client work ", groups: groups) == .valid("Client work"))
        #expect(GroupNaming.validate("   ", groups: groups) == .empty)
        #expect(GroupNaming.validate(" work", groups: groups) == .taken)
        #expect(GroupNaming.validate("SIDE PROJECTS", groups: groups) == .taken)
        // Renaming a group to its own name (or a case change of it) is allowed.
        #expect(GroupNaming.validate("WORK", groups: groups, excluding: work.id) == .valid("WORK"))
    }

    @Test func persistenceRoundTripKeepsGroupsAndMembership() throws {
        let work = SessionGroup(name: "Work", color: .blue, order: 0, isCollapsed: true)
        let a = Session(name: "api", directory: "/code/api", groupId: work.id, order: 3)
        let b = Session(name: "notes", directory: "/notes")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bubblegum-groups-\(UUID()).json")
        try PersistedState(sessions: [a, b], groups: [work]).save(to: url)
        let loaded = try #require(PersistedState.load(from: url))
        #expect(loaded.groups == [work])
        #expect(loaded.sessions.map(\.groupId) == [work.id, nil])
        #expect(loaded.sessions.map(\.order) == [3, 0])
    }

    @Test func filesFromBeforeGroupsLoadAsUngrouped() throws {
        let json = """
        {"archivedOpen": true, "sessions": [
          {"id": "\(UUID())", "name": "old", "directory": "/code/old", "isPinned": true}
        ]}
        """
        let state = try PersistedState.decode(Data(json.utf8))
        #expect(state.groups.isEmpty)
        #expect(state.sessions.count == 1 && state.sessions[0].groupId == nil && state.sessions[0].order == 0)
    }

    @Test func unknownGroupAndBadGroupEntriesAreTolerated() throws {
        let gid = UUID()
        let json = """
        {"groups": [
          {"id": "\(gid)", "name": "Work", "color": "chartreuse", "order": 2},
          {"name": "no id"}
        ], "sessions": [
          {"id": "\(UUID())", "name": "a", "directory": "/a", "groupId": "\(gid)"},
          {"id": "\(UUID())", "name": "b", "directory": "/b", "groupId": "\(UUID())"}
        ]}
        """
        let state = try PersistedState.decode(Data(json.utf8))
        #expect(state.groups.count == 1)
        #expect(state.groups[0].color == .default && state.groups[0].order == 2 && !state.groups[0].isCollapsed)
        // A session pointing at a group that no longer exists goes back to Ungrouped.
        #expect(state.sessions.map(\.groupId) == [gid, nil])
    }
}

@Suite struct GroupOpsTests {
    let work = SessionGroup(name: "Work", color: .blue, order: 0)
    let side = SessionGroup(name: "Side", color: .pink, order: 1)

    func sample() -> [Session] {
        [
            Session(name: "a", directory: "/a", groupId: work.id, order: 0),
            Session(name: "b", directory: "/b", groupId: work.id, order: 1),
            Session(name: "c", directory: "/c", groupId: side.id, order: 0),
            Session(name: "d", directory: "/d"),
            Session(name: "e", directory: "/e", isArchived: true, groupId: work.id, order: 2),
        ]
    }

    func names(_ g: UUID?, _ s: [Session]) -> [String] { GroupOps.members(of: g, in: s).map(\.name) }

    @Test func membersAreActiveOnlyAndInManualOrder() {
        var s = sample()
        s[0].order = 5 // a now sorts after b
        #expect(names(work.id, s) == ["b", "a"])
        #expect(names(nil, s) == ["d"])
        // Equal orders (files from before groups) keep array order.
        let flat = [Session(name: "x", directory: "/x"), Session(name: "y", directory: "/y")]
        #expect(names(nil, flat) == ["x", "y"])
    }

    @Test func createAppendsAfterLastGroup() {
        var groups = [work, side]
        let g = GroupOps.create(name: "Scripts", color: .green, groups: &groups)
        #expect(g.order == 2 && GroupOps.sorted(groups).map(\.name) == ["Work", "Side", "Scripts"])
    }

    @Test func moveBetweenGroupsAndWithinAGroup() {
        var s = sample()
        let (a, b, c, d) = (s[0].id, s[1].id, s[2].id, s[3].id)
        // c into Work before b.
        GroupOps.move(c, to: work.id, before: b, sessions: &s)
        #expect(names(work.id, s) == ["a", "c", "b"])
        #expect(names(side.id, s).isEmpty)
        // Reorder inside Work: a to the end.
        GroupOps.move(a, to: work.id, sessions: &s)
        #expect(names(work.id, s) == ["c", "b", "a"])
        // Dropping a row onto itself changes nothing.
        GroupOps.move(b, to: work.id, before: b, sessions: &s)
        #expect(names(work.id, s) == ["c", "b", "a"])
        // b onto Ungrouped, before d.
        GroupOps.move(b, to: nil, before: d, sessions: &s)
        #expect(names(nil, s) == ["b", "d"] && names(work.id, s) == ["c", "a"])
    }

    @Test func movingAnArchivedSessionUnarchivesIt() {
        var s = sample()
        let e = s[4].id
        GroupOps.move(e, to: side.id, sessions: &s)
        #expect(s[4].isArchived == false && names(side.id, s) == ["c", "e"])
    }

    @Test func reorderGroups() {
        let scripts = SessionGroup(name: "Scripts", color: .green, order: 2)
        var groups = [work, side, scripts]
        GroupOps.moveGroup(scripts.id, before: work.id, groups: &groups)
        #expect(GroupOps.sorted(groups).map(\.name) == ["Scripts", "Work", "Side"])
        GroupOps.moveGroup(scripts.id, groups: &groups) // to the end
        #expect(GroupOps.sorted(groups).map(\.name) == ["Work", "Side", "Scripts"])
        #expect(groups.map(\.order).sorted() == [0, 1, 2])
    }

    @Test func ungroupAllKeepsOrderAfterUngroupedSessions() {
        var s = sample()
        GroupOps.ungroupAll(work.id, sessions: &s)
        #expect(s.allSatisfy { $0.groupId != work.id })
        #expect(names(nil, s) == ["d", "a", "b"])
        #expect(s[4].groupId == nil && s[4].isArchived) // archived members are ungrouped too
    }
}

@Suite struct GroupSidebarTests {
    @Test func groupsThenUngroupedThenArchived() {
        let work = SessionGroup(name: "Work", color: .blue, order: 1)
        let side = SessionGroup(name: "Side", color: .pink, order: 0)
        let a = Session(name: "a", directory: "/a", groupId: work.id, order: 1)
        let b = Session(name: "b", directory: "/b", groupId: work.id, order: 0)
        let c = Session(name: "c", directory: "/c", groupId: side.id)
        let d = Session(name: "d", directory: "/d")
        let e = Session(name: "e", directory: "/e", isArchived: true, groupId: work.id)
        let items = SidebarLayout.items(sessions: [a, b, c, d, e], groups: [work, side], query: "", archivedOpen: true)
        #expect(items == [
            .group(id: side.id, count: 1, isOpen: true, needsAttention: false), .row(c.id),
            .group(id: work.id, count: 2, isOpen: true, needsAttention: false), .row(b.id), .row(a.id),
            .ungrouped(count: 1), .row(d.id),
            .newGroup,
            .archivedToggle(count: 1, isOpen: true), .row(e.id),
        ])
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(SidebarLayout.visibleIds(items) == [c.id, b.id, a.id, d.id, e.id])
    }

    @Test func collapsedGroupHidesRowsAndShowsAttention() {
        var work = SessionGroup(name: "Work", color: .blue, isCollapsed: true)
        let quiet = Session(name: "quiet", directory: "/q", groupId: work.id)
        var waiting = Session(name: "waiting", directory: "/w", groupId: work.id, status: .waiting)
        let unread = Session(name: "unread", directory: "/u", unread: true, groupId: work.id)
        func head(_ sessions: [Session]) -> SidebarItem? {
            SidebarLayout.items(sessions: sessions, groups: [work], query: "", archivedOpen: true).first
        }
        #expect(head([quiet]) == .group(id: work.id, count: 1, isOpen: false, needsAttention: false))
        #expect(head([quiet, waiting]) == .group(id: work.id, count: 2, isOpen: false, needsAttention: true))
        #expect(head([unread]) == .group(id: work.id, count: 1, isOpen: false, needsAttention: true))
        // An archived session that is unread doesn't light up the group.
        waiting.status = .idle
        var archivedUnread = unread
        archivedUnread.isArchived = true
        #expect(head([waiting, archivedUnread]) == .group(id: work.id, count: 1, isOpen: false, needsAttention: false))
        // Expanded: no indicator on the heading.
        work.isCollapsed = false
        #expect(head([unread]) == .group(id: work.id, count: 1, isOpen: true, needsAttention: false))
        let items = SidebarLayout.items(sessions: [quiet], groups: [work], query: "", archivedOpen: true)
        #expect(SidebarLayout.visibleIds(items) == [quiet.id])
    }

    @Test func searchIsFlatAcrossGroups() {
        let work = SessionGroup(name: "Work", color: .blue)
        let a = Session(name: "api", directory: "/a", groupId: work.id)
        let b = Session(name: "app", directory: "/b")
        let items = SidebarLayout.items(sessions: [a, b], groups: [work], query: "ap", archivedOpen: true)
        #expect(items == [.label("Results · 2"), .row(a.id), .row(b.id)])
    }
}
