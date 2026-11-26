import Foundation

/// Watches the events folder and delivers parsed hook events on the main queue.
/// Event-driven (DispatchSource on the directory), no polling.
public final class HookEventWatcher: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "dev.flamingo.hook-events")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let handler: @MainActor ([HookEvent]) -> Void

    public init(directory: URL, handler: @escaping @MainActor ([HookEvent]) -> Void) {
        self.directory = directory
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard source == nil else { return }
            fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
            src.setEventHandler { [weak self] in self?.drain() }
            src.setCancelHandler { [fd] in close(fd) }
            source = src
            src.resume()
            drain() // leftovers from while the app was not running
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    /// Reads all pending `*.json` files (oldest first), deletes them, and dispatches the events.
    private func drain() {
        let events = Self.drain(directory: directory)
        guard !events.isEmpty else { return }
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(events) }
        }
    }

    /// Synchronous drain, exposed for tests.
    public static func drain(directory: URL) -> [HookEvent] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        struct Entry { let url: URL; let date: Date }
        var files: [Entry] = []
        for url in urls where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            let date = (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? Date.distantPast
            files.append(Entry(url: url, date: date))
        }
        files.sort { a, b in
            a.date == b.date ? a.url.lastPathComponent < b.url.lastPathComponent : a.date < b.date
        }

        var events: [HookEvent] = []
        for url in files.map(\.url) {
            let data = try? Data(contentsOf: url)
            try? fm.removeItem(at: url)
            if let data, let e = HookEvent.parse(data) { events.append(e) }
        }
        return events
    }
}
