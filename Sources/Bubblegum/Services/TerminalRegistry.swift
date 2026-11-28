import AppKit
import SwiftTerm
import BubblegumCore

/// Terminal view with file drag-and-drop (T-5).
final class TFTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        send(txt: urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// Backslash-escapes characters the shell treats specially, like Terminal.app does.
    static func shellEscape(_ path: String) -> String {
        let special = Set(" \t\n\\'\"`$&|;<>()[]{}*?!#~=%^")
        var out = ""
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// One running (or finished) terminal for a session.
@MainActor
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let sessionId: UUID
    let view: TFTerminalView
    weak var registry: TerminalRegistry?
    private(set) var exited = false

    init(sessionId: UUID) {
        self.sessionId = sessionId
        self.view = TFTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.processDelegate = self
        view.optionAsMetaKey = true
    }

    func start(directory: String, resumeId: String?, newSessionId: String?) {
        let shell = LaunchCommand.shell()
        view.startProcess(
            executable: shell,
            args: LaunchCommand.arguments(directory: directory, resumeId: resumeId, newSessionId: newSessionId),
            environment: LaunchCommand.environment(sessionId: sessionId),
            execName: nil,
            currentDirectory: FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
        )
    }

    func terminate() {
        guard !exited else { return }
        exited = true
        view.terminate()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        registry?.titleChanged(self, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        exited = true
        registry?.processExited(self, exitCode: exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        exited = true
        registry?.processExited(self, exitCode: nil)
    }

    func bellRang(source: LocalProcessTerminalView, style: BellStyle) {}
}

/// Creates and caches one terminal view per session so switching never kills or redraws a process (S-3).
@MainActor
final class TerminalRegistry {
    private var controllers: [UUID: TerminalController] = [:]
    var onExit: ((UUID, Int32?) -> Void)?
    var onTitle: ((UUID, String) -> Void)?

    private var theme: Theme = .dark
    private var fontSize: CGFloat = 13

    func view(for id: UUID) -> TFTerminalView? { controllers[id]?.view }

    func isRunning(_ id: UUID) -> Bool {
        guard let c = controllers[id] else { return false }
        return !c.exited
    }

    /// Starts a fresh process for the session, replacing any previous terminal. With `resume`,
    /// `claude --resume <claudeSessionId>`; otherwise `claude --session-id <claudeSessionId>`.
    func start(_ session: Session, resume: Bool) {
        remove(session.id)
        let c = TerminalController(sessionId: session.id)
        c.registry = self
        style(c.view)
        controllers[session.id] = c
        c.start(directory: session.directory, resumeId: resume ? session.claudeSessionId : nil,
                newSessionId: resume ? nil : session.claudeSessionId)
    }

    /// Terminates the process and drops the view.
    func remove(_ id: UUID) {
        guard let c = controllers.removeValue(forKey: id) else { return }
        c.registry = nil // a late exit callback from the old process is ignored
        c.terminate()
        c.view.removeFromSuperview()
    }

    func terminateAll() {
        for id in Array(controllers.keys) { remove(id) }
    }

    func applyAppearance(theme: Theme, fontSize: Int) {
        self.theme = theme
        self.fontSize = CGFloat(fontSize)
        for c in controllers.values { style(c.view) }
    }

    private func style(_ v: TFTerminalView) {
        let font = terminalFont(size: fontSize)
        if v.font != font { v.font = font }
        v.nativeBackgroundColor = theme.terminal
        v.nativeForegroundColor = theme.textPrimary
        v.caretColor = theme.accent
        v.selectedTextBackgroundColor = theme.accent.withAlphaComponent(theme.isDark ? 0.35 : 0.25)
        v.needsDisplay = true
    }

    fileprivate func titleChanged(_ c: TerminalController, title: String) {
        guard controllers[c.sessionId] === c else { return }
        onTitle?(c.sessionId, title)
    }

    fileprivate func processExited(_ c: TerminalController, exitCode: Int32?) {
        guard controllers[c.sessionId] === c else { return }
        onExit?(c.sessionId, exitCode)
    }
}
