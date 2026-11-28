import Foundation
import SlyyMailKit
@testable import SlyyMailr

// MARK: - Sample data (tests, screenshots)

@MainActor
extension AppModel {
    /// A model filled with the wireframe's sample content; never connects to a server.
    static func sample(calendar: Bool = false, conversation: Bool = false) -> AppModel {
        let account = AccountSettings(
            email: "anna@slyy.ai", displayName: "Anna Weber",
            imap: ServerEndpoint(host: "mail.mc1.simplify-erp.de", port: 993, security: .tls),
            smtp: ServerEndpoint(host: "mail.mc1.simplify-erp.de", port: 587, security: .startTLS),
            caldavURL: "https://mail.mc1.simplify-erp.de/"
        )
        var withAlias = account
        withAlias.aliases = [SenderIdentity(name: "Slyy Info", email: "info@slyy.ai", signature: "Slyy · info@slyy.ai")]
        func folder(_ path: String, _ use: SpecialUse?, unseen: Int = 0, total: Int = 0) -> IMAPFolder {
            IMAPFolder(path: path, serverPath: path, name: path.components(separatedBy: "/").last!, delimiter: "/", flags: [], specialUse: use, unseen: unseen, total: total)
        }
        var folders = [
            folder("INBOX", .inbox, unseen: 12, total: 240), folder("Drafts", .drafts, total: 2), folder("Sent", .sent),
            folder("Archive", .archive), folder("Junk", .junk, unseen: 4), folder("Trash", .trash),
            folder("Kunden", nil), folder("Kunden/Angebote", nil), folder("Lieferanten", nil),
        ]
        folders[0].name = "Inbox"
        let now = Date()
        func summary(_ uid: UInt32, _ name: String, _ addr: String, _ subject: String, _ ago: TimeInterval, seen: Bool, flags: Set<String> = [], attach: Bool = false, invite: Bool = false, folder: String = "INBOX", refs: [String]? = nil) -> MessageSummary {
            MessageSummary(uid: uid, folder: folder, flags: seen ? flags.union(["\\Seen"]) : flags, date: now.addingTimeInterval(-ago), size: 4000,
                           from: [EmailAddress(name: name, address: addr)], to: [account.address], cc: [], subject: subject, messageID: "<\(uid)@slyy.ai>",
                           hasAttachments: attach, isInvite: invite, inReplyTo: refs?.last, references: refs)
        }
        let messages = [
            summary(5, "Heiko Meier", "heiko@slyy.ai", "ERP Wochenfazit", 1200, seen: false, invite: true),
            summary(4, "Brandt Logistik", "dispo@brandt-logistik.de", "Lieferavis KW 49", 5400, seen: false, attach: true),
            summary(3, "Jürgen Schott", "j.schott@schott-haustechnik.de", "Re: Angebot Wärmepumpe", 86400, seen: false, flags: ["\\Flagged"], refs: ["<6@slyy.ai>", "<90@slyy.ai>"]),
            summary(2, "Bob Krause", "bob@slyy.ai", "Accepted: Planung Q1", 2 * 86400, seen: true),
            summary(1, "Finanzamt Bayreuth", "poststelle@finanzamt.bayern.de", "Bescheid über Umsatzsteuer", 3 * 86400, seen: true, attach: true),
            summary(6, "Jürgen Schott", "j.schott@schott-haustechnik.de", "Angebot Wärmepumpe", 4 * 86400, seen: true, flags: ["\\Answered"], attach: true),
        ]
        let sentReply = summary(90, "Anna Weber", "anna@slyy.ai", "Re: Angebot Wärmepumpe", 2 * 86400, seen: true, folder: "Sent", refs: ["<6@slyy.ai>"])

        // Week of today: a recurring video meeting on Friday 10:00, plus a few others.
        var cal = Calendar.current
        cal.firstWeekday = 2
        let week = cal.dateInterval(of: .weekOfYear, for: now)!.start
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { cal.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: week)! }
        let room = URL(string: "https://vid.rocket.re-cloud.io/slyy-k7m2q9xwt4bh8nzr3fpe")!
        var weekly = CalendarEvent(uid: "wochenfazit", summary: "ERP Wochenfazit", notes: "Status zu Angeboten, Lager und offenen Rechnungen.", start: at(4, 10), end: at(4, 10, 30),
                                   recurrence: RecurrenceRule(frequency: .weekly), organizer: EmailAddress(name: "Heiko Meier", address: "heiko@slyy.ai"),
                                   attendees: [Attendee(email: "heiko@slyy.ai", name: "Heiko Meier", status: .accepted), Attendee(email: "anna@slyy.ai", name: "Anna Weber", status: .accepted),
                                               Attendee(email: "j.schott@schott-haustechnik.de", name: "Jürgen Schott", status: .tentative), Attendee(email: "bob@slyy.ai", name: "Bob Krause")],
                                   videoURL: room)
        weekly.calendarURL = "anna"
        var e2 = CalendarEvent(uid: "jf", summary: "Jour fixe", start: at(0, 9), end: at(0, 10)); e2.calendarURL = "anna"
        var e3 = CalendarEvent(uid: "schott", summary: "Kundentermin Schott", location: "Bayreuth", start: at(1, 14), end: at(1, 15, 30), videoURL: room); e3.calendarURL = "anna"
        var e4 = CalendarEvent(uid: "inv", summary: "Lager-Inventur", start: at(2, 10), end: at(2, 12)); e4.calendarURL = "team"
        var e5 = CalendarEvent(uid: "call", summary: "Call Lieferant", start: at(2, 10, 30), end: at(2, 11, 30)); e5.calendarURL = "anna"
        var e6 = CalendarEvent(uid: "messe", summary: "Messe Nürnberg", start: cal.startOfDay(for: at(1, 0)), end: cal.startOfDay(for: at(3, 0)), isAllDay: true, timeZoneID: nil); e6.calendarURL = "team"
        let calendars = [
            CalDAVCalendar(url: "anna", name: "Anna", color: "#2B3BFF", ctag: nil, isReadOnly: false),
            CalDAVCalendar(url: "team", name: "Team Slyy", color: "#D9730D", ctag: nil, isReadOnly: false),
        ]
        let m = AppModel.offline(account: withAlias, folders: folders, messages: messages, calendars: calendars, events: [e6, e2, e3, e4, e5, weekly])
        m.totalMessages = messages.count
        m.calendarDate = now
        m.calendarMode = .week

