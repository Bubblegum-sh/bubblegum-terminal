import AppKit
import FlamingoCore
import UserNotifications

/// macOS notification banners and the Dock badge (N-3, N-4, N-5).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when the user clicks a notification for a session.
    var onOpen: ((UUID) -> Void)?

    /// UNUserNotificationCenter needs a real app bundle; it traps when run as a bare executable.
    private let available = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ alert: SessionAlert) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.sessionId.uuidString
        content.userInfo = ["sessionId": alert.sessionId.uuidString]
        // One banner per session: a newer one replaces the previous.
        let request = UNNotificationRequest(identifier: alert.sessionId.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clear(sessionId: UUID) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sessionId.uuidString])
    }

    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The store only posts for sessions that are not focused, so show it even when the app is active.
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let idString = response.notification.request.content.userInfo["sessionId"] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let idString, let id = UUID(uuidString: idString) { self.onOpen?(id) }
        }
    }
}
