import Foundation
import UserNotifications

/// macOS banners for a session that needs you. Only a real bundle can post them (a bare binary has no
/// bundle id and UNUserNotificationCenter would crash); without one, or without permission, the page's
/// toast is all there is.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var isAuthorized = false
    private let isAvailable: Bool
    var onOpen: ((String) -> Void)?

    override init() {
        isAvailable = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        super.init()
    }

    func requestPermission() {
        guard isAvailable else {
            Log.info("notifications: not a bundle run; toasts only")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isAuthorized = granted
                    Log.info("notifications: \(granted ? "allowed" : "not allowed\(error.map { " (\($0.localizedDescription))" } ?? ""); toasts only")")
                }
            }
        }
    }

    func post(sessionID: String, title: String, body: String) {
        guard isAvailable, isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sid": sessionID]
        content.threadIdentifier = sessionID
        let request = UNNotificationRequest(identifier: "needs-\(sessionID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.warn("notifications: could not post: \(error.localizedDescription)") }
        }
    }

    func clear(sessionID: String) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["needs-\(sessionID)"])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let sid = response.notification.request.content.userInfo["sid"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let sid { self.onOpen?(sid) }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
