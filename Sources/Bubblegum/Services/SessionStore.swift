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
    @Published var query: String = ""
    @Published var archivedOpen: Bool = true { didSet { if archivedOpen != oldValue { persist() } } }

    // UI state
    @Published var renamingId: UUID?
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

    init(paths: AppPaths = .standard) {
        self.paths = paths
        self.installer = HookInstaller(paths: paths)
        LegacyMigration.run(paths: paths) // from "Flamingo" / "Terminal Flamingo": data folder + hook paths
        if let state = PersistedState.load(from: paths.sessionsFile) {
            sessions = state.sessions.map { var s = $0; s.status = .paused; return s }
            selectedId = state.selectedId.flatMap { id in sessions.contains { $0.id == id } ? id : nil }
            archivedOpen = state.archivedOpen
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
        SidebarLayout.items(sessions: sessions, query: query, archivedOpen: archivedOpen)
    }

    var visibleIds: [UUID] { SidebarLayout.visibleIds(sidebarItems) }

    private func isFocused(_ id: UUID) -> Bool {
        NSApp.isActive && selectedId == id
    }

    // MARK: Create / open

    /// S-1: ⌘T or "+" opens the New session sheet.
    func showNewSessionSheet() {
        showQuickSwitcher = false
        if recents.prune() { saveRecents() }
        newSessionFilter = ""
        newSessionIndex = 0
        showNewSession = true
    }

    func closeNewSessionSheet() {
        showNewSession = false
        terminalFocusRequest += 1
    }

    /// Recent rows as shown in the sheet (filtered, newest first, max 9).
    var visibleRecents: [RecentProject] { recents.visible(filter: newSessionFilter) }

    func sessionCount(inFolder path: String) -> Int {
        let p = (path as NSString).standardizingPath
        return sessions.filter { ($0.directory as NSString).standardizingPath == p }.count
    }

    /// Opening a recent project always creates a new session in that folder.
    func openRecent(at index: Int) {
        let list = visibleRecents
        guard list.indices.contains(index) else { return }
        let path = list[index].path
        showNewSession = false
        guard RecentProjects.directoryExists(path) else {
            recents.prune()
            saveRecents()
            showError("Project folder not found", "\(Session.abbreviate(path)) no longer exists.")
            return
        }
        createSession(directory: path)
    }

    /// Blank session (⌘N): no project, starts in the home folder.
    func startBlankSession() {
        showNewSession = false
        let name = SessionNaming.unique(SessionNaming.blankSessionName, existing: sessions.map(\.name))
        createSession(directory: NSHomeDirectory(), name: name)
    }

    /// Open project… (⌘O): folder picker.
    func openProjectWithPicker() {
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
        createSession(directory: url.path)
    }

    func createSession(directory: String, name: String? = nil) {
        let name = name ?? SessionNaming.unique(SessionNaming.defaultName(for: directory), existing: sessions.map(\.name))
        let s = Session(name: name, directory: directory, status: .paused)
        sessions.append(s)
        query = ""
        select(s.id, focusTerminal: true)
        persist()
    }

    /// Selecting is "opening": a Paused session resumes (S-5).
    func select(_ id: UUID, focusTerminal: Bool = true) {
        guard session(id) != nil else { return }
        if renamingId != nil && renamingId != id { renamingId = nil }
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
        if renamingId == id { renamingId = nil }
        terminals.remove(id)
        notifier.clear(sessionId: id)
        let visible = visibleIds
        sessions.removeAll { $0.id == id }
        if selectedId == id {
            let idx = visible.firstIndex(of: id) ?? 0
            let remaining = visible.filter { $0 != id && session($0) != nil }
            selectedId = remaining.isEmpty ? sessions.first?.id : remaining[min(idx, remaining.count - 1)]
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

    func beginRename(_ id: UUID? = nil) {
        if showQuickSwitcher, let h = quickSwitcherHighlight {
            showQuickSwitcher = false
            select(h, focusTerminal: false)
            beginRename(h)
            return
        }
        guard let id = id ?? selectedId, let s = session(id) else { return }
        if s.isArchived { archivedOpen = true }
        if !query.isEmpty && !SidebarLayout.matches(s, query: query) { query = "" }
        if selectedId != id { select(id, focusTerminal: false) }
        renamingId = id
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
        let state = PersistedState(sessions: sessions, selectedId: selectedId, archivedOpen: archivedOpen)
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
