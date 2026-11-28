import XCTest
@testable import SlyyMailKit

/// iTIP for ONE occurrence of a recurring meeting (RECURRENCE-ID) must touch only that occurrence, never the series.
final class OccurrenceITIPTests: XCTestCase {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, zone: TimeZone = berlin) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Weekly Friday 10:00 Berlin, 6 times from 2027-01-08, with an override moving 2027-01-22 to 14:00.
    static func series(uid: String, organizer: String, attendee: String, summary: String = "Weekly") -> String {
        """
        BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:x\r\nBEGIN:VEVENT\r\nUID:\(uid)\r\nDTSTAMP:20261101T000000Z\r\n\
        DTSTART;TZID=Europe/Berlin:20270108T100000\r\nDTEND;TZID=Europe/Berlin:20270108T110000\r\nRRULE:FREQ=WEEKLY;COUNT=6\r\n\
        SUMMARY:\(summary)\r\nORGANIZER:mailto:\(organizer)\r\n\
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:\(organizer)\r\nATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:\(attendee)\r\nEND:VEVENT\r\n\
        BEGIN:VEVENT\r\nUID:\(uid)\r\nDTSTAMP:20261101T000000Z\r\nRECURRENCE-ID;TZID=Europe/Berlin:20270122T100000\r\n\
        DTSTART;TZID=Europe/Berlin:20270122T140000\r\nDTEND;TZID=Europe/Berlin:20270122T150000\r\nSUMMARY:\(summary) (moved)\r\n\
        ORGANIZER:mailto:\(organizer)\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:\(organizer)\r\nATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:\(attendee)\r\n\
        END:VEVENT\r\nEND:VCALENDAR\r\n
        """
    }

    static func itip(_ method: String, uid: String, organizer: String, attendee: String, partstat: String = "NEEDS-ACTION", rid: String?) -> String {
        """
        BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:x\r\nMETHOD:\(method)\r\nBEGIN:VEVENT\r\nUID:\(uid)\r\nDTSTAMP:20261120T000000Z\r\nSEQUENCE:1\r\n\
        \(rid.map { "RECURRENCE-ID;TZID=Europe/Berlin:\($0)\r\n" } ?? "")\
        DTSTART;TZID=Europe/Berlin:\(rid ?? "20270108T100000")\r\nSUMMARY:Weekly\r\nORGANIZER:mailto:\(organizer)\r\n\
        ATTENDEE;PARTSTAT=\(partstat):mailto:\(attendee)\r\n\(method == "CANCEL" ? "STATUS:CANCELLED\r\n" : "")END:VEVENT\r\nEND:VCALENDAR\r\n
        """
    }

    func starts(_ ics: String) -> [Date] {
        ICalendarReader.expand(ICalendarReader.read(ics).events, from: Self.date(2027, 1, 1), to: Self.date(2027, 3, 1)).map(\.start)
    }

    // MARK: Unit

    func testCancelOccurrenceAddsExdateAndDropsOverride() throws {
        let root = try XCTUnwrap(ICalComponent.parse(Self.series(uid: "u1", organizer: "org@example.org", attendee: "me@example.org")))
        // Cancel the plain occurrence 2027-01-15 and the overridden one 2027-01-22 (RECURRENCE-ID given in UTC: same instant).
        let once = try XCTUnwrap(ICalendarWriter.cancelOccurrence(Self.date(2027, 1, 15, 10), uid: "u1", in: root))
        let twice = try XCTUnwrap(ICalendarWriter.cancelOccurrence(Self.date(2027, 1, 22, 10), uid: "u1", in: try XCTUnwrap(ICalComponent.parse(once))))
        XCTAssertTrue(twice.contains("EXDATE;TZID=Europe/Berlin:20270115T100000"), twice)
        XCTAssertTrue(twice.contains("EXDATE;TZID=Europe/Berlin:20270122T100000"), twice)
        XCTAssertTrue(twice.contains("RRULE:FREQ=WEEKLY;COUNT=6"))
        XCTAssertFalse(twice.contains("RECURRENCE-ID"), "the override for the cancelled occurrence is gone")
        let r = ICalendarReader.read(twice)
        XCTAssertEqual(r.events.count, 1)
        XCTAssertEqual(starts(twice), [Self.date(2027, 1, 8, 10), Self.date(2027, 1, 29, 10), Self.date(2027, 2, 5, 10), Self.date(2027, 2, 12, 10)])
        // Cancelling the same occurrence again does not add a second EXDATE.
        let again = try XCTUnwrap(ICalendarWriter.cancelOccurrence(Self.date(2027, 1, 15, 10), uid: "u1", in: try XCTUnwrap(ICalComponent.parse(twice))))
        XCTAssertEqual(again.components(separatedBy: "20270115T100000").count - 1, 1)
    }

    func testCancelOccurrenceOfAllDaySeriesUsesDateForm() throws {
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:x\r\nBEGIN:VEVENT\r\nUID:d1\r\nDTSTART;VALUE=DATE:20270104\r\nDTEND;VALUE=DATE:20270105\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Off\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let rid = try XCTUnwrap(ICalTime.parse("20270105", tzid: nil, isDate: true)).date
        let out = try XCTUnwrap(ICalendarWriter.cancelOccurrence(rid, uid: "d1", in: try XCTUnwrap(ICalComponent.parse(ics))))
        XCTAssertTrue(out.contains("EXDATE;VALUE=DATE:20270105"), out)
        let all = ICalendarReader.expand(ICalendarReader.read(out).events, from: rid.addingTimeInterval(-5 * 86400), to: rid.addingTimeInterval(5 * 86400))
        XCTAssertEqual(all.count, 2)
    }

    func testCancelOnlyRemainingPartReturnsNil() throws {
        // Only an override stored (invited to that one occurrence): cancelling it leaves nothing.
        let only = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:x\r\nBEGIN:VEVENT\r\nUID:o1\r\nRECURRENCE-ID:20270122T090000Z\r\nDTSTART:20270122T090000Z\r\nDTEND:20270122T100000Z\r\nSUMMARY:x\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        XCTAssertNil(ICalendarWriter.cancelOccurrence(Self.date(2027, 1, 22, 10), uid: "o1", in: try XCTUnwrap(ICalComponent.parse(only))))
    }

    func testWritingAnOccurrenceKeepsTheMaster() throws {
        let original = Self.series(uid: "u2", organizer: "me@example.org", attendee: "bob@example.org")
        let root = try XCTUnwrap(ICalComponent.parse(original))
        // An answer for 2027-01-15 (no override yet) adds an override and leaves the master as it was.
        var occ = try XCTUnwrap(CalendarService.override(of: ICalendarReader.read(original).events, at: Self.date(2027, 1, 15, 10)))
        occ.attendees[1].status = .accepted
        let out = ICalendarReader.read(ICalendarWriter.object(occ, keeping: root))
        let master = try XCTUnwrap(out.events.first { $0.recurrenceID == nil })
        XCTAssertNotNil(master.recurrence)
        XCTAssertEqual(master.start, Self.date(2027, 1, 8, 10))
        XCTAssertEqual(master.status(of: "bob@example.org"), .needsAction)
        XCTAssertEqual(out.events.first { $0.recurrenceID == Self.date(2027, 1, 15, 10) }?.status(of: "bob@example.org"), .accepted)
        XCTAssertEqual(out.events.count, 3)
        // The existing override for 2027-01-22 is updated in place, not duplicated.
        var moved = try XCTUnwrap(out.events.first { $0.recurrenceID == Self.date(2027, 1, 22, 10) })
        moved.attendees[1].status = .declined
        let out2 = ICalendarReader.read(ICalendarWriter.object(moved, keeping: try XCTUnwrap(out.root)))
        XCTAssertEqual(out2.events.count, 3)
        XCTAssertEqual(out2.events.first { $0.recurrenceID == Self.date(2027, 1, 22, 10) }?.status(of: "bob@example.org"), .declined)
        XCTAssertEqual(out2.events.first { $0.recurrenceID == nil }?.status(of: "bob@example.org"), .needsAction)
    }

    // MARK: Live (Radicale, SLYY_IT=1)

    func testApplyCancelAndReplyForOneOccurrence() async throws {
        let me = try TestAccount.local("r1@example.com")
        let mail = me.mail()
        let service = me.calendar(mail)
        try await me.withTestCalendar { client, cal in
            // I'm invited to a weekly series; the organizer cancels only 2027-01-15.
            let uid = "r1-cancel-\(me.token)-\(UUID().uuidString)"
            let stored = try await client.put(ics: Self.series(uid: uid, organizer: "org@example.org", attendee: "r1@example.com", summary: me.tagged("Weekly")), uid: uid, calendarURL: cal.url)
            try await service.apply(itip: Self.itip("CANCEL", uid: uid, organizer: "org@example.org", attendee: "r1@example.com", rid: "20270115T100000"))
            let afterOne = try await client.object(at: stored.url)
            XCTAssertEqual(starts(afterOne.ics).count, 5, "only the cancelled occurrence is gone")
            XCTAssertFalse(starts(afterOne.ics).contains(Self.date(2027, 1, 15, 10)))
            // Cancelling the moved occurrence drops its override too.
            try await service.apply(itip: Self.itip("CANCEL", uid: uid, organizer: "org@example.org", attendee: "r1@example.com", rid: "20270122T100000"))
            let afterTwo = try await client.object(at: stored.url)
            XCTAssertEqual(afterTwo.events.count, 1)
            XCTAssertEqual(starts(afterTwo.ics).count, 4)
            // A CANCEL without RECURRENCE-ID still removes the whole series.
            try await service.apply(itip: Self.itip("CANCEL", uid: uid, organizer: "org@example.org", attendee: "r1@example.com", rid: nil))
            let gone = try await service.findObject(uid: uid)
            XCTAssertNil(gone)

            // I organize a series; an attendee accepts only 2027-01-29: the series' status stays as it was.
            let uid2 = "r1-reply-\(me.token)-\(UUID().uuidString)"
            let stored2 = try await client.put(ics: Self.series(uid: uid2, organizer: "r1@example.com", attendee: "guest@example.org", summary: me.tagged("Mine")), uid: uid2, calendarURL: cal.url)
            try await service.apply(itip: Self.itip("REPLY", uid: uid2, organizer: "r1@example.com", attendee: "guest@example.org", partstat: "ACCEPTED", rid: "20270129T100000"))
            let replied = try await client.object(at: stored2.url)
            XCTAssertEqual(replied.events.first { $0.recurrenceID == nil }?.status(of: "guest@example.org"), .needsAction)
            XCTAssertNotNil(replied.events.first { $0.recurrenceID == nil }?.recurrence)
            XCTAssertEqual(replied.events.first { $0.recurrenceID == Self.date(2027, 1, 29, 10) }?.status(of: "guest@example.org"), .accepted)
            XCTAssertEqual(starts(replied.ics).count, 6)
        }
        await mail.disconnect()
    }
}
