import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published var isEnabled = true

    func requestAuthorizationIfNeeded() async {
        let current = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if current == .notDetermined {
            do {
                isAuthorized = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .badge, .sound]
                )
            } catch {
                isAuthorized = false
            }
            return
        }

        isAuthorized = current == .authorized || current == .provisional || current == .ephemeral
    }

    func scheduleIncomingMessageNotification(from sender: String, body: String, urgent: Bool) async {
        guard isEnabled, isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "New message from \(sender)"
        content.body = body
        content.badge = NSNumber(value: 1)
        content.sound = .default
        if urgent {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        try? await UNUserNotificationCenter.current().add(request)
    }
}
