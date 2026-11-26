import Foundation

public enum ParticipationStatus: String, Codable, Sendable, CaseIterable {
    case needsAction = "NEEDS-ACTION"
    case accepted = "ACCEPTED"
    case declined = "DECLINED"
    case tentative = "TENTATIVE"
    case delegated = "DELEGATED"
}

public struct Attendee: Codable, Hashable, Sendable, Identifiable {
    public var email: String
    public var name: String
    public var status: ParticipationStatus
    public var role: String
    public var rsvp: Bool

    public var id: String { email.lowercased() }

    public init(email: String, name: String = "", status: ParticipationStatus = .needsAction, role: String = "REQ-PARTICIPANT", rsvp: Bool = true) {
        self.email = email
        self.name = name
        self.status = status
        self.role = role
        self.rsvp = rsvp
    }
}

/// One event (or one occurrence of a recurring event).
public struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    public var uid: String
    public var summary: String
    public var location: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// IANA zone of the event's wall-clock time; nil = UTC/floating.
    public var timeZoneID: String?
    public var recurrence: RecurrenceRule?
    public var exceptionDates: [Date]
    public var organizer: EmailAddress?
    public var attendees: [Attendee]
    public var sequence: Int
    public var status: String
    public var videoURL: URL?
    /// Set on expanded occurrences of a recurring event and on exception overrides.
    public var recurrenceID: Date?
    /// Reminder before start, in minutes (from the first VALARM), nil = none.
    public var alarmMinutes: Int?

    // Where it is stored.
    public var calendarURL: String?
    public var objectURL: String?
    public var etag: String?

    public var id: String {
        uid + (recurrenceID.map { "#\(Int($0.timeIntervalSince1970))" } ?? "")
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var isRecurring: Bool { recurrence != nil }
    public var isCancelled: Bool { status.uppercased() == "CANCELLED" }

    public init(uid: String = UUID().uuidString.lowercased(), summary: String, location: String = "", notes: String = "", start: Date, end: Date, isAllDay: Bool = false, timeZoneID: String? = TimeZone.current.identifier, recurrence: RecurrenceRule? = nil, exceptionDates: [Date] = [], organizer: EmailAddress? = nil, attendees: [Attendee] = [], sequence: Int = 0, status: String = "CONFIRMED", videoURL: URL? = nil, recurrenceID: Date? = nil, alarmMinutes: Int? = 10) {
        self.uid = uid
        self.summary = summary
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZoneID = timeZoneID
        self.recurrence = recurrence
        self.exceptionDates = exceptionDates
        self.organizer = organizer
        self.attendees = attendees
        self.sequence = sequence
        self.status = status
        self.videoURL = videoURL
        self.recurrenceID = recurrenceID
        self.alarmMinutes = alarmMinutes
    }

    public func overlaps(_ from: Date, _ to: Date) -> Bool {
        start < to && (end > from || (end == start && start >= from))
    }

    /// My participation status if I'm an attendee.
    public func status(of email: String) -> ParticipationStatus? {
        attendees.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }?.status
    }

    public func isOrganized(by email: String) -> Bool {
        organizer == nil || organizer?.address.caseInsensitiveCompare(email) == .orderedSame
    }
}

/// Reading events from iCalendar data.
public enum ICalendarReader {
    public struct Result {
        public var method: String?
        /// Master events and standalone exceptions, unexpanded.
        public var events: [CalendarEvent]
        public var root: ICalComponent?
    }

    public static func read(_ text: String, defaultZone: TimeZone = .current) -> Result {
        guard let root = ICalComponent.parse(text) else { return Result(method: nil, events: [], root: nil) }
        let method = root.first("METHOD")?.value.uppercased()
        let events = root.children("VEVENT").compactMap { event(from: $0, calendar: root, defaultZone: defaultZone) }
        return Result(method: method, events: events, root: root)
    }

