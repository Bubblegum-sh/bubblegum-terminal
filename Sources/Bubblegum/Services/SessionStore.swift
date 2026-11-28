import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import BubblegumCore

/// Source of truth for sessions, selection, search and archive state.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = [] {
        didSet { updateBadge() }
    }
    @Published private(set) var selectedId: UUID? {
        didSet { if selectedId != oldValue { git.track(selected?.directory) } }
    }
    @Published private(set) var groups: [SessionGroup] = []
    @Published var query: String = ""
    @Published var archivedOpen: Bool = true { didSet { if archivedOpen != oldValue { persist() } } }
    @Published var ungroupedOpen: Bool = true { didSet { if ungroupedOpen != oldValue { persist() } } }

    // UI state
    @Published var renamingId: UUID?
    /// True when `renamingId` is being edited in the top bar rather than its sidebar row.
    @Published private(set) var renamingInHeader = false
    @Published var showQuickSwitcher = false
    /// The New session sheet (⌘T) and its filter / focused row.
    @Published var showNewSession = false
    @Published var newSessionFilter = ""
    @Published var newSessionIndex = 0
    @Published private(set) var recents = RecentProjects()
    @Published var quickSwitcherHighlight: UUID?
    @Published var hooksInstalled = false
    @Published var showHookSheet = false
    @Published var errorMessage: String?
    @Published var errorTitle = "Something went wrong"
    @Published var confirmRestartId: UUID?
    @Published var confirmDeleteId: UUID?
    /// Group heading being renamed inline.
    @Published var renamingGroupId: UUID?
    /// Group waiting for the Delete group confirmation.
    @Published var confirmDeleteGroupId: UUID?
    /// The Create group sheet, when open.
    @Published var groupSheet: GroupSheetRequest?
    /// Sidebar drag in progress, and where its drop would land.
    @Published var sidebarDrag: SidebarDragItem?
    @Published var dropMark: SidebarDropMark?
    /// Set while the New session sheet was opened from a group's "Add new session".
    @Published private(set) var newSessionGroupId: UUID?
    /// Incremented to ask the sidebar to focus the search field (⌘F).
    @Published private(set) var searchFocusRequest = 0
    /// Incremented to ask the terminal host to take keyboard focus (T-2).
    @Published private(set) var terminalFocusRequest = 0

    let terminals = TerminalRegistry()
    let git = GitMonitor()
    let notifier = Notifier()
    let paths: AppPaths
    private let installer: HookInstaller
    private var watcher: HookEventWatcher?
    private var started = false
    private var mouseDownMonitor: Any?

    init(paths: AppPaths = .standard) {
        self.paths = paths
        self.installer = HookInstaller(paths: paths)
        LegacyMigration.run(paths: paths) // from "Flamingo" / "Terminal Flamingo": data folder + hook paths
        installer.updateScriptIfOutdated()
        let loaded = PersistedState.loadForApp(from: paths.sessionsFile)
        if let state = loaded.state {
            sessions = state.sessions.map { var s = $0; s.status = .paused; return s }
            groups = state.groups
            selectedId = state.selectedId.flatMap { id in sessions.contains { $0.id == id } ? id : nil }
            archivedOpen = state.archivedOpen
            ungroupedOpen = state.ungroupedOpen
        }
        if let backup = loaded.backup {
            let what = loaded.state == nil ? "Saved sessions couldn’t be read" : "Some saved sessions couldn’t be read"
            showError(what, "The original file was kept at \(Session.abbreviate(backup.path)).")
        }
        if selectedId == nil { selectedId = sessions.first { !$0.isArchived }?.id }
        recents = RecentProjects.load(from: paths.recentsFile)
        if recents.prune() { saveRecents() }
    }

    /// Called once the app has finished launching.
    func start() {
        guard !started else { return }
        started = true

        terminals.onExit = { [weak self] id, code in self?.processExited(id, exitCode: code) }
        terminals.onTitle = { [weak self] id, title in self?.mutate(id) { $0.terminalTitle = title } }
        notifier.onOpen = { [weak self] id in self?.select(id, focusTerminal: true) }
        notifier.setUp()

        watcher = HookEventWatcher(directory: paths.eventsDirectory) { [weak self] events in
            self?.handle(events)
        }
        watcher?.start()
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.clearStaleSidebarDrag()
            return event
        }
        git.start()
        git.track(selected?.directory)

        refreshHookState()
        let key = "didOfferHookInstall"
        if !hooksInstalled && !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            showHookSheet = true
        }

        if let id = selectedId { open(id) }
        updateBadge()
    }

    // MARK: Lookup

    func session(_ id: UUID?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    var selected: Session? { session(selectedId) }

    var sidebarItems: [SidebarItem] {
        SidebarLayout.items(sessions: sessions, groups: groups, query: query, archivedOpen: archivedOpen, ungroupedOpen: ungroupedOpen)
    }

    var visibleIds: [UUID] { SidebarLayout.visibleIds(sidebarItems) }

    func group(_ id: UUID?) -> SessionGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// Groups in sidebar order.
    var sortedGroups: [SessionGroup] { GroupOps.sorted(groups) }

    private func isFocused(_ id: UUID) -> Bool {
        NSApp.isActive && selectedId == id
    }

    // MARK: Create / open

    /// S-1: ⌘T or "+" opens the New session sheet. From a group's "Add new session" it is
    /// titled for that group and the new session goes into it; any other way, Ungrouped.
    func showNewSessionSheet(inGroup groupId: UUID? = nil) {
        showQuickSwitcher = false
        newSessionGroupId = group(groupId)?.id
        if recents.prune() { saveRecents() }
        newSessionFilter = ""
        newSessionIndex = 0
        showNewSession = true
    }

    func closeNewSessionSheet() {
        showNewSession = false
        newSessionGroupId = nil
        terminalFocusRequest += 1
    }

    /// Recent rows as shown in the sheet (filtered, newest first, max 9).
    var visibleRecents: [RecentProject] { recents.visible(filter: newSessionFilter) }

    func sessionCount(inFolder path: String) -> Int {
        let p = (path as NSString).standardizingPath
        return sessions.filter { ($0.directory as NSString).standardizingPath == p }.count
    }

    /// The group a session created right now goes into: the sheet's group while it is open.
    private func takeNewSessionGroup() -> UUID? {
        defer { newSessionGroupId = nil }
        return showNewSession ? newSessionGroupId : nil
    }

    /// Opening a recent project always creates a new session in that folder.
    func openRecent(at index: Int) {
        let list = visibleRecents
        guard list.indices.contains(index) else { return }
        let path = list[index].path
        let groupId = takeNewSessionGroup()
        showNewSession = false
        guard RecentProjects.directoryExists(path) else {
            recents.prune()
            saveRecents()
            showError("Project folder not found", "\(Session.abbreviate(path)) no longer exists.")
            return
        }
        createSession(directory: path, groupId: groupId)
    }

    /// Blank session (⌘N): no project, starts in the home folder.
    func startBlankSession() {
        let groupId = takeNewSessionGroup()
        showNewSession = false
        let name = SessionNaming.unique(SessionNaming.blankSessionName, existing: sessions.map(\.name))
        createSession(directory: NSHomeDirectory(), name: name, groupId: groupId)
    }

    /// Open project… (⌘O): folder picker.
    func openProjectWithPicker() {
        let groupId = takeNewSessionGroup()
        showNewSession = false
        showQuickSwitcher = false
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Start Session"
        panel.message = "Choose a project folder to run Claude Code in"
        if let dir = selected?.directory { panel.directoryURL = URL(fileURLWithPath: dir) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createSession(directory: url.path, groupId: groupId)
    }

    func createSession(directory: String, name: String? = nil, groupId: UUID? = nil) {
        let name = name ?? SessionNaming.unique(SessionNaming.defaultName(for: directory), existing: sessions.map(\.name))
        let groupId = group(groupId)?.id
        // First session in a folder (not a blank one in ~, not one already put in a group):
        // offer to start a group for it.
        let firstInFolder = groupId == nil && directory != NSHomeDirectory() && sessionCount(inFolder: directory) == 0
        let s = Session(name: name, directory: directory, groupId: groupId,
                        order: GroupOps.nextOrder(in: groupId, sessions: sessions), status: .paused)
        sessions.append(s)
        query = ""
        if let groupId { setCollapsed(groupId, false) }
        select(s.id, focusTerminal: true)
        persist()
        if firstInFolder {
            groupSheet = GroupSheetRequest(mode: .newFolder, sessionId: s.id, suggestedName: SessionNaming.defaultName(for: directory))
        }
    }

    /// Selecting is "opening": a Paused session resumes (S-5).
    func select(_ id: UUID, focusTerminal: Bool = true) {
        guard session(id) != nil else { return }
        if renamingId != nil && renamingId != id { renamingId = nil }
        reveal(id)
        selectedId = id
        open(id)
        if NSApp.isActive { markRead(id) }
        if focusTerminal { terminalFocusRequest += 1 }
        persist()
    }

    private func open(_ id: UUID) {
        guard let s = session(id) else { return }
        if s.status == .paused || (s.status.isRunning && !terminals.isRunning(id)) {
            launch(id, resume: true)
        }
    }

    private func launch(_ id: UUID, resume requested: Bool) {
        guard var s = session(id) else { return }
        // Only resume a conversation Claude Code actually saved; a session that never got a
        // message has an id but no transcript, and `claude --resume` would fail on it.
        let resume = requested && (s.claudeSessionId.map { ClaudeTranscripts.exists(sessionId: $0) } ?? false)
        if !resume { s.claudeSessionId = nil }
        terminals.start(s, resume: resume)
        // Every project session start updates recents (blank sessions in ~ are skipped).
        recents.record(path: s.directory)
        saveRecents()
        mutate(id) {
            $0.status = .starting
            $0.claudeNotFound = false
            $0.terminalTitle = nil
            $0.lastMessage = nil
            if !resume { $0.claudeSessionId = nil; $0.modelInfo = nil }
        }
        if id == selectedId { terminalFocusRequest += 1 }
    }

    /// S-7: "Resume" on an ended session.
    func resume(_ id: UUID) { launch(id, resume: true) }

    /// S-7: "New session" on an ended session: a fresh Claude conversation in the same folder.
    func startFresh(_ id: UUID) {
        launch(id, resume: false)
        persist()
    }

    // MARK: Restart / delete

    /// S-6: confirm only when Working.
    func requestRestart(_ id: UUID? = nil) {
        guard let id = id ?? selectedId, let s = session(id) else { return }
        if s.status == .working { confirmRestartId = id } else { restart(id) }
    }

    func restart(_ id: UUID) {
        confirmRestartId = nil
        launch(id, resume: true)
    }

    func requestDelete(_ id: UUID) { confirmDeleteId = id }

    /// S-8: terminates the process and removes it; Claude's transcript on disk is untouched.
    func delete(_ id: UUID) {
        confirmDeleteId = nil
        delete(Set([id]))
    }

    /// Removes several sessions in one pass (Delete group and its sessions). The selection moves
    /// once, to the nearest visible session that is not being deleted, so no session that is
    /// about to go away gets selected (and launched) on the way.
    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let r = renamingId, ids.contains(r) { renamingId = nil }
        for id in ids {
            terminals.remove(id)
            notifier.clear(sessionId: id)
        }
        let visible = visibleIds
        sessions.removeAll { ids.contains($0.id) }
        if let sel = selectedId, ids.contains(sel) {
            let idx = visible.firstIndex(of: sel) ?? 0
            let before = visible[..<min(idx, visible.count)].reversed().filter { session($0) != nil }
            let after = visible[min(idx, visible.count)...].filter { session($0) != nil }
            selectedId = after.first ?? before.first ?? sessions.first { !$0.isArchived }?.id ?? sessions.first?.id
            if let next = selectedId { select(next) }
        }
        persist()
    }

    // MARK: Archive / rename

    /// L-6: a running process keeps running.
    func toggleArchive(_ id: UUID? = nil) {
        guard let id = id ?? selectedId else { return }
        mutate(id) { $0.isArchived.toggle() }
        if session(id)?.isArchived == true { archivedOpen = true }
        persist()
    }

    /// `inHeader` edits the name in the top bar (double-click on the title) instead of the sidebar row.
    func beginRename(_ id: UUID? = nil, inHeader: Bool = false) {
        if showQuickSwitcher, let h = quickSwitcherHighlight {
            showQuickSwitcher = false
            select(h, focusTerminal: false)
            beginRename(h)
            return
        }
        guard let id = id ?? selectedId, let s = session(id) else { return }
        renamingInHeader = inHeader
        if inHeader {
            if selectedId != id { select(id, focusTerminal: false) }
            renamingId = id
            return
        }
        // A search that hides the row is cleared first, then its group / Archived is opened.
        if !query.isEmpty && !SidebarLayout.matches(s, query: query) { query = "" }
        reveal(id)
        if selectedId != id { select(id, focusTerminal: false) }
        renamingId = id
    }

    /// Expands what hides a session's row (its collapsed group, the closed Archived section),
    /// e.g. when the quick switcher or a notification selects it. Also while a search is shown,
    /// so the row is still visible once the search is cleared.
    private func reveal(_ id: UUID) {
        guard let s = session(id) else { return }
        if s.isArchived {
            if !archivedOpen { archivedOpen = true }
        } else if let g = group(s.groupId) {
            if g.isCollapsed { setCollapsed(g.id, false) }
        } else if !ungroupedOpen {
            ungroupedOpen = true
        }
    }

    /// Returns false when the name is rejected (empty).
    @discardableResult
    func commitRename(_ id: UUID, to name: String) -> Bool {
        guard let valid = SessionNaming.validatedRename(name) else { return false }
        mutate(id) { $0.name = valid }
        renamingId = nil
        persist()
        terminalFocusRequest += 1
        return true
    }

    func cancelRename() {
        renamingId = nil
        terminalFocusRequest += 1
    }

    func showError(_ title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    // MARK: Groups

    func toggleCollapsed(_ id: UUID) {
        guard let g = group(id) else { return }
        setCollapsed(id, !g.isCollapsed)
    }

    private func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == id }), groups[i].isCollapsed != collapsed else { return }
        groups[i].isCollapsed = collapsed
        persist()
    }

    /// Sidebar "New group…" (no Move option) or the session header's group chip (with Move).
    func showGroupSheet(movingSession sessionId: UUID? = nil) {
        showQuickSwitcher = false
        showNewSession = false
        groupSheet = GroupSheetRequest(mode: sessionId == nil ? .scratch : .fromSession, sessionId: sessionId, suggestedName: "")
    }

    func closeGroupSheet() {
        groupSheet = nil
        terminalFocusRequest += 1
    }

    /// Creates the group from the sheet and moves the session into it when asked.
    /// Returns false when the name is empty or taken.
    @discardableResult
    func createGroup(name: String, color: GroupColor, moving sessionId: UUID?) -> Bool {
        guard case .valid(let valid) = GroupNaming.validate(name, groups: groups) else { return false }
        let g = GroupOps.create(name: valid, color: color, groups: &groups)
        if let sessionId, session(sessionId) != nil {
            GroupOps.move(sessionId, to: g.id, sessions: &sessions)
        }
        groupSheet = nil
        persist()
        terminalFocusRequest += 1
        return true
    }

    func beginRenameGroup(_ id: UUID) {
        guard group(id) != nil else { return }
        renamingId = nil
        query = ""
        renamingGroupId = id
    }

    /// Returns false when the name is empty or used by another group (it is not saved).
    @discardableResult
    func commitRenameGroup(_ id: UUID, to name: String) -> Bool {
        guard case .valid(let valid) = GroupNaming.validate(name, groups: groups, excluding: id),
              let i = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[i].name = valid
        renamingGroupId = nil
        persist()
        terminalFocusRequest += 1
        return true
    }

    func cancelRenameGroup() {
        renamingGroupId = nil
        terminalFocusRequest += 1
    }

    func setGroupColor(_ id: UUID, _ color: GroupColor) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].color = color
        persist()
    }

    func requestDeleteGroup(_ id: UUID) {
        guard group(id) != nil else { return }
        confirmDeleteGroupId = id
    }

    /// Sessions the Delete group dialog talks about (archived ones included).
    func sessionCount(inGroup id: UUID) -> Int {
        sessions.filter { $0.groupId == id }.count
    }

    /// Deletes the group. Its sessions move to Ungrouped, or are deleted too (their claude
    /// processes are stopped; Claude's transcripts on disk are untouched).
    func deleteGroup(_ id: UUID, deleteSessions: Bool) {
        confirmDeleteGroupId = nil
        guard group(id) != nil else { return }
        if renamingGroupId == id { renamingGroupId = nil }
        if deleteSessions {
            delete(Set(GroupOps.allMembers(of: id, in: sessions).map(\.id)))
        } else {
            GroupOps.ungroupAll(id, sessions: &sessions)
        }
        groups.removeAll { $0.id == id }
        persist()
    }

    /// Drag and drop: into a group (nil = Ungrouped), before a row or at the end.
    /// An archived session dropped here is unarchived.
    func moveSession(_ id: UUID, toGroup groupId: UUID?, before: UUID? = nil) {
        guard session(id) != nil, groupId == nil || group(groupId) != nil else { return }
        GroupOps.move(id, to: groupId, before: before, sessions: &sessions)
        persist()
    }

    /// Drag and drop onto Archived.
    func archive(_ id: UUID) {
        guard session(id)?.isArchived == false else { return }
        toggleArchive(id)
    }

    /// Drag a group heading: before another group (nil = last, above Ungrouped).
    func moveGroup(_ id: UUID, before: UUID?) {
        GroupOps.moveGroup(id, before: before, groups: &groups)
        persist()
    }

    /// A drag starting on a session row or group heading. Ignored (no drop will accept it) while
    /// that item is being renamed or a search is shown.
    func beginSidebarDrag(_ drag: SidebarDragItem) {
        dropMark = nil
        switch drag {
        case .session(let id) where renamingId == id: sidebarDrag = nil
        case .group(let id) where renamingGroupId == id: sidebarDrag = nil
        default: sidebarDrag = query.isEmpty ? drag : nil
        }
    }

    /// A drag cancelled with Esc or dropped outside the sidebar never reaches performDrop, so
    /// its state is cleared on the next click.
    private func clearStaleSidebarDrag() {
        if sidebarDrag != nil { sidebarDrag = nil }
        if dropMark != nil { dropMark = nil }
    }

    func perform(_ action: SidebarDropAction) {
        switch action {
        case .moveSession(let id, let groupId, let before): moveSession(id, toGroup: groupId, before: before)
        case .archive(let id): archive(id)
        case .moveGroup(let id, let before): moveGroup(id, before: before)
        }
    }

    // MARK: Export

    /// Saves the session's whole conversation as Markdown (from Claude Code's transcript).
    func exportSession(_ id: UUID? = nil) {
        guard let s = session(id ?? selectedId) else { return }
        guard let claudeId = s.claudeSessionId, let transcript = ClaudeTranscripts.url(sessionId: claudeId) else {
            showError("Nothing to export yet", "“\(s.name)” has no saved conversation. Claude Code saves it after the first message.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.message = "Save the whole conversation of “\(s.name)” as Markdown"
        panel.nameFieldStringValue = TranscriptExporter.suggestedFileName(for: s.name)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let metadata = TranscriptExporter.Metadata(title: s.name, directory: s.directory, model: s.modelInfo, claudeSessionId: claudeId)
        Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: transcript)
                let markdown = TranscriptExporter.markdown(transcript: data, metadata: metadata)
                try Data(markdown.utf8).write(to: destination, options: .atomic)
            } catch {
                await MainActor.run { [weak self] in
                    self?.showError("Couldn’t export “\(metadata.title)”", error.localizedDescription)
                }
            }
        }
    }

    // MARK: Navigation

    func focusSearch() {
        showQuickSwitcher = false
        showNewSession = false
        searchFocusRequest += 1
    }

    func focusTerminal() { terminalFocusRequest += 1 }

    func toggleQuickSwitcher() {
        showNewSession = false
        showQuickSwitcher.toggle()
        if !showQuickSwitcher { terminalFocusRequest += 1 }
    }

    func closeQuickSwitcher() {
        showQuickSwitcher = false
        terminalFocusRequest += 1
    }

    /// F-3: ⌘1…⌘9.
    func selectVisible(index: Int) {
        if showNewSession { openRecent(at: index); return }
        let ids = visibleIds
        guard ids.indices.contains(index) else { return }
        select(ids[index])
    }

    func selectNext(_ delta: Int) {
        let ids = visibleIds
        guard !ids.isEmpty else { return }
        let cur = selectedId.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        let next = (cur + delta + ids.count) % ids.count
        select(ids[next])
    }

    // MARK: App activation / unread

    func appDidBecomeActive() {
        if let id = selectedId { markRead(id) }
        git.refresh()
    }

    private func markRead(_ id: UUID) {
        guard session(id)?.unread == true else { return }
        mutate(id) { $0.unread = false }
        notifier.clear(sessionId: id)
        persist()
    }

    private func updateBadge() {
        notifier.setBadge(sessions.filter(\.unread).count)
    }

    // MARK: Hooks

    func refreshHookState() {
        hooksInstalled = installer.isInstalled()
    }

    func installHooks() {
        do {
            try installer.install()
            showHookSheet = false
        } catch {
            showError("Couldn’t install hooks", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        refreshHookState()
    }

    private func handle(_ events: [HookEvent]) {
        var changed = false
        for event in events {
            guard let i = sessions.firstIndex(where: { $0.id == event.appSessionId }) else { continue }
            var s = sessions[i]
            let alert = SessionReducer.apply(event, to: &s, isFocused: isFocused(s.id))
            sessions[i] = s
            changed = true
            if let alert { notifier.post(alert) }
            if s.id == selectedId { git.refresh() } // Claude may have committed or switched branches
        }
        if changed { persist() }
    }

    private func processExited(_ id: UUID, exitCode: Int32?) {
        mutate(id) {
            $0.status = .ended
            $0.claudeNotFound = exitCode == LaunchCommand.claudeNotFoundExitCode
            $0.lastActivity = Date()
        }
        persist()
    }

    // MARK: Persistence

    private func mutate(_ id: UUID, _ f: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        f(&sessions[i])
    }

    private func saveRecents() {
        do { try recents.save(to: paths.recentsFile) } catch {
            NSLog("Bubblegum: could not save recent projects: \(error)")
        }
    }

    private func persist() {
        let state = PersistedState(sessions: sessions, groups: groups, selectedId: selectedId, archivedOpen: archivedOpen,
                                   ungroupedOpen: ungroupedOpen)
        do { try state.save(to: paths.sessionsFile) } catch {
            NSLog("Bubblegum: could not save sessions: \(error)")
        }
    }

    #if DEBUG
    /// Snapshot aid: end the selected session's process to show the Ended bar.
    func debugEnd() {
        if let id = selectedId { terminals.remove(id); processExited(id, exitCode: 0) }
    }
    #endif

    func shutdown() {
        persist()
        watcher?.stop()
        terminals.terminateAll()
    }
}

/// What the Create group sheet was opened for.
struct GroupSheetRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        /// Sidebar "New group…": no Move option.
        case scratch
        /// The session header's group chip: "Move <session> into this group", on by default.
        case fromSession
        /// Opened after the first session in a folder was created; Cancel keeps it in Ungrouped.
        case newFolder
    }

    let id = UUID()
    var mode: Mode
    var sessionId: UUID?
    var suggestedName: String
}
