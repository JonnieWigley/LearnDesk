import Foundation
import UserNotifications

/// Local notifications. Only works when running as a bundled .app (not via `swift run`).
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static var enabled: Bool {
        available && UserDefaults.standard.bool(forKey: Prefs.notifications)
    }

    static func requestPermission() async -> Bool {
        guard available else { return false }
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    static func send(title: String, body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