    public static func event(from v: ICalComponent, calendar: ICalComponent?, defaultZone: TimeZone = .current) -> CalendarEvent? {
        guard let dtstart = v.first("DTSTART"), let start = ICalTime.parse(dtstart, calendar: calendar, defaultZone: defaultZone) else { return nil }
        var end: Date
        if let dtend = v.first("DTEND"), let e = ICalTime.parse(dtend, calendar: calendar, defaultZone: defaultZone) {
            end = e.date
        } else if let dur = v.first("DURATION")?.value, let secs = parseDuration(dur) {
            end = start.date.addingTimeInterval(secs)
        } else {
            end = start.isAllDay ? start.date.addingTimeInterval(86400) : start.date
        }
        if end < start.date { end = start.date }
        let zone = start.timeZone ?? defaultZone
        var exdates: [Date] = []
        for ex in v.all("EXDATE") {
            for part in ex.value.split(separator: ",") {
                if let d = ICalTime.parse(String(part), tzid: ex.param("TZID"), isDate: ex.param("VALUE")?.uppercased() == "DATE", calendar: calendar, defaultZone: defaultZone) {
                    exdates.append(d.date)
                }
            }
        }
        let organizer = v.first("ORGANIZER").map { p in EmailAddress(name: p.param("CN").map(EmailAddress.unquote) ?? "", address: mailto(p.value)) }
        let attendees: [Attendee] = v.all("ATTENDEE").map { p in
            Attendee(
                email: mailto(p.value),
                name: p.param("CN").map(EmailAddress.unquote) ?? "",
                status: ParticipationStatus(rawValue: (p.param("PARTSTAT") ?? "NEEDS-ACTION").uppercased()) ?? .needsAction,
                role: p.param("ROLE") ?? "REQ-PARTICIPANT",
                rsvp: p.param("RSVP")?.uppercased() == "TRUE"
            )
        }
        let description = v.first("DESCRIPTION")?.text ?? ""
        let location = v.first("LOCATION")?.text ?? ""
        let video = v.first("X-SLYY-VIDEO-URL").flatMap { URL(string: $0.value) }
            ?? v.first("X-JITSI-URL").flatMap { URL(string: $0.value) }
            ?? v.first("URL").flatMap { URL(string: $0.value) }.flatMap { JitsiRoom.findLink(in: $0.absoluteString) }
            ?? JitsiRoom.findLink(in: location + "\n" + description)
        let alarm = v.children("VALARM").first?.first("TRIGGER").flatMap { parseDuration($0.value) }.map { Int(-$0 / 60) }
        return CalendarEvent(
            uid: v.first("UID")?.value ?? UUID().uuidString,
            summary: v.first("SUMMARY")?.text ?? "",
            location: location,
            notes: JitsiRoom.stripDescriptionBlock(description),
            start: start.date,
            end: end,
            isAllDay: start.isAllDay,
            timeZoneID: start.isAllDay ? nil : start.timeZone?.identifier,
            recurrence: v.first("RRULE").flatMap { RecurrenceRule($0.value, defaultZone: zone) },
            exceptionDates: exdates,
            organizer: organizer,
            attendees: attendees,
            sequence: Int(v.first("SEQUENCE")?.value ?? "0") ?? 0,
            status: v.first("STATUS")?.value.uppercased() ?? "CONFIRMED",
            videoURL: video,
            recurrenceID: v.first("RECURRENCE-ID").flatMap { ICalTime.parse($0, calendar: calendar, defaultZone: defaultZone)?.date },
            alarmMinutes: alarm
        )
    }

    static func mailto(_ s: String) -> String {
        s.lowercased().hasPrefix("mailto:") ? String(s.dropFirst(7)) : s
    }

