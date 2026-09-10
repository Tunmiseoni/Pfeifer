import Foundation
import UserNotifications

/// Surfaces user-visible notices (clipboard fallback, errors).
public protocol Notifier: Sendable {
    /// Fire-and-forget: delivery is best effort; a denied permission must
    /// never fail the dictation flow that triggered it.
    func notify(title: String, body: String) async
}

/// UNUserNotificationCenter-backed notifier. Requires the host to be a
/// proper bundle with a stable identifier and notification authorization —
/// the app shell requests auth on the first clipboard fallback; tests use
/// a mock because the test runner is not a bundled app.
public struct UserNotifier: Notifier {
    public init() {}

    public func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "pfeifer-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        _ = try? await UNUserNotificationCenter.current().add(request)
    }
}
