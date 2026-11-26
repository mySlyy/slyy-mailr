import Foundation

public struct RecurrenceRule: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    /// Weekday (1 = Sunday … 7 = Saturday, like Foundation) with an optional ordinal (1MO, -1FR).
    public struct WeekdayNum: Codable, Hashable, Sendable {
        public var weekday: Int
        public var ordinal: Int?

        public init(weekday: Int, ordinal: Int? = nil) {
            self.weekday = weekday
            self.ordinal = ordinal
        }
    }

    public var frequency: Frequency
    public var interval: Int
    public var count: Int?
    public var until: Date?
    public var byDay: [WeekdayNum]
    public var byMonthDay: [Int]
    public var byMonth: [Int]

    public init(frequency: Frequency, interval: Int = 1, count: Int? = nil, until: Date? = nil, byDay: [WeekdayNum] = [], byMonthDay: [Int] = [], byMonth: [Int] = []) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.count = count
        self.until = until
        self.byDay = byDay
        self.byMonthDay = byMonthDay
        self.byMonth = byMonth
    }

    static let dayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// Parses "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20271231T235959Z". Unsupported parts are ignored.
    public init?(_ rrule: String, defaultZone: TimeZone = .current) {
        var dict: [String: String] = [:]
        for part in rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[kv[0].uppercased()] = String(kv[1]) }
        }
        guard let f = dict["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
        frequency = f
        interval = max(1, Int(dict["INTERVAL"] ?? "1") ?? 1)
        count = dict["COUNT"].flatMap { Int($0) }
        until = dict["UNTIL"].flatMap { ICalTime.parse($0, tzid: nil, defaultZone: defaultZone)?.date }
        byDay = (dict["BYDAY"] ?? "").split(separator: ",").compactMap { s in
            let code = String(s.suffix(2)).uppercased()
            guard let idx = RecurrenceRule.dayCodes.firstIndex(of: code) else { return nil }
            let ord = s.count > 2 ? Int(s.dropLast(2)) : nil
            return WeekdayNum(weekday: idx + 1, ordinal: ord)
        }
        byMonthDay = (dict["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        byMonth = (dict["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
    }

    public var rruleString: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if let count { parts.append("COUNT=\(count)") }
        if let until { parts.append("UNTIL=\(ICalTime.formatUTC(until))") }
        if !byDay.isEmpty {
            parts.append("BYDAY=" + byDay.map { ($0.ordinal.map(String.init) ?? "") + RecurrenceRule.dayCodes[$0.weekday - 1] }.joined(separator: ","))
        }
        if !byMonthDay.isEmpty { parts.append("BYMONTHDAY=" + byMonthDay.map(String.init).joined(separator: ",")) }
        if !byMonth.isEmpty { parts.append("BYMONTH=" + byMonth.map(String.init).joined(separator: ",")) }
        return parts.joined(separator: ";")
    }

    /// Occurrence start times from `start` (inclusive) that begin before `rangeEnd`.
    /// Times keep the wall-clock time of `start` in `zone` across DST changes.
    public func occurrences(start: Date, zone: TimeZone, rangeEnd: Date, exdates: Set<Date> = [], limit: Int = 5000) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.firstWeekday = 2 // WKST=MO
        let base = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: start)
        var result: [Date] = []
        var produced = 0
        var period = 0
        let maxPeriods = 50_000

        func at(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            var c = DateComponents(year: y, month: m, day: d, hour: base.hour, minute: base.minute, second: base.second)
            c.timeZone = zone
            guard let date = cal.date(from: c), cal.component(.day, from: date) == d else { return nil } // skip Feb 30 etc.
            return date
        }

        while period < maxPeriods {
            var candidates: [Date] = []
            switch frequency {
            case .daily:
                if let d = cal.date(byAdding: .day, value: period * interval, to: start) {
                    let c = cal.dateComponents([.year, .month, .day], from: d)
                    if byMonth.isEmpty || byMonth.contains(c.month!), byDay.isEmpty || byDay.contains(where: { $0.weekday == cal.component(.weekday, from: d) }) {
                        if let x = at(c.year!, c.month!, c.day!) { candidates.append(x) }
                    }
                }
            case .weekly:
                guard let weekStart = cal.dateInterval(of: .weekOfYear, for: start)?.start,
                      let thisWeek = cal.date(byAdding: .weekOfYear, value: period * interval, to: weekStart) else { break }
                let days = byDay.isEmpty ? [base.weekday!] : byDay.map(\.weekday)
                for wd in days {
                    // Offset from Monday: MO=0 … SU=6
                    let offset = (wd + 5) % 7
                    if let d = cal.date(byAdding: .day, value: offset, to: thisWeek) {
                        let c = cal.dateComponents([.year, .month, .day], from: d)
                        if let x = at(c.year!, c.month!, c.day!) { candidates.append(x) }
                    }
                }
            case .monthly:
                guard let first = cal.date(from: DateComponents(year: base.year, month: base.month, day: 1)),
                      let month = cal.date(byAdding: .month, value: period * interval, to: first) else { break }
                let c = cal.dateComponents([.year, .month], from: month)
                candidates = daysInMonth(cal: cal, year: c.year!, month: c.month!, defaultDay: base.day!).compactMap { at(c.year!, c.month!, $0) }
            case .yearly:
                let year = base.year! + period * interval
                let months = byMonth.isEmpty ? [base.month!] : byMonth
                for m in months {
                    let days: [Int]
                    if byDay.isEmpty && byMonthDay.isEmpty {
                        days = [base.day!]
                    } else {
                        days = daysInMonth(cal: cal, year: year, month: m, defaultDay: base.day!)
                    }
                    candidates += days.compactMap { at(year, m, $0) }
                }
            }
            candidates.sort()
            for c in candidates where c >= start {
                if let until, c > until { return result }
                produced += 1
                if let count, produced > count { return result }
                if c >= rangeEnd { return result }
                if !exdates.contains(c) { result.append(c) }
                if result.count >= limit { return result }
            }
            period += 1
            // Stop when the period itself is past the range (all candidates would be too).
            if let probe = candidates.first, probe >= rangeEnd { return result }
        }
        return result
    }

    /// Days of a month selected by BYDAY (with ordinals) / BYMONTHDAY, or the start day.
    func daysInMonth(cal: Calendar, year: Int, month: Int, defaultDay: Int) -> [Int] {
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let count = range.count
        var days: [Int] = []
        if !byMonthDay.isEmpty {
            days += byMonthDay.compactMap { d in
                let day = d > 0 ? d : count + d + 1
                return (1...count).contains(day) ? day : nil
            }
        }
        if !byDay.isEmpty {
            let firstWeekday = cal.component(.weekday, from: first)
            for wd in byDay {
                let all = (1...count).filter { ((firstWeekday - 1 + $0 - 1) % 7) + 1 == wd.weekday }
                if let ord = wd.ordinal, ord != 0 {
                    let idx = ord > 0 ? ord - 1 : all.count + ord
                    if all.indices.contains(idx) { days.append(all[idx]) }
                } else {
                    days += all
                }
            }
        }
        if byMonthDay.isEmpty && byDay.isEmpty { days = defaultDay <= count ? [defaultDay] : [] }
        return Array(Set(days)).sorted()
    }
}