    /// ISO 8601 duration (P1D, PT15M, -PT10M, P1W) → seconds.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        var str = s.uppercased()
        var sign: Double = 1
        if str.hasPrefix("-") { sign = -1; str.removeFirst() }
        if str.hasPrefix("+") { str.removeFirst() }
        guard str.hasPrefix("P") else { return nil }
        str.removeFirst()
        var total: Double = 0
        var num = ""
        var inTime = false
        for ch in str {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { num.append(ch); continue }
            let n = Double(num) ?? 0
            num = ""
            switch ch {
            case "W": total += n * 7 * 86400
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : n * 30 * 86400
            case "S": total += n
            default: return nil
            }
        }
        return sign * total
    }

    /// Expands masters (with RRULE) into occurrences in [from, to), applying exceptions and EXDATEs.
    public static func expand(_ events: [CalendarEvent], from: Date, to: Date, defaultZone: TimeZone = .current) -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        let byUID = Dictionary(grouping: events, by: \.uid)
        for (_, group) in byUID {
            let masters = group.filter { $0.recurrenceID == nil }
            let exceptions = group.filter { $0.recurrenceID != nil }
            guard let master = masters.first else {
                out += exceptions.filter { $0.overlaps(from, to) && !$0.isCancelled }
                continue
            }
            guard let rule = master.recurrence else {
                if master.overlaps(from, to) { out.append(master) }
                continue
            }
            let zone = master.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? defaultZone
            let overridden = Dictionary(exceptions.compactMap { e in e.recurrenceID.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
            // Start a bit before `from` so long events that began earlier are included.
            let starts = rule.occurrences(start: master.start, zone: zone, rangeEnd: to, exdates: Set(master.exceptionDates))
            for s in starts {
                if let ex = overridden[s] {
                    if !ex.isCancelled, ex.overlaps(from, to) { out.append(ex) }
                    continue
                }
                var occ = master
                occ.start = s
                occ.end = s.addingTimeInterval(master.duration)
                occ.recurrenceID = s
                if occ.overlaps(from, to) { out.append(occ) }
            }
            // Exceptions moved into the range from outside their original slot.
            for ex in exceptions where !ex.isCancelled && ex.overlaps(from, to) && !starts.contains(ex.recurrenceID!) {
                out.append(ex)
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}

/// Writing events and iTIP messages (RFC 5546).
public enum ICalendarWriter {
    public static let prodID = "-//Slyy//Slyy Mail 0.1//EN"

    static func calendar(method: String?) -> ICalComponent {
        let cal = ICalComponent("VCALENDAR")
        cal.set("PRODID", prodID)
        cal.set("VERSION", "2.0")
        cal.set("CALSCALE", "GREGORIAN")
        if let method { cal.set("METHOD", method) }
        return cal
    }

    /// Writes `event` into a VEVENT, keeping properties we don't manage (alarms, X- props, attachments).
    public static func apply(_ e: CalendarEvent, to v: ICalComponent, now: Date = Date()) {
        let zone = e.isAllDay ? nil : e.timeZoneID.flatMap(TimeZone.init(identifier:))
        v.set("UID", e.uid)
        v.set("DTSTAMP", ICalTime.formatUTC(now))
        if v.first("CREATED") == nil { v.set("CREATED", ICalTime.formatUTC(now)) }
        v.set("LAST-MODIFIED", ICalTime.formatUTC(now))
        v.set("SEQUENCE", String(e.sequence))
        v.setText("SUMMARY", e.summary)
        v.set(ICalTime.property("DTSTART", date: e.start, allDay: e.isAllDay, zone: zone))
        v.remove("DURATION")
        v.set(ICalTime.property("DTEND", date: e.isAllDay ? max(e.end, e.start.addingTimeInterval(86400)) : e.end, allDay: e.isAllDay, zone: zone))
        v.set("STATUS", e.status)
        v.set("TRANSP", "OPAQUE")
        if let r = e.recurrence { v.set("RRULE", r.rruleString) } else { v.remove("RRULE") }
        v.remove("EXDATE")
        for ex in e.exceptionDates { v.properties.append(ICalTime.property("EXDATE", date: ex, allDay: e.isAllDay, zone: zone)) }
        if let rid = e.recurrenceID { v.set(ICalTime.property("RECURRENCE-ID", date: rid, allDay: e.isAllDay, zone: zone)) }

        var description = e.notes
        var location = e.location
        v.remove("X-SLYY-VIDEO-URL")
        v.remove("X-JITSI-URL")
        if let url = e.videoURL {
            description = JitsiRoom.descriptionBlock(url) + (e.notes.isEmpty ? "" : "\n" + e.notes)
            if location.isEmpty { location = url.absoluteString }
            v.set("URL", url.absoluteString)
            v.set("X-SLYY-VIDEO-URL", url.absoluteString)
            v.set("X-JITSI-URL", url.absoluteString)
            v.set("X-MICROSOFT-SKYPETEAMSMEETINGURL", url.absoluteString) // Outlook shows a "Join" button for this
        } else if v.first("URL").map({ JitsiRoom.findLink(in: $0.value) != nil }) == true {
            v.remove("URL")
            v.remove("X-MICROSOFT-SKYPETEAMSMEETINGURL")
        }
        v.setText("DESCRIPTION", description)
        v.setText("LOCATION", location)

        v.remove("ORGANIZER")
        v.remove("ATTENDEE")
        if !e.attendees.isEmpty, let org = e.organizer {
            var p: [String: String] = [:]
            if !org.name.isEmpty { p["CN"] = org.name }
            v.properties.append(ICalProperty("ORGANIZER", "mailto:\(org.address)", params: p))
            for a in e.attendees {
                var ap: [String: String] = ["PARTSTAT": a.status.rawValue, "ROLE": a.role, "CUTYPE": "INDIVIDUAL"]
                if a.rsvp { ap["RSVP"] = "TRUE" }
                if !a.name.isEmpty { ap["CN"] = a.name }
                v.properties.append(ICalProperty("ATTENDEE", "mailto:\(a.email)", params: ap))
            }
        }
        v.components.removeAll { $0.name == "VALARM" }
        if let minutes = e.alarmMinutes {
            let alarm = ICalComponent("VALARM")
            alarm.set("ACTION", "DISPLAY")
            alarm.setText("DESCRIPTION", e.summary.isEmpty ? "Reminder" : e.summary)
            alarm.set("TRIGGER", "-PT\(max(0, minutes))M")
            v.components.append(alarm)
        }
    }

    /// A complete calendar object for storage (no METHOD) or an iTIP message (with METHOD).
    public static func object(_ e: CalendarEvent, method: String? = nil, keeping original: ICalComponent? = nil) -> String {
        let cal: ICalComponent
        if let original {
            cal = original.copy()
            cal.set("PRODID", prodID)
            if let method { cal.set("METHOD", method) } else { cal.remove("METHOD") }
        } else {
            cal = calendar(method: method)
        }
        let master = cal.children("VEVENT").first { $0.first("RECURRENCE-ID") == nil && $0.first("UID")?.value == e.uid }
        let v = master ?? ICalComponent("VEVENT")
        if master == nil { cal.components.append(v) }
        apply(e, to: v)
        ensureTimeZones(cal)
        return cal.serialize()
    }

    /// Adds a VTIMEZONE for every TZID used, and drops unused ones.
    static func ensureTimeZones(_ cal: ICalComponent) {
        var used = Set<String>()
        for v in cal.components where v.name != "VTIMEZONE" {
            for p in v.properties { if let id = p.param("TZID") { used.insert(id) } }
        }
        let existing = Set(cal.children("VTIMEZONE").compactMap { $0.first("TZID")?.value })
        cal.components.removeAll { $0.name == "VTIMEZONE" && !used.contains($0.first("TZID")?.value ?? "") }
        for id in used.subtracting(existing).sorted() {
            if let tz = TimeZone(identifier: id) { cal.components.insert(ICalTime.vtimezone(for: tz), at: 0) }
        }
    }

    /// METHOD:REQUEST for attendees (new or updated meeting).
    public static func request(_ e: CalendarEvent) -> String {
        object(e, method: "REQUEST")
    }

    /// METHOD:CANCEL for the whole series (or one occurrence if `recurrenceID` is set).
    public static func cancel(_ e: CalendarEvent) -> String {
        var c = e
        c.status = "CANCELLED"
        c.sequence += 1
        return object(c, method: "CANCEL")
    }

    /// METHOD:REPLY from one attendee to the organizer.
    public static func reply(to invite: CalendarEvent, attendee: EmailAddress, status: ParticipationStatus, comment: String? = nil) -> String {
        let cal = calendar(method: "REPLY")
        let v = ICalComponent("VEVENT")
        let zone = invite.isAllDay ? nil : invite.timeZoneID.flatMap(TimeZone.init(identifier:))
        v.set("UID", invite.uid)
        v.set("DTSTAMP", ICalTime.formatUTC(Date()))
        v.set("SEQUENCE", String(invite.sequence))
        v.setText("SUMMARY", invite.summary)
        v.set(ICalTime.property("DTSTART", date: invite.start, allDay: invite.isAllDay, zone: zone))
        v.set(ICalTime.property("DTEND", date: invite.end, allDay: invite.isAllDay, zone: zone))
        if let rid = invite.recurrenceID { v.set(ICalTime.property("RECURRENCE-ID", date: rid, allDay: invite.isAllDay, zone: zone)) }
        if let org = invite.organizer {
            v.properties.append(ICalProperty("ORGANIZER", "mailto:\(org.address)", params: org.name.isEmpty ? [:] : ["CN": org.name]))
        }
        var p = ["PARTSTAT": status.rawValue]
        if !attendee.name.isEmpty { p["CN"] = attendee.name }
        v.properties.append(ICalProperty("ATTENDEE", "mailto:\(attendee.address)", params: p))
        if let comment, !comment.isEmpty { v.setText("COMMENT", comment) }
        cal.components.append(v)
        ensureTimeZones(cal)
        return cal.serialize()
    }
}
