import Foundation

/// An incoming iTIP mail that was not applied because its sender may not make that change.
public enum ITIPError: Error, LocalizedError, Equatable {
    case cancelNotFromOrganizer
    case replyNotFromAttendee

    public var errorDescription: String? {
        switch self {
        case .cancelNotFromOrganizer: return "This cancellation didn't come from the organizer, so the calendar wasn't changed."
        case .replyNotFromAttendee: return "This reply didn't come from the attendee it answers for, so the calendar wasn't changed."
        }
    }
}

/// Calendar operations: CalDAV storage plus iTIP mails to attendees (invites, updates, cancellations, replies).
public actor CalendarService {
    public let account: AccountSettings
    private let caldav: CalDAVClient?
    private let mail: MailService
    private var calendarsCache: [CalDAVCalendar] = []

    public init(account: AccountSettings, password: String, mail: MailService) {
        self.account = account
        self.mail = mail
        if let url = URL(string: account.caldavURL), !account.caldavURL.isEmpty {
            caldav = CalDAVClient(baseURL: url, username: account.username, password: password)
        } else {
            caldav = nil
        }
    }

    public var isAvailable: Bool { caldav != nil }

    /// Calendars that hold events; creates "Calendar" if the account has none yet.
    public func calendars() async throws -> [CalDAVCalendar] {
        guard let caldav else { return [] }
        var list = try await caldav.calendars()
        if list.isEmpty {
            list = [try await caldav.makeCalendar(name: "Calendar")]
        }
        calendarsCache = list
        return list
    }

    public func defaultCalendar() async throws -> CalDAVCalendar? {
        if calendarsCache.isEmpty { _ = try await calendars() }
        return calendarsCache.first { !$0.isReadOnly } ?? calendarsCache.first
    }

    /// Expanded occurrences in [from, to) across the given calendars (all if nil).
    public func events(from: Date, to: Date, in selected: [CalDAVCalendar]? = nil) async throws -> [CalendarEvent] {
        guard let caldav else { return [] }
        var cals = selected ?? calendarsCache
        if cals.isEmpty { cals = try await calendars() }
        var all: [CalendarEvent] = []
        try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for cal in cals {
                group.addTask {
                    let objects = try await caldav.objects(in: cal, from: from, to: to)
                    return objects.flatMap { obj in
                        ICalendarReader.expand(obj.events, from: from, to: to).map { e in
                            var e = e
                            e.calendarURL = cal.url
                            e.objectURL = obj.url
                            e.etag = obj.etag
                            return e
                        }
                    }
                }
            }
            for try await chunk in group { all += chunk }
        }
        return all.sorted { $0.start < $1.start }
    }

    /// Creates or updates an event. Sends REQUEST mails to attendees when I'm the organizer and `notify` is true.
    @discardableResult
    public func save(_ input: CalendarEvent, notify: Bool = true) async throws -> CalendarEvent {
        guard let caldav else { throw CalDAVError.discoveryFailed("no calendar server configured") }
        var e = input
        if !e.attendees.isEmpty && e.organizer == nil { e.organizer = account.address }
        // The organizer is listed as an accepted attendee (as Outlook and Apple do).
        if let org = e.organizer, !e.attendees.isEmpty, !e.attendees.contains(where: { $0.email.caseInsensitiveCompare(org.address) == .orderedSame }) {
            e.attendees.insert(Attendee(email: org.address, name: org.name, status: .accepted, role: "CHAIR", rsvp: false), at: 0)
        }
        var previous: CalendarEvent?
        var original: ICalComponent?
        if let url = e.objectURL {
            let obj = try await caldav.object(at: url)
            original = ICalComponent.parse(obj.ics)
            previous = obj.events.first { $0.recurrenceID == nil }
            e.etag = obj.etag ?? e.etag
            e.sequence = max(e.sequence, (previous?.sequence ?? 0) + 1)
            // A recurring occurrence opened from the expanded list edits the whole series (keep the series start date).
            if let prev = previous, prev.isRecurring, e.recurrenceID != nil {
                let shift = e.start.timeIntervalSince(e.recurrenceID!)
                e.start = prev.start.addingTimeInterval(shift)
                e.end = e.start.addingTimeInterval(input.duration)
                e.recurrenceID = nil
            }
            // Time changed → attendees must answer again.
            if let prev = previous, prev.start != e.start || prev.end != e.end {
                for i in e.attendees.indices where e.attendees[i].email.caseInsensitiveCompare(account.email) != .orderedSame {
                    e.attendees[i].status = .needsAction
                }
            }
        }
        var calURL = e.calendarURL
        if calURL == nil { calURL = try await defaultCalendar()?.url }
        guard let calURL else { throw CalDAVError.discoveryFailed("no writable calendar") }
        e.calendarURL = calURL
        let ics = ICalendarWriter.object(e, keeping: original)
        let stored = try await caldav.put(ics: ics, uid: e.uid, calendarURL: calURL, objectURL: e.objectURL, etag: e.etag)
        e.objectURL = stored.url
        e.etag = stored.etag

        if notify, e.isOrganized(by: account.email) {
            let others = e.attendees.filter { $0.email.caseInsensitiveCompare(account.email) != .orderedSame }
            let removed = (previous?.attendees ?? []).filter { old in !e.attendees.contains { $0.email.caseInsensitiveCompare(old.email) == .orderedSame } }
            if !others.isEmpty {
                let subject = (previous == nil ? "Invitation: " : "Updated invitation: ") + e.summary
                try await mail.sendCalendarMail(to: others.map { EmailAddress(name: $0.name, address: $0.email) }, subject: subject, text: CalendarService.inviteText(e), method: "REQUEST", ics: ICalendarWriter.request(e))
            }
            if !removed.isEmpty, var cancelled = previous {
                cancelled.attendees = removed
                try await mail.sendCalendarMail(to: removed.map { EmailAddress(name: $0.name, address: $0.email) }, subject: "Cancelled: " + e.summary, text: CalendarService.inviteText(e), method: "CANCEL", ics: ICalendarWriter.cancel(cancelled))
            }
        }
        return e
    }

    /// Deletes an event (whole series) and sends CANCEL to attendees if I'm the organizer.
    public func delete(_ e: CalendarEvent, notify: Bool = true) async throws {
        guard let caldav, let url = e.objectURL else { return }
        let obj = try? await caldav.object(at: url)
        let master = obj?.events.first { $0.recurrenceID == nil } ?? e
        try await caldav.delete(objectURL: url, etag: obj?.etag ?? e.etag)
        let others = master.attendees.filter { $0.email.caseInsensitiveCompare(account.email) != .orderedSame }
        if notify, master.isOrganized(by: account.email), !others.isEmpty {
            try await mail.sendCalendarMail(to: others.map { EmailAddress(name: $0.name, address: $0.email) }, subject: "Cancelled: " + master.summary, text: CalendarService.inviteText(master), method: "CANCEL", ics: ICalendarWriter.cancel(master))
        } else if notify, let org = master.organizer, !master.isOrganized(by: account.email) {
            // Deleting someone else's meeting = declining it.
            try? await mail.sendCalendarMail(to: [org], subject: "Declined: " + master.summary, text: "", method: "REPLY", ics: ICalendarWriter.reply(to: master, attendee: account.address, status: .declined))
        }
    }

    /// Answers an invite from a mail: REPLY to the organizer and update my calendar.
    public func respond(to invite: CalendarEvent, status: ParticipationStatus, comment: String? = nil) async throws {
        guard let organizer = invite.organizer else { return }
        // Answer as the address that was invited (an alias, if that's where the invite went).
        let me = invite.attendees.first { account.isMine($0.email) }.map { a in
            account.identities.first { $0.email.caseInsensitiveCompare(a.email) == .orderedSame }?.address ?? EmailAddress(name: a.name, address: a.email)
        } ?? account.address
        let ics = ICalendarWriter.reply(to: invite, attendee: me, status: status, comment: comment)
        let verb = status == .accepted ? "Accepted" : status == .declined ? "Declined" : "Tentative"
        try await mail.sendCalendarMail(to: [organizer], subject: "\(verb): \(invite.summary)", text: comment ?? "", method: "REPLY", ics: ics, from: me)
        guard let caldav else { return }
        let existing = try await findObject(uid: invite.uid)
        if status == .declined {
            guard let existing else { return }
            // Declining one occurrence removes only that one, not the series.
            if let rid = invite.recurrenceID, let root = ICalComponent.parse(existing.ics), let rest = ICalendarWriter.cancelOccurrence(rid, uid: invite.uid, in: root) {
                _ = try await caldav.put(ics: rest, uid: invite.uid, calendarURL: "", objectURL: existing.url, etag: existing.etag)
            } else {
                try await caldav.delete(objectURL: existing.url, etag: existing.etag)
            }
            return
        }
        var mine = invite
        if let idx = mine.attendees.firstIndex(where: { account.isMine($0.email) }) {
            mine.attendees[idx].status = status
        } else {
            mine.attendees.append(Attendee(email: me.address, name: me.name, status: status))
        }
        // Existing object: update in place. New: store in my default calendar.
        var calendarURL = ""
        if existing == nil {
            guard let def = try await defaultCalendar() else { return }
            calendarURL = def.url
        }
        _ = try await caldav.put(ics: ICalendarWriter.object(mine, keeping: existing.flatMap { ICalComponent.parse($0.ics) }), uid: mine.uid, calendarURL: calendarURL, objectURL: existing?.url, etag: existing?.etag)
    }

    /// Applies an incoming CANCEL (removes the event) or REPLY (updates the attendee's status) from a mail.
    /// `sender` is the mail's From address: a CANCEL is applied only if it is the stored event's organizer,
    /// a REPLY only if it is the replying attendee (who must be on the stored event). Otherwise throws `ITIPError`.
    public func apply(itip ics: String, from sender: String) async throws {
        guard let caldav else { return }
        let r = ICalendarReader.read(ics)
        guard let e = r.events.first, let method = r.method else { return }
        guard let obj = try await findObject(uid: e.uid) else { return }
        try Self.checkSender(sender, method: method, itip: e, stored: obj.events)
        switch method {
        case "CANCEL":
            // One occurrence (RECURRENCE-ID): exclude just that one from the series; otherwise the whole event goes.
            if let rid = e.recurrenceID, let root = ICalComponent.parse(obj.ics) {
                if let rest = ICalendarWriter.cancelOccurrence(rid, uid: e.uid, in: root) {
                    _ = try await caldav.put(ics: rest, uid: e.uid, calendarURL: "", objectURL: obj.url, etag: obj.etag)
                } else {
                    try await caldav.delete(objectURL: obj.url, etag: obj.etag)
                }
            } else {
                try await caldav.delete(objectURL: obj.url, etag: obj.etag)
            }
        case "REPLY":
            guard let reply = e.attendees.first else { return }
            // A reply for one occurrence updates that occurrence (its override, made from the master if needed), not the series.
            guard var target = obj.events.first(where: { $0.recurrenceID == e.recurrenceID }) ?? CalendarService.override(of: obj.events, at: e.recurrenceID) else { return }
            if let i = target.attendees.firstIndex(where: { $0.email.caseInsensitiveCompare(reply.email) == .orderedSame }) {
                target.attendees[i].status = reply.status
                _ = try await caldav.put(ics: ICalendarWriter.object(target, keeping: ICalComponent.parse(obj.ics)), uid: target.uid, calendarURL: "", objectURL: obj.url, etag: obj.etag)
            }
        default:
            break
        }
    }

    /// A new override for occurrence `rid` of the recurring master in `events` (nil without a recurring master or `rid`).
    static func override(of events: [CalendarEvent], at rid: Date?) -> CalendarEvent? {
        guard let rid, var o = events.first(where: { $0.recurrenceID == nil }), o.isRecurring else { return nil }
        o.recurrenceID = rid
        o.start = rid
        o.end = rid.addingTimeInterval(o.duration)
        o.recurrence = nil
        o.exceptionDates = []
        return o
    }

    /// Throws unless the mail's sender may send this iTIP message for the stored event.
    static func checkSender(_ sender: String, method: String, itip e: CalendarEvent, stored: [CalendarEvent]) throws {
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b, !a.isEmpty else { return false }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        let master = stored.first { $0.recurrenceID == nil } ?? stored.first
        switch method {
        case "CANCEL":
            let organizer = master?.organizer?.address
            guard same(organizer, sender), e.organizer == nil || same(e.organizer?.address, organizer) else {
                throw ITIPError.cancelNotFromOrganizer
            }
        case "REPLY":
            guard let reply = e.attendees.first, same(reply.email, sender),
                  master?.attendees.contains(where: { same($0.email, reply.email) }) == true else {
                throw ITIPError.replyNotFromAttendee
            }
        default:
            break
        }
    }

    /// Finds the stored object for a UID by searching all calendars (±2 years).
    public func findObject(uid: String) async throws -> CalendarObject? {
        guard let caldav else { return nil }
        let now = Date()
        for cal in (calendarsCache.isEmpty ? try await calendars() : calendarsCache) {
            let objs = try await caldav.objects(in: cal, from: now.addingTimeInterval(-730 * 86400), to: now.addingTimeInterval(730 * 86400))
            if let hit = objs.first(where: { $0.events.contains { $0.uid == uid } }) { return hit }
        }
        return nil
    }

    static func inviteText(_ e: CalendarEvent) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = e.isAllDay ? .none : .short
        if let tz = e.timeZoneID.flatMap(TimeZone.init(identifier:)) { f.timeZone = tz }
        var lines = [e.summary, f.string(from: e.start) + (e.isAllDay ? "" : " – " + DateFormatter.localizedString(from: e.end, dateStyle: .none, timeStyle: .short))]
        if let v = e.videoURL { lines.append("\nJoin video call / Videokonferenz beitreten:\n\(v.absoluteString)") }
        if !e.location.isEmpty && e.location != e.videoURL?.absoluteString { lines.append("Location: \(e.location)") }
        if !e.notes.isEmpty { lines.append("\n" + e.notes) }
        return lines.joined(separator: "\n")
    }
}
