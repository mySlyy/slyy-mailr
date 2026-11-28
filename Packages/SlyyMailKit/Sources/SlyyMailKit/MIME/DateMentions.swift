import Foundation

/// A date a mail talks about ("I'll be back on Monday December 7th", "bis spätestens 4.12.").
public struct DateMention: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// The sender is away and back on `date` (out-of-office replies).
        case returning
        /// Something is due on `date` ("by", "until", "bis zum", "spätestens", "Frist").
        case deadline
        /// Any other date.
        case other
    }

    /// The day (start of day in the calendar used). For `.returning` it is the day the sender is back.
    public var date: Date
    /// The matched text, e.g. "Monday December 7th".
    public var phrase: String
    public var kind: Kind
    /// When to be reminded: that day at 09:00.
    public var suggestedReminder: Date

    public init(date: Date, phrase: String, kind: Kind, suggestedReminder: Date) {
        self.date = date
        self.phrase = phrase
        self.kind = kind
        self.suggestedReminder = suggestedReminder
    }
}

/// Lean, deterministic, on-device detection of dates in a mail's text (English and German).
/// No network, no AI and no NSDataDetector (not on Linux): a few regular expressions over the first
/// few thousand characters of the new text (quoted older mails are skipped), so it is cheap enough to run
/// whenever a message is shown.
///
/// A Slyy Haven based check (Ask Haven) could later enrich or replace this, e.g. for free-form phrasing
/// ("after the holidays", "end of next month"); until Haven is available, this stays local.
public enum DateMentions {
    /// At most this many characters of the (unquoted) text are scanned.
    public static let maxCharacters = 4000
    /// Hour of day for suggested reminders.
    public static let reminderHour = 9

    /// Dates mentioned in `text`, returning (out-of-office) first, then soonest first.
    /// Years are inferred from `sentAt` (the next occurrence on or after the mail's day); only dates from
    /// yesterday to one year after `now` are returned.
    public static func find(in text: String, sentAt: Date, now: Date = Date(), calendar: Calendar = .current) -> [DateMention] {
        let body = relevantText(text)
        guard !body.isEmpty else { return [] }
        var scan = Scan(text: body, sentAt: sentAt, calendar: calendar)
        scan.run()

        let lower = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let upper = calendar.date(byAdding: .year, value: 1, to: now) ?? now
        var best: [Date: DateMention] = [:]
        var order: [Date] = []
        for m in scan.found where m.date >= lower && m.date <= upper {
            if let existing = best[m.date] {
                if rank(m.kind) < rank(existing.kind) { best[m.date] = m }
            } else {
                best[m.date] = m
                order.append(m.date)
            }
        }
        return order.compactMap { best[$0] }.sorted { a, b in
            if rank(a.kind) != rank(b.kind), a.kind == .returning || b.kind == .returning { return a.kind == .returning }
            return a.date < b.date
        }
    }

    static func rank(_ k: DateMention.Kind) -> Int {
        switch k {
        case .returning: return 0
        case .deadline: return 1
        case .other: return 2
        }
    }

