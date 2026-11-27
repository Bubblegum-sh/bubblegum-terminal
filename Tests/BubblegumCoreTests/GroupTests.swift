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
