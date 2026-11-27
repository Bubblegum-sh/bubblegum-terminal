import AppKit
import SwiftUI
import BubblegumCore

struct SessionDetailView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.theme) private var theme
    @State private var branchOpen = false

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
        .overlayPreferenceValue(BranchPillAnchorKey.self) { branchSwitcher($0) }
        .onChange(of: store.selectedId) { _, _ in branchOpen = false }
    }

    /// The branch switcher, opened under the branch pill; a click anywhere else closes it.
    @ViewBuilder
    private func branchSwitcher(_ anchor: Anchor<CGRect>?) -> some View {
        if branchOpen, let anchor {
            GeometryReader { proxy in
                let pill = proxy[anchor]
                let width: CGFloat = 370
                let x = min(max(pill.midX - width / 2, 8), proxy.size.width - width - 8)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { closeBranchSwitcher() }
                        .accessibilityHidden(true)
                    BranchSwitcherPanel(git: store.git, close: closeBranchSwitcher)
                        .offset(x: x, y: pill.maxY + 6)
                }
            }
        }
    }

    private func closeBranchSwitcher() {
        branchOpen = false
        store.focusTerminal()
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
                BranchPill(git: store.git, isOpen: $branchOpen)
                StatusPill(session: s)
                if let info = s.modelInfo {
                    ModelPill(info: info)
                }
            } else {
                WindowDragArea()
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
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

/// Model and reasoning effort from the session's last answer (read from its transcript).
struct ModelPill: View {
    let info: ModelInfo
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Burst()
                .stroke(theme.accentC, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(info.displayModel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text1)
                .lineLimit(1)
            if let level = info.effortLevel, let label = info.effortLabel {
                Rectangle().fill(theme.borderC).frame(width: 1, height: 12)
                EffortBars(level: level)
                Text("\(label) effort")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .overlay(Capsule().stroke(theme.borderC, lineWidth: 1))
        .fixedSize()
        .help("Model and reasoning effort of the last answer")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var t = "Model \(info.displayModel)"
        if let label = info.effortLabel { t += ", \(label.lowercased()) effort" }
        return t
    }
}

/// Five rising bars; the first `level` are filled in accent.
private struct EffortBars: View {
    let level: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...ModelInfo.effortLevels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? theme.accentC : theme.text3.opacity(0.35))
                    .frame(width: 3, height: 4 + CGFloat(i) * 1.6)
            }
        }
        .frame(height: 12, alignment: .bottom)
    }
}

/// A small eight-ray starburst.
private struct Burst: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.38
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            p.move(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
            p.addLine(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
        }
        return p
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