    /// The text written in this mail: lines quoted with ">" are skipped, and everything from an
    /// "On … wrote:" / "Am … schrieb …:" / "-----Original Message-----" / "From: … Sent: …" header on is dropped.
    public static func relevantText(_ text: String, limit: Int = maxCharacters) -> String {
        let lines = text.prefix(limit * 4).split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        var count = 0
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(">") { continue }
            let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if isQuoteHeader(line, next: next) { break }
            out.append(raw)
            count += raw.count + 1
            if count >= limit { break }
        }
        return String(out.joined(separator: "\n").prefix(limit))
    }

    static func isQuoteHeader(_ line: String, next: String) -> Bool {
        let l = line.lowercased()
        let n = next.lowercased()
        if l.hasPrefix("-----original message") || l.hasPrefix("----- original message")
            || l.hasPrefix("-----ursprüngliche nachricht") || l.hasPrefix("----- ursprüngliche nachricht") { return true }
        if l.hasPrefix("on "), l.hasSuffix("wrote:") || (n.hasSuffix("wrote:") && !n.hasPrefix("on ")) { return true }
        if l.hasPrefix("am "), (l.hasSuffix(":") && l.contains("schrieb")) || (n.hasSuffix(":") && n.contains("schrieb")) { return true }
        if l.hasPrefix("from:") || l.hasPrefix("von:") {
            for p in ["sent:", "gesendet:", "date:", "datum:", "to:", "an:"] where n.hasPrefix(p) { return true }
        }
        return false
    }

    // MARK: Words

    static let months: [String: Int] = [
        "january": 1, "jan": 1, "januar": 1, "jänner": 1,
        "february": 2, "feb": 2, "februar": 2,
        "march": 3, "mar": 3, "märz": 3, "maerz": 3, "mär": 3,
        "april": 4, "apr": 4,
        "may": 5, "mai": 5,
        "june": 6, "jun": 6, "juni": 6,
        "july": 7, "jul": 7, "juli": 7,
        "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10, "oktober": 10, "okt": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12, "dezember": 12, "dez": 12,
    ]

    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday).
    static let fullWeekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7,
    ]
    static let shortWeekdays: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
        // German two-letter forms only count with a dot ("Mo., 7.12.").
        "so": 1, "mo": 2, "di": 3, "mi": 4, "do": 5, "fr": 6, "sa": 7,
    ]

    static func alternation(_ words: some Sequence<String>) -> String {
        words.sorted { $0.count > $1.count }.joined(separator: "|")
    }

    static let monthAlt = alternation(months.keys)
    static let fullWeekdayAlt = alternation(fullWeekdays.keys)
    /// Optional weekday before a date: "Monday ", "Mon. ", "Montag, ", "Mo., ".
    static let weekdayPrefix = "(?:(?:\(fullWeekdayAlt)|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat)\\.?,?\\s+|(?:mo|di|mi|do|fr|sa|so)\\.,?\\s*)?"

    static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        // The patterns are constants: a typo is a programming error caught by the tests.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// "Monday December 7th", "Dec 7", "December 7, 2026"
    static let monthFirst = regex("(?<![\\p{L}\\d])\(weekdayPrefix)(?:the\\s+)?(\(monthAlt))(?!\\p{L})\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?![\\p{L}\\d]|[:.]\\d)(?:,?\\s+(\\d{4})(?!\\d))?")
    /// "7 December 2026", "7. Dezember", "Montag, 7. Dezember", "7th of December"
    static let dayFirst = regex("(?<![\\p{L}\\d.,])\(weekdayPrefix)(\\d{1,2})(?:\\.|st|nd|rd|th)?\\s+(?:of\\s+)?(\(monthAlt))(?!\\p{L})\\.?(?:,?\\s+(\\d{4})(?!\\d))?")
    /// "7.12.", "07.12.2026", "Mo., 7.12." (both dots required: "7.12" alone is a number; "0.7.1" is a version)
    static let numeric = regex("(?<![\\p{L}\\d.,+/-])\(weekdayPrefix)(\\d{1,2})\\.(\\d{1,2})\\.(\\d{4}|\\d{2})?(?!\\d|\\.\\d)")
    /// "2026-12-07"
    static let iso = regex("(?<![\\d-])(\\d{4})-(\\d{1,2})-(\\d{1,2})(?![\\d-])")
    /// "on Monday", "next Friday", "bis Freitag" (group 1: the weekday)
    static let bareWeekday = regex("(?<!\\p{L})(?:on|next|this|until|till|by|from|am|ab|bis|nächsten|kommenden|diesen)\\s+(?:the\\s+)?(\(fullWeekdayAlt))(?!\\p{L})")
    static let tomorrow = regex("(?<!\\p{L})tomorrow(?!\\p{L})")
    /// "morgen" is "tomorrow"; "Morgen" is usually "morning" ("Guten Morgen"), except at the start of a sentence.
    static let morgen = regex("(?<!\\p{L})morgen(?!\\p{L})|(?:^|(?<=[.!?]\\s))Morgen(?!\\p{L})", caseInsensitive: false)
    static let nextWeek = regex("(?<!\\p{L})(?:next week|nächste[rn]? woche|kommende[rn]? woche)(?!\\p{L})")

    // MARK: Context

    /// A sentence ends after a word, after a number when a capitalised word other than a month follows
    /// ("on 2026-12-15. By the way", but not "7. Dezember"), or at a blank line.
    static let sentenceEnd = regex("(?<=[\\p{L})])[.!?](?=\\s)|(?<=\\d)[.!?](?=\\s+\\p{Lu})(?!\\s+(?i:\(monthAlt))(?!\\p{L}))|\\n[ \\t]*\\n", caseInsensitive: false)
    /// Out of office / back on.
    static let returningCue = regex("(?<!\\p{L})(?:i(?:'ll| will)? be back|(?<!get |getting |come |write |call )back(?! to you)|returning|i(?:'ll| will)? return|my return|return to (?:the )?office|return on|out of (?:the )?office|ooo|pto|vacation|holidays?|on leave|annual leave|parental leave|sick leave|maternity leave|(?<!right )away|zurück|wieder (?:im büro|da|erreichbar|zurück|verfügbar|im haus)|urlaub|abwesend|nicht im büro|außer haus|ab dem|bis einschließlich)(?!\\p{L})")
    /// Cues that make a date a deadline even next to words like "zurück" ("bis spätestens 15.12. zurück").
    static let strongDeadlineCue = regex("(?<!\\p{L})(?:due|deadline|no later than|spätestens|frist|fällig)(?!\\p{L})")
    static let deadlineCue = regex("(?<!\\p{L})(?:by|until|till|due|deadline|no later than|before|latest|bis zum|bis spätestens|spätestens|frist|fällig|bis)(?!\\p{L})")
    /// "until X": back the day after X.
    static let untilCue = regex("(?<!\\p{L})(?:until|till|til|through|thru|bis|einschließlich|inklusive|inkl)(?!\\p{L})")
    /// "from X" in an absence note is when the absence starts, not the return.
    static let fromCue = regex("(?<!\\p{L})(?:from|vom|starting|beginning|since|seit)(?!\\p{L})")

    // MARK: Scan

    struct Scan {
        let text: String
        let ns: NSString
        let sentAt: Date
        let cal: Calendar
        let sentDay: Date
        var claimed: [NSRange] = []
        var found: [DateMention] = []

        init(text: String, sentAt: Date, calendar: Calendar) {
            self.text = text
            self.ns = text as NSString
            self.sentAt = sentAt
            self.cal = calendar
            self.sentDay = calendar.startOfDay(for: sentAt)
        }

        mutating func run() {
            let all = NSRange(location: 0, length: ns.length)
            for (re, order) in [(DateMentions.monthFirst, 0), (DateMentions.dayFirst, 1), (DateMentions.numeric, 2)] {
                for m in re.matches(in: text, range: all) {
                    let g = order == 0 ? (month: 1, day: 2, year: 3) : (month: 2, day: 1, year: 3)
                    guard let day = int(m, g.day), let month = order == 2 ? int(m, g.month) : monthNumber(m, g.month) else { continue }
                    if order != 2, isCommonWord(m.range(at: g.month)) { continue }
                    let date = infer(year: int(m, g.year), month: month, day: day, weekday: weekday(at: m.range))
                    add(date, m.range)
                }
            }
            for m in DateMentions.iso.matches(in: text, range: all) {
                guard let y = int(m, 1), let mo = int(m, 2), let d = int(m, 3) else { continue }
                add(make(y, mo, d), m.range)
            }
            for m in DateMentions.bareWeekday.matches(in: text, range: all) {
                let r = m.range(at: 1)
                guard let wd = DateMentions.fullWeekdays[ns.substring(with: r).lowercased()] else { continue }
                add(nextWeekday(wd), r)
            }
            for re in [DateMentions.tomorrow, DateMentions.morgen] {
                for m in re.matches(in: text, range: all) { add(cal.date(byAdding: .day, value: 1, to: sentDay), m.range) }
            }
            for m in DateMentions.nextWeek.matches(in: text, range: all) { add(nextWeekday(2), m.range) }
        }

        func int(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }

        /// "may" and "mar" are words too ("you may 5 times"): as months they are written with a capital.
        func isCommonWord(_ r: NSRange) -> Bool {
            let word = ns.substring(with: r)
            guard ["may", "mar"].contains(word.lowercased()) else { return false }
            return word.first?.isLowercase ?? true
        }

        func monthNumber(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { return nil }
            return DateMentions.months[ns.substring(with: r).lowercased()]
        }

        /// The weekday a match starts with, if any ("Monday December 7th" → Monday).
        func weekday(at range: NSRange) -> Int? {
            let word = ns.substring(with: range).prefix { $0.isLetter }.lowercased()
            return DateMentions.fullWeekdays[word] ?? DateMentions.shortWeekdays[word]
        }

        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            let year = y < 100 ? 2000 + y : y
            guard let date = cal.date(from: DateComponents(year: year, month: m, day: d)) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: date)
            guard c.year == year, c.month == m, c.day == d else { return nil } // 31 November
            return cal.startOfDay(for: date)
        }

        /// A date without a year: its next occurrence on or after the mail's day; a given weekday that
        /// only fits the following year moves it there.
        func infer(year: Int?, month: Int, day: Int, weekday: Int?) -> Date? {
            if let year { return make(year, month, day) }
            let y0 = cal.component(.year, from: sentAt)
            guard var d = make(y0, month, day) ?? make(y0 + 1, month, day) else { return nil }
            if d < sentDay, let next = make(cal.component(.year, from: d) + 1, month, day) { d = next }
            if let weekday, cal.component(.weekday, from: d) != weekday,
               let next = make(cal.component(.year, from: d) + 1, month, day), cal.component(.weekday, from: next) == weekday {
                d = next
            }
            return d
        }

        /// The next such weekday strictly after the mail's day.
        func nextWeekday(_ wd: Int) -> Date? {
            let today = cal.component(.weekday, from: sentDay)
            var delta = (wd - today + 7) % 7
            if delta == 0 { delta = 7 }
            return cal.date(byAdding: .day, value: delta, to: sentDay)
        }

        mutating func add(_ date: Date?, _ range: NSRange) {
            guard let date, !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
            claimed.append(range)
            let phrase = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            var kind = DateMention.Kind.other
            var day = date
            let (before, after) = context(range)
            let near = String(before.suffix(22))
            if has(DateMentions.strongDeadlineCue, String(before.suffix(26))) {
                kind = .deadline
            } else if has(DateMentions.returningCue, before + " " + after) {
                if has(DateMentions.fromCue, String(before.suffix(14))) {
                    kind = .other // the absence starts then
                } else {
                    kind = .returning
                    if has(DateMentions.untilCue, near) {
                        // "until Friday 4 Dec": back the next working day.
                        day = cal.date(byAdding: .day, value: 1, to: day) ?? day
                        while cal.isDateInWeekend(day) { day = cal.date(byAdding: .day, value: 1, to: day) ?? day }
                    }
                }
            } else if has(DateMentions.deadlineCue, String(before.suffix(26))) {
                kind = .deadline
            }
            let reminder = cal.date(bySettingHour: DateMentions.reminderHour, minute: 0, second: 0, of: day) ?? day
            found.append(DateMention(date: day, phrase: phrase, kind: kind, suggestedReminder: reminder))
        }

        /// Up to ~45 characters before and 40 after the match, within the same sentence.
        func context(_ range: NSRange) -> (before: String, after: String) {
            // Sentence ends are searched in the whole text (transparent bounds), so "15. By" sees its digit.
            var start = max(0, range.location - 45)
            let beforeRange = NSRange(location: start, length: range.location - start)
            if let last = DateMentions.sentenceEnd.matches(in: text, options: [.withTransparentBounds], range: beforeRange).last {
                start = last.range.location + last.range.length
            }
            let end = range.location + range.length
            var stop = min(ns.length, end + 40)
            let afterRange = NSRange(location: end, length: stop - end)
            if let first = DateMentions.sentenceEnd.firstMatch(in: text, options: [.withTransparentBounds], range: afterRange) {
                stop = first.range.location
            }
            let before = ns.substring(with: NSRange(location: start, length: max(0, range.location - start)))
            let after = ns.substring(with: NSRange(location: end, length: max(0, stop - end)))
            return (before.replacingOccurrences(of: "\n", with: " "), after.replacingOccurrences(of: "\n", with: " "))
        }

        func has(_ re: NSRegularExpression, _ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
    }
}
