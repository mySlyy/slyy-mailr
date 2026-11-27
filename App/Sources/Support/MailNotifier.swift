import Foundation
import UserNotifications
import SlyyMailKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "New mail" notifications. Remembers the highest Inbox UID already announced per account,
/// so every message is announced once, and nothing is announced on the first sync of an account.
enum MailNotifier {
    static let category = "SLYY_MAIL"
    static let prefix = "slyy.mail."
    /// At most this many single notifications per check; the rest become one summary.
    static let maxSingles = 3

    struct Arrivals: Equatable {
        var messages: [MessageSummary]
        var highestUID: UInt32
    }

    /// Unread Inbox messages above the last announced UID, newest first. nil = first run (baseline only).
    static func arrivals(in inbox: [MessageSummary], after lastUID: UInt32?) -> Arrivals? {
        let highest = inbox.map(\.uid).max() ?? (lastUID ?? 0)
        guard let lastUID else { return nil }
        let fresh = inbox.filter { $0.uid > lastUID && !$0.isSeen }.sorted { $0.uid > $1.uid }
        return Arrivals(messages: fresh, highestUID: max(highest, lastUID))
    }

    static func key(_ account: UUID) -> String { "notify.lastUID.\(account.uuidString)" }

    static func lastUID(account: UUID, store: UserDefaults = .standard) -> UInt32? {
        (store.object(forKey: key(account)) as? NSNumber)?.uint32Value
    }

    /// Checks the first Inbox page; posts notifications unless the user is looking at the app.
    @MainActor
    static func process(inbox: [MessageSummary], account: UUID, store: UserDefaults = .standard, force: Bool = false) async {
        let last = lastUID(account: account, store: store)
        guard let r = arrivals(in: inbox, after: last) else {
            if let top = inbox.map(\.uid).max() { store.set(NSNumber(value: top), forKey: key(account)) }
            return
        }
        store.set(NSNumber(value: r.highestUID), forKey: key(account))
        guard !r.messages.isEmpty, force || !appIsActive else { return }
        guard store.object(forKey: "notifyNewMail") as? Bool ?? true else { return }
        await post(r.messages)
    }

    @MainActor
    static var appIsActive: Bool {
        #if os(macOS)
        return NSApp?.isActive ?? false
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }

    static func post(_ list: [MessageSummary]) async {
        let center = UNUserNotificationCenter.current()
        for m in list.prefix(maxSingles) {
            let c = UNMutableNotificationContent()
            c.title = m.from.first?.display ?? String(localized: "New message")
            c.body = m.subject.isEmpty ? String(localized: "(no subject)") : m.subject
            c.sound = .default
            c.threadIdentifier = "inbox"
            c.categoryIdentifier = category
            c.userInfo = ["folder": m.folder, "uid": Int(m.uid)]
            try? await center.add(UNNotificationRequest(identifier: prefix + m.id, content: c, trigger: nil))
        }
        if list.count > maxSingles {
            let c = UNMutableNotificationContent()
            c.title = String(localized: "\(list.count - maxSingles) more new messages")
            c.body = list.dropFirst(maxSingles).prefix(3).compactMap { $0.from.first?.display }.joined(separator: ", ")
            c.threadIdentifier = "inbox"
            c.categoryIdentifier = category
            c.userInfo = ["folder": "INBOX"]
            try? await center.add(UNNotificationRequest(identifier: prefix + "more", content: c, trigger: nil))
        }
    }
}
