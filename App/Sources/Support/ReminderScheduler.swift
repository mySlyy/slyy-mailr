import Foundation
import UserNotifications
import SlyyMailKit

/// Local notifications for upcoming events, with a "Join" action when the event has a video link.
enum ReminderScheduler {
    static let category = "SLYY_MEETING"
    static let joinAction = "SLYY_JOIN"
    static let prefix = "slyy.event."

    static func registerCategories() {
        let join = UNNotificationAction(identifier: joinAction, title: String(localized: "Join video call"), options: [.foreground])
        let meeting = UNNotificationCategory(identifier: category, actions: [join], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([meeting])
    }

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Replaces all scheduled reminders with those for the next 7 days (max 60; iOS keeps 64).
    static func schedule(_ events: [CalendarEvent]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        let now = Date()
        let horizon = now.addingTimeInterval(7 * 86400)
        let due = events.compactMap { e -> (CalendarEvent, Date)? in
            guard !e.isCancelled, let minutes = e.alarmMinutes else { return nil }
            let fire = e.start.addingTimeInterval(-Double(minutes) * 60)
            return fire > now && fire < horizon ? (e, fire) : nil
        }
        .sorted { $0.1 < $1.1 }
        .prefix(60)

        let timeFormat = DateFormatter()
        timeFormat.timeStyle = .short
        for (e, fire) in due {
            let content = UNMutableNotificationContent()
            content.title = e.summary.isEmpty ? String(localized: "Event") : e.summary
            var body = e.isAllDay ? String(localized: "All day") : timeFormat.string(from: e.start)
            if !e.location.isEmpty, e.location != e.videoURL?.absoluteString { body += " · " + e.location }
            content.body = body
            content.sound = .default
            if let v = e.videoURL {
                content.categoryIdentifier = category
                content.userInfo = ["videoURL": v.absoluteString]
            }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            let req = UNNotificationRequest(identifier: prefix + e.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}
