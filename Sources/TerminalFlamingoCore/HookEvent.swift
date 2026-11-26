import Foundation

/// One event written by `hook.sh`: `{"tf": "<TF_SESSION_ID>", "payload": <Claude Code hook JSON>}`.
public struct HookEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case notification = "Notification"
        case stop = "Stop"
    }

    public var appSessionId: UUID
    public var kind: Kind?
    public var rawEventName: String?
    public var claudeSessionId: String?
    public var cwd: String?
    public var message: String?

    public init(appSessionId: UUID, kind: Kind?, rawEventName: String? = nil, claudeSessionId: String? = nil, cwd: String? = nil, message: String? = nil) {
        self.appSessionId = appSessionId
        self.kind = kind
        self.rawEventName = rawEventName ?? kind?.rawValue
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
        self.message = message
    }

    /// Parses an event file. Returns nil for malformed files or a missing/invalid `tf` id.
    public static func parse(_ data: Data) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tf = obj["tf"] as? String,
              let id = UUID(uuidString: tf) else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let name = payload["hook_event_name"] as? String
        let sid = (payload["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HookEvent(
            appSessionId: id,
            kind: name.flatMap(Kind.init(rawValue:)),
            rawEventName: name,
            claudeSessionId: sid,
            cwd: payload["cwd"] as? String,
            message: payload["message"] as? String
        )
    }
}

/// What the app should tell the user after an event.
public struct SessionAlert: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case done, needsAnswer }
    public var sessionId: UUID
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var body: String
}

public enum SessionReducer {
    /// Applies a hook event to a session (section 6 of the spec).
    /// - Parameter isFocused: the app is active and this session is selected.
    /// - Returns: the alert to post, if any (N-3, N-7).
    @discardableResult
    public static func apply(_ event: HookEvent, to s: inout Session, isFocused: Bool, now: Date = Date()) -> SessionAlert? {
        if let sid = event.claudeSessionId { s.claudeSessionId = sid }
        s.lastActivity = now
        guard let kind = event.kind else { return nil }

        switch kind {
        case .sessionStart:
            // No status change, except that "Starting…" means "no hook event yet":
            // once Claude reports in, it is waiting for the user's first prompt.
            if s.status == .starting { s.status = .idle }
            return nil

        case .userPromptSubmit:
            s.status = .working
            s.lastMessage = nil
            return nil

        case .notification:
            let message = event.message ?? "Claude needs your attention"
            if s.status == .idle {
                // N-7: Claude's idle reminder. Update the message, don't notify again.
                s.lastMessage = message
                return nil
            }
            s.status = .waiting
            s.lastMessage = message
            if isFocused { return nil }
            s.unread = true
            return SessionAlert(sessionId: s.id, kind: .needsAnswer, title: s.name, subtitle: "Needs your answer", body: message)

        case .stop:
            s.status = .idle
            s.lastMessage = nil
            if isFocused { return nil }
            s.unread = true
            return SessionAlert(sessionId: s.id, kind: .done, title: s.name, subtitle: "Done", body: "Claude finished and is waiting for your next task")
        }
    }
}
