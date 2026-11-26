import Foundation

/// DATE / DATE-TIME values with time zones.
public enum ICalTime {
    static let utc = TimeZone(identifier: "UTC")!

    /// Windows zone names that Outlook/Exchange put in TZID (most common in DACH/EU + a few others).
    static let windowsZones: [String: String] = [
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw",
        "Romance Standard Time": "Europe/Paris",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "E. Europe Standard Time": "Europe/Chisinau",
        "FLE Standard Time": "Europe/Kiev",
        "GTB Standard Time": "Europe/Bucharest",
        "Russian Standard Time": "Europe/Moscow",
        "Turkey Standard Time": "Europe/Istanbul",
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "Pacific Standard Time": "America/Los_Angeles",
        "China Standard Time": "Asia/Shanghai",
        "Tokyo Standard Time": "Asia/Tokyo",
        "India Standard Time": "Asia/Kolkata",
        "Arabian Standard Time": "Asia/Dubai",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "UTC": "UTC",
        "Coordinated Universal Time": "UTC",
    ]

    /// Resolves a TZID: IANA name, Windows name, Outlook-style "(UTC+01:00) Amsterdam, Berlin..." or a VTIMEZONE in the same calendar.
    public static func timeZone(_ tzid: String?, calendar: ICalComponent? = nil) -> TimeZone? {
        guard var id = tzid?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), !id.isEmpty else { return nil }
        if id.hasPrefix("/") { id = String(id.drop(while: { $0 == "/" })) } // "/mozilla.org/20050126_1/Europe/Berlin"
        if let tz = TimeZone(identifier: id) { return tz }
        if let mapped = windowsZones[id], let tz = TimeZone(identifier: mapped) { return tz }
        // Path-like ids ending in an IANA name
        let parts = id.split(separator: "/")
        if parts.count >= 2, let tz = TimeZone(identifier: parts.suffix(2).joined(separator: "/")) { return tz }
        if id.contains("Berlin") || id.contains("Amsterdam") || id.contains("Vienna") || id.contains("Wien") { return TimeZone(identifier: "Europe/Berlin") }
        // VTIMEZONE in the same object: X-LIC-LOCATION or the STANDARD offset as a last resort.
        if let vtz = calendar?.children("VTIMEZONE").first(where: { $0.first("TZID")?.value == tzid }) {
            if let loc = vtz.first("X-LIC-LOCATION")?.value, let tz = TimeZone(identifier: loc) { return tz }
            if let std = vtz.children("STANDARD").first?.first("TZOFFSETTO")?.value, let secs = offsetSeconds(std) {
                return TimeZone(secondsFromGMT: secs)
            }
        }
        return nil
    }

    static func offsetSeconds(_ s: String) -> Int? {
        // +0100, -0530, +013000
        guard s.count >= 5, let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(s.dropFirst())
        guard let h = Int(String(digits[0..<2])), let m = Int(String(digits[2..<4])) else { return nil }
        let sec = digits.count >= 6 ? Int(String(digits[4..<6])) ?? 0 : 0
        let total = h * 3600 + m * 60 + sec
        return sign == "-" ? -total : total
    }

    public struct Parsed: Equatable {
        public var date: Date
        public var isAllDay: Bool
        /// nil for UTC or floating times.
        public var timeZone: TimeZone?
    }

    /// Parses a DTSTART/DTEND/RECURRENCE-ID/EXDATE value.
    public static func parse(_ prop: ICalProperty, calendar: ICalComponent? = nil, defaultZone: TimeZone = .current) -> Parsed? {
        parse(prop.value, tzid: prop.param("TZID"), isDate: prop.param("VALUE")?.uppercased() == "DATE", calendar: calendar, defaultZone: defaultZone)
    }

    public static func parse(_ raw: String, tzid: String?, isDate: Bool = false, calendar: ICalComponent? = nil, defaultZone: TimeZone = .current) -> Parsed? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if isDate || v.count == 8 {
            guard let comps = dateComponents(v) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = defaultZone
            return cal.date(from: comps).map { Parsed(date: $0, isAllDay: true, timeZone: nil) }
        }
        guard v.count >= 15, var comps = dateComponents(String(v.prefix(8))) else { return nil }
        let t = Array(v)
        guard let hh = Int(String(t[9..<11])), let mm = Int(String(t[11..<13])), let ss = Int(String(t[13..<15])) else { return nil }
        comps.hour = hh
        comps.minute = mm
        comps.second = ss
        var cal = Calendar(identifier: .gregorian)
        let zone: TimeZone
        var keep: TimeZone?
        if v.hasSuffix("Z") {
            zone = utc
        } else if let tz = timeZone(tzid, calendar: calendar) {
            zone = tz
            keep = tz
        } else {
            zone = defaultZone // floating
        }
        cal.timeZone = zone
        return cal.date(from: comps).map { Parsed(date: $0, isAllDay: false, timeZone: keep) }
    }

    static func dateComponents(_ s: String) -> DateComponents? {
        guard s.count >= 8, let y = Int(s.prefix(4)), let m = Int(s.dropFirst(4).prefix(2)), let d = Int(s.dropFirst(6).prefix(2)) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    // MARK: Formatting

    public static func formatUTC(_ date: Date) -> String {
        format(date, zone: utc) + "Z"
    }

    public static func format(_ date: Date, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    public static func formatDate(_ date: Date, zone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }

    /// A DTSTART/DTEND-style property for a date in the given zone (UTC if nil).
    public static func property(_ name: String, date: Date, allDay: Bool, zone: TimeZone?) -> ICalProperty {
        if allDay { return ICalProperty(name, formatDate(date), params: ["VALUE": "DATE"]) }
        if let zone, zone.identifier != "UTC", zone.identifier != "GMT" {
            return ICalProperty(name, format(date, zone: zone), params: ["TZID": zone.identifier])
        }
        return ICalProperty(name, formatUTC(date))
    }

    // MARK: VTIMEZONE

    /// Builds a VTIMEZONE from Foundation's tz data (yearly rules derived from the given reference year).
    public static func vtimezone(for zone: TimeZone, referenceYear: Int? = nil) -> ICalComponent {
        let tz = ICalComponent("VTIMEZONE")
        tz.set("TZID", zone.identifier)
        tz.set("X-LIC-LOCATION", zone.identifier)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let year = referenceYear ?? cal.component(.year, from: Date())
        let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        guard let t1 = zone.nextDaylightSavingTimeTransition(after: jan1),
              let t2 = zone.nextDaylightSavingTimeTransition(after: t1),
              cal.component(.year, from: t2) == year else {
            let std = ICalComponent("STANDARD")
            let off = offsetString(zone.secondsFromGMT(for: jan1))
            std.set("DTSTART", "19700101T000000")
            std.set("TZOFFSETFROM", off)
            std.set("TZOFFSETTO", off)
            std.set("TZNAME", zone.abbreviation(for: jan1) ?? zone.identifier)
            tz.components.append(std)
            return tz
        }
        for t in [t1, t2] {
            let before = zone.secondsFromGMT(for: t.addingTimeInterval(-1))
            let after = zone.secondsFromGMT(for: t)
            let isDaylight = zone.isDaylightSavingTime(for: t)
            let comp = ICalComponent(isDaylight ? "DAYLIGHT" : "STANDARD")
            // Local wall time at which the transition happens (in the old offset).
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone(secondsFromGMT: before)!
            let c = local.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: t)
            let daysInMonth = local.range(of: .day, in: .month, for: t)?.count ?? 31
            let ordinal = c.day! > daysInMonth - 7 ? -1 : (c.day! - 1) / 7 + 1
            // DTSTART must be the first instance of the RRULE (in 1970).
            let rule = RecurrenceRule(frequency: .yearly, byDay: [.init(weekday: c.weekday!, ordinal: ordinal)], byMonth: [c.month!])
            let day1970 = rule.daysInMonth(cal: cal, year: 1970, month: c.month!, defaultDay: c.day!).first ?? c.day!
            comp.set("DTSTART", String(format: "1970%02d%02dT%02d%02d%02d", c.month!, day1970, c.hour!, c.minute!, c.second!))
            let wd = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][c.weekday! - 1]
            comp.set("RRULE", "FREQ=YEARLY;BYMONTH=\(c.month!);BYDAY=\(ordinal)\(wd)")
            comp.set("TZOFFSETFROM", offsetString(before))
            comp.set("TZOFFSETTO", offsetString(after))
            comp.set("TZNAME", zone.abbreviation(for: t) ?? (isDaylight ? "DST" : "STD"))
            tz.components.append(comp)
        }
        return tz
    }

    static func offsetString(_ secs: Int) -> String {
        let sign = secs < 0 ? "-" : "+"
        let a = abs(secs)
        return String(format: "%@%02d%02d", sign, a / 3600, (a % 3600) / 60)
    }
}