        // The open message: Heiko's invitation with the .ics part.
        var invite = weekly
        invite.attendees = weekly.attendees.map { var a = $0; if a.email == "anna@slyy.ai" { a.status = .needsAction }; return a }
        var mail = OutgoingMessage(from: EmailAddress(name: "Heiko Meier", address: "heiko@slyy.ai"), to: [account.address, EmailAddress(name: "Jürgen Schott", address: "j.schott@schott-haustechnik.de")],
                                   subject: "Invitation: ERP Wochenfazit", text: "Hallo zusammen,\n\nwie jede Woche: 20 Minuten Status zu Angeboten, Lager und offenen Rechnungen. Agenda im Anhang.",
                                   attachments: [OutgoingAttachment(filename: "Agenda-KW48.pdf", mimeType: "application/pdf", data: Data(count: 86_000))])
        mail.calendar = CalendarAttachment(method: "REQUEST", ics: ICalendarWriter.request(invite))
        m.showForTesting(messages[0], message: ParsedMessage(data: mail.render()), conversation: [messages[0]])
        m.selectedMessageIDs = [messages[0].id]
        if conversation {
            let latest = messages.first { $0.uid == 3 }!
            let original = messages.first { $0.uid == 6 }!
            m.expandedMessages = [latest.id]
            m.expandedThreads = [MessageThreads.group(messages).first { $0.messages.contains { $0.id == latest.id } }!.id]
            m.selectedMessageIDs = [latest.id]
            let latestBody = ParsedMessage(data: OutgoingMessage(
                from: EmailAddress(name: "Jürgen Schott", address: "j.schott@schott-haustechnik.de"), to: [account.address],
                subject: "Re: Angebot Wärmepumpe", text: "Hallo Frau Weber,\n\nmorgen 10 Uhr passt. Bitte die Montage mit anbieten.\n\nGrüße\nJürgen Schott").render())
            m.showForTesting(latest, message: latestBody, conversation: [original, sentReply, latest], bodies: [
                latest.id: latestBody,
                original.id: ParsedMessage(data: OutgoingMessage(
                    from: EmailAddress(name: "Jürgen Schott", address: "j.schott@schott-haustechnik.de"), to: [account.address],
                    subject: "Angebot Wärmepumpe", text: "Guten Tag, bitte um ein Angebot für eine Wärmepumpe im Einfamilienhaus.").render()),
                sentReply.id: ParsedMessage(data: OutgoingMessage(
                    from: account.address, to: [EmailAddress(address: "j.schott@schott-haustechnik.de")],
                    subject: "Re: Angebot Wärmepumpe", text: "Hallo Herr Schott, anbei das Angebot. Passt Ihnen morgen 10 Uhr für Rückfragen?").render()),
            ])
        }
        if calendar {
            m.sidebarSelection = .calendar
            m.selectedEvent = ICalendarReader.expand([weekly], from: week, to: at(7, 0)).first
        }
        return m
    }
}
