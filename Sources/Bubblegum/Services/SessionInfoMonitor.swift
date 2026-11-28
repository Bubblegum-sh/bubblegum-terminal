import Foundation
import BubblegumCore

/// Live Session Info for the open popover. The transcript is parsed incrementally on a
/// background actor; the file is watched with a DispatchSource, and while the session is
/// running a slow timer also picks up subagent transcripts and a transcript that appears late.
@MainActor
final class SessionInfoMonitor: ObservableObject {
    @Published private(set) var info: SessionInfo?

    private var claudeId: String?
    private var reader: SessionInfoReader<ClaudeSessionInfoProvider>?
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var timer: Timer?
    private var refreshing = false
    private var refreshAgain = false

    static let pollInterval: TimeInterval = 2

    /// Call on appear and whenever the session's Claude id or running state changes.
    func track(claudeId: String?, running: Bool) {
        if claudeId != self.claudeId {
            stopWatching()
            self.claudeId = claudeId
            info = nil
            reader = claudeId.map { SessionInfoReader(provider: ClaudeSessionInfoProvider(), sessionId: $0) }
        }
        timer?.invalidate()
        timer = nil
        if running, reader != nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopWatching()
        reader = nil
        claudeId = nil
    }

    private func refresh() {
        guard let reader else { return }
        // One read at a time; changes that arrive meanwhile get one more pass.
        if refreshing { refreshAgain = true; return }
        refreshing = true
        Task { [weak self] in
            let result = await reader.refresh()
            let main = await reader.mainFile
            guard let self, self.reader === reader else { return }
            self.refreshing = false
            if self.info != result { self.info = result }
            self.watch(main)
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    private func watch(_ url: URL?) {
        guard url?.path != watchedPath else { return }
        stopWatching()
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let events = src?.data, !events.isDisjoint(with: [.delete, .rename]) {
                    self.stopWatching() // the next refresh finds the file again
                }
                self.refresh()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        watchedPath = url.path
        src.resume()
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        watchedPath = nil
    }
}
