import Foundation
import UserNotifications
import SlyyMailKit

/// One snoozed message: hidden from the list until `until`, then shown again (unread) with a reminder.
struct SnoozeEntry: Codable, Hashable {
    /// Message-ID when the mail has one, else folder + UID (see `SnoozeStore.key(for:)`).
    var key: String
    var until: Date
    var subject: String
    var sender: String
    var folder: String
    var uid: UInt32
    /// Messages snoozed together (a conversation) share this, and come back together on Unsnooze.
    var batch: String?

    init(_ s: MessageSummary, until: Date, batch: String? = nil) {
        key = SnoozeStore.key(for: s)
        self.batch = batch
        self.until = until
        subject = s.subject
        sender = s.from.first?.display ?? ""
        folder = s.folder
        uid = s.uid
    }

    /// Enough of a summary to set flags on the server (folder + UID).
    var summary: MessageSummary {
        MessageSummary(uid: uid, folder: folder, flags: [], date: until, size: 0, from: [], to: [], cc: [],
                       subject: subject, messageID: nil, hasAttachments: false, isInvite: false)
    }
}

/// Snoozed messages, kept in UserDefaults per account.
/// Snoozes live on this device only: they are not synced to the server or to the user's other devices.
enum SnoozeStore {
    static let prefix = "slyy.snooze."

    static func defaultsKey(_ account: UUID) -> String { "snoozes.v1.\(account.uuidString)" }

    /// Message-ID when present (survives moves between folders), else folder + UID.
    static func key(for s: MessageSummary) -> String {
        if let id = s.messageID?.trimmingCharacters(in: .whitespaces), !id.isEmpty { return "mid:" + id.lowercased() }
        return "uid:\(s.folder)#\(s.uid)"
    }

    static func entries(account: UUID, store: UserDefaults = .standard) -> [SnoozeEntry] {
        guard let data = store.data(forKey: defaultsKey(account)) else { return [] }
        return (try? JSONDecoder().decode([SnoozeEntry].self, from: data)) ?? []
    }

    static func save(_ list: [SnoozeEntry], account: UUID, store: UserDefaults = .standard) {
        if list.isEmpty {
            store.removeObject(forKey: defaultsKey(account))
        } else if let data = try? JSONEncoder().encode(list) {
            store.set(data, forKey: defaultsKey(account))
        }
    }

    /// Adds (or moves) snoozes; returns all of the account's snoozes.
    @discardableResult
    static func add(_ new: [SnoozeEntry], account: UUID, store: UserDefaults = .standard) -> [SnoozeEntry] {
        let keys = Set(new.map(\.key))
        let list = entries(account: account, store: store).filter { !keys.contains($0.key) } + new
        save(list, account: account, store: store)
        return list
    }

    /// Removes snoozes by key; returns the rest.
    @discardableResult
    static func remove(keys: Set<String>, account: UUID, store: UserDefaults = .standard) -> [SnoozeEntry] {
        let list = entries(account: account, store: store).filter { !keys.contains($0.key) }
        save(list, account: account, store: store)
        return list
    }

    /// Takes the snoozes that are due out of the store and returns them.
    static func takeDue(account: UUID, now: Date = Date(), store: UserDefaults = .standard) -> [SnoozeEntry] {
        let all = entries(account: account, store: store)
        let due = all.filter { $0.until <= now }
        if !due.isEmpty { save(all.filter { $0.until > now }, account: account, store: store) }
        return due
    }

    // MARK: Reminders

    /// The local notification for a snooze: "Reminder: <subject>", "From <sender>"; tapping it opens the message
    /// (AppDelegate → `AppModel.openFromNotification`).
    static func scheduleReminder(for e: SnoozeEntry) async {
        let c = UNMutableNotificationContent()
        let subject = e.subject.isEmpty ? String(localized: "(no subject)") : e.subject
        c.title = String(localized: "Reminder: \(subject)")
        if !e.sender.isEmpty { c.body = String(localized: "From \(e.sender)") }
        c.sound = .default
        c.categoryIdentifier = MailNotifier.category
        c.userInfo = ["folder": e.folder, "uid": Int(e.uid), "snooze": e.key]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: e.until)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: prefix + e.key, content: c, trigger: trigger))
    }

    static func cancelReminders(keys: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: keys.map { prefix + $0 })
    }
}
