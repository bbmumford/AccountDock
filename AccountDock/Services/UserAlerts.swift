import Foundation
import UserNotifications

/// Posts macOS notifications for problems that need the user and cannot wait
/// until they next open the menu, such as an account whose sign-in was
/// rejected. Each kind of alert is posted at most once per `minimumInterval`.
@MainActor
final class UserAlerts {
    static let shared = UserAlerts()

    private var lastPosted: [String: Date] = [:]
    private var authorizationRequested = false

    func post(id: String, title: String, body: String, minimumInterval: TimeInterval = 6 * 60 * 60) {
        if let last = lastPosted[id], Date().timeIntervalSince(last) < minimumInterval { return }
        lastPosted[id] = Date()
        let center = UNUserNotificationCenter.current()
        let request = UNNotificationRequest(identifier: id, content: {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            return content
        }(), trigger: nil)
        let askFirst = !authorizationRequested
        authorizationRequested = true
        Task {
            if askFirst { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            try? await center.add(request)
        }
    }
}
