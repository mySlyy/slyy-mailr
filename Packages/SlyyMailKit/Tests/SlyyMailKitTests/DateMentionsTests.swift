import XCTest
@testable import SlyyMailKit

final class DateMentionsTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Friday 27 November 2026, 10:00.
    var sent: Date { day(2026, 11, 27, 10) }

    func find(_ text: String, sentAt: Date? = nil) -> [DateMention] {
        let s = sentAt ?? sent
        return DateMentions.find(in: text, sentAt: s, now: s, calendar: cal)
    }

    func testOutOfOfficeExample() {
        let text = "Thank you for your email. I am currently on PTO and I'll be back on Monday December 7th, so please expect a delayed response. If your message is urgent, please call me on +31 615 945 988. Otherwise, I will get back to you after my return."
        let found = find(text)
        XCTAssertEqual(found.count, 1, "\(found)")
        let m = found.first
        XCTAssertEqual(m?.kind, .returning)
        XCTAssertEqual(m?.date, day(2026, 12, 7))
        XCTAssertEqual(m?.suggestedReminder, day(2026, 12, 7, 9))
        XCTAssertEqual(m?.phrase, "Monday December 7th")
    }

    func testGermanOutOfOffice() {
        let a = find("Vielen Dank für Ihre Nachricht. Ich bin bis einschließlich 4. Dezember im Urlaub und ab Montag, 7. Dezember wieder im Büro.")
        XCTAssertEqual(a.first?.kind, .returning)
        XCTAssertEqual(a.first?.date, day(2026, 12, 7)) // Fri 4 Dec + 1 = Saturday → Monday
        XCTAssertEqual(a.count, 1, "\(a)")

        let b = find("Ich bin derzeit nicht im Büro. Ab dem 07.12.2026 bin ich wieder erreichbar. In dringenden Fällen wenden Sie sich an meine Kollegin.")
        XCTAssertEqual(b.map(\.kind), [.returning])
        XCTAssertEqual(b.first?.date, day(2026, 12, 7))
        XCTAssertEqual(b.first?.suggestedReminder, day(2026, 12, 7, 9))

        let c = find("Guten Morgen, ich bin bis 9.12. abwesend.")
        XCTAssertEqual(c.map(\.kind), [.returning], "\(c)") // "Guten Morgen" is not "tomorrow"
        XCTAssertEqual(c.first?.date, day(2026, 12, 10))

        let d = find("Ich bin am 7.12. wieder zurück.")
        XCTAssertEqual(d.first?.date, day(2026, 12, 7))
        XCTAssertEqual(d.first?.kind, .returning)
    }

    func testAbsenceRangeEnglish() {
        let r = find("I'm out of the office from December 1 until December 4 with limited access to email.")
        XCTAssertEqual(r.first?.kind, .returning)
        XCTAssertEqual(r.first?.date, day(2026, 12, 7)) // Fri 4 → back Monday
        XCTAssertEqual(r.dropFirst().first?.kind, .other) // the absence starts 1 Dec
    }

    func testDeadline() {
        let r = find("Hi Ann,\nplease send the signed contract by Friday, December 4. Thanks!")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.kind, .deadline)
        XCTAssertEqual(r.first?.date, day(2026, 12, 4))
        XCTAssertEqual(r.first?.suggestedReminder, day(2026, 12, 4, 9))

        let de = find("Bitte schicken Sie uns die Unterlagen bis spätestens 15.12. zurück.")
        // "zurück" refers to the documents here, but sending them back is still about that day.
        XCTAssertEqual(de.first?.date, day(2026, 12, 15))

        let frist = find("Die Frist endet am 10. Dezember 2026.")
        XCTAssertEqual(frist.first?.kind, .deadline)
        XCTAssertEqual(frist.first?.date, day(2026, 12, 10))
    }

    func testOtherAndSorting() {
        let r = find("Let's meet on 2026-12-15. By the way I'm on vacation and back on Dec 9.")
        XCTAssertEqual(r.map(\.kind), [.returning, .other])
        XCTAssertEqual(r.map(\.date), [day(2026, 12, 9), day(2026, 12, 15)])
    }

    func testQuotedOlderMailIsIgnored() {
        let text = """
        Sounds good, thanks.

        On Tue, Nov 3, 2026 at 10:00 AM, Ann Lee <ann@example.com> wrote:
        > I am out of office until December 7.
        > Back on Monday December 7th.
        """
        XCTAssertEqual(find(text), [])

        let german = """
        Danke!

        Am 03.11.2026 um 10:00 schrieb Ann Lee <ann@example.com>:
        Ich bin bis 9.12. im Urlaub.
        """
        XCTAssertEqual(find(german), [])

        let outlook = """
        Passt.

        From: Ann Lee <ann@example.com>
        Sent: Tuesday, November 3, 2026 10:00
        Subject: Urlaub
        I'm on vacation until December 9.
        """
        XCTAssertEqual(find(outlook), [])

        XCTAssertEqual(find("> back on December 7th\n> thanks"), [])
    }

    func testNoFalsePositives() {
        let text = """
        Call me on +31 615 945 988 or 030 1234 5678.
        The meeting is at 10:30 or 14.30 Uhr.
        We shipped version 0.7.1 and 1.12.2 last week; also v2.10.15 and 10.0.0.1.
        The price is 7.12 EUR, about 3/4 of last year. 12/7 is ambiguous.
        Guten Morgen! Am Morgen gehe ich laufen.
        You may 5 times ask.
        """
        let r = find(text)
        XCTAssertEqual(r, [], "\(r)")
    }

    func testYearInference() {
        // A December date in a January mail is the same year; a January date in a December mail is the next.
        let jan = day(2026, 1, 10, 9)
        XCTAssertEqual(find("Back on December 7th, I'm on vacation.", sentAt: jan).first?.date, day(2026, 12, 7))
        let dec = day(2026, 12, 20, 9)
        XCTAssertEqual(find("I am on holiday until January 6.", sentAt: dec).first?.date, day(2027, 1, 7))
        // A weekday that only fits next year moves it there.
        XCTAssertEqual(find("See you Monday 4 January.", sentAt: dec).first?.date, day(2027, 1, 4))
    }

    func testWindow() {
        // Too far ahead, or already past (relative to now), is not offered.
        XCTAssertEqual(find("The contract runs until 2028-06-30."), [])
        let old = day(2025, 3, 1, 9)
        XCTAssertEqual(DateMentions.find(in: "Back on March 10.", sentAt: old, now: sent, calendar: cal), [])
    }

    func testRelativeWords() {
        let t = find("Can you send it tomorrow?")
        XCTAssertEqual(t.first?.date, day(2026, 11, 28))
        let m = find("Ich schicke es dir morgen.")
        XCTAssertEqual(m.first?.date, day(2026, 11, 28))
        let w = find("Ich bin nächste Woche wieder im Büro.")
        XCTAssertEqual(w.first?.kind, .returning)
        XCTAssertEqual(w.first?.date, day(2026, 11, 30)) // Monday after Fri 27 Nov
        let nw = find("Let's talk next week.")
        XCTAssertEqual(nw.first?.date, day(2026, 11, 30))
        let wd = find("I'm away, back on Wednesday.")
        XCTAssertEqual(wd.first?.date, day(2026, 12, 2))
        XCTAssertEqual(wd.first?.kind, .returning)
    }

    func testMoreFormats() {
        XCTAssertEqual(find("Termin: 7 December 2026").first?.date, day(2026, 12, 7))
        XCTAssertEqual(find("Termin: Dec 7").first?.date, day(2026, 12, 7))
        XCTAssertEqual(find("on the 7th of December").first?.date, day(2026, 12, 7))
        XCTAssertEqual(find("Mo., 7.12. passt").first?.date, day(2026, 12, 7))
        XCTAssertEqual(find("Back on Mon 7 Dec, I'm away").first?.date, day(2026, 12, 7))
        XCTAssertEqual(find("Lunch on 7 December 12:00?").first?.date, day(2026, 12, 7))
        XCTAssertEqual(find("Am 31.11. geht nicht"), []) // no such day
    }

    func testLongTextIsCapped() {
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 400)
        XCTAssertEqual(find(filler + "Back on December 7th."), [])
        XCTAssertEqual(find("Back on December 7th. " + filler).first?.date, day(2026, 12, 7))
    }
}
