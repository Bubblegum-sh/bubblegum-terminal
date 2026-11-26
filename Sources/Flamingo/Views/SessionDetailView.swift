import AppKit
import SwiftUI
import FlamingoCore

struct SessionDetailView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 52)
                .background(theme.windowC)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.borderC).frame(height: 1) }

            ZStack(alignment: .bottom) {
                theme.terminalC
                if let s = store.selected {
                    TerminalHost(
                        sessionId: s.id,
                        status: s.status,
                        focusToken: store.terminalFocusRequest,
                        registry: store.terminals
                    )
                    .padding(.top, 18)
                    .padding(.horizontal, 22)
                    .padding(.bottom, s.status == .ended ? 64 : 16)
                    .accessibilityLabel("Terminal")

                    if s.status == .ended {
                        EndedBar(session: s)
                    }
                } else {
                    emptyState
                }
            }
        }
    }

    // MARK: Toolbar (N-2)

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            if let s = store.selected {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name)
                        .font(TFFont.toolbarTitle)
                        .lineLimit(1)
                    Text(pathLine(s))
                        .font(TFFont.path)
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)
                WindowDragArea().frame(maxWidth: .infinity)
                StatusPill(session: s)
                IconButton(systemImage: "pencil", label: "Rename session (⌘R)") { store.beginRename(s.id) }
                IconButton(systemImage: "arrow.clockwise", label: "Restart session") { store.requestRestart(s.id) }
            } else {
                WindowDragArea()
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
    }

    private func pathLine(_ s: Session) -> String {
        var line = s.displayPath
        if let id = s.claudeSessionId {
            line += " · claude --resume \(id.prefix(4))…"
        }
        return line
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No sessions yet — ⌘T to start one")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.text2)
            Button("New Session…") { store.showNewSessionSheet() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusPill: View {
    let session: Session
    @Environment(\.theme) private var theme

    var body: some View {
        let label = session.isArchived ? "Archived" : session.status.label
        HStack(spacing: 6) {
            Circle().fill(theme.statusC(session.status)).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .fixedSize()
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .background(Capsule().fill(theme.elevatedC))
        .help(session.status.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(label)")
    }
}

/// S-7: shown when the claude process has exited.
struct EndedBar: View {
    let session: Session
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.claudeNotFound ? "exclamationmark.triangle.fill" : "stop.circle")
                .foregroundStyle(session.claudeNotFound ? theme.statusC(.working) : theme.text3)
            Text(session.claudeNotFound
                 ? "claude was not found in your PATH. Check ~/.zshrc or ~/.zprofile, then resume."
                 : "Session ended")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .lineLimit(2)
            Spacer()
            Button("New session") { store.startFresh(session.id) }
                .help("Start a fresh Claude conversation in this folder")
            Button("Resume") { store.resume(session.id) }
                .keyboardShortcut(.defaultAction)
                .help(session.claudeSessionId == nil ? "Start Claude again" : "Resume the previous conversation")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.elevatedC))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderC))
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }
}

/// Hosts the cached terminal view for the selected session. Swapping sessions only
/// swaps subviews; the processes keep running in the registry (S-3).
struct TerminalHost: NSViewRepresentable {
    let sessionId: UUID
    /// Included so the view updates when the registry replaces the terminal (restart / resume).
    let status: SessionStatus
    let focusToken: Int
    let registry: TerminalRegistry

    final class Coordinator {
        var lastFocusToken: Int?
    }

    final class HostView: NSView {
        weak var current: NSView?
        override var isFlipped: Bool { true }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let v = HostView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ host: HostView, context: Context) {
        let term = registry.view(for: sessionId)
        if host.current !== term {
            host.current?.removeFromSuperview()
            if let term {
                term.removeFromSuperview()
                term.frame = host.bounds
                term.autoresizingMask = [.width, .height]
                host.addSubview(term)
            }
            host.current = term
        }
        // T-2: take focus only when explicitly requested (selection, new session),
        // never on background status updates.
        if let term, context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        }
    }
}
