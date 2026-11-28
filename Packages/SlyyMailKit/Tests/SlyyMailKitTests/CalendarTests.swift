import XCTest
@testable import SlyyMailKit

final class CalendarTests: XCTestCase {
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    func date(_ s: String, _ tz: TimeZone? = nil) -> Date {
        ICalTime.parse(s, tzid: (tz ?? berlin).identifier)!.date
    }

    /// Invite as Outlook sends it: Windows TZID, folded lines, escaped text.
    let outlookInvite = """
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    PRODID:Microsoft Exchange Server 2010\r
    VERSION:2.0\r
    BEGIN:VTIMEZONE\r
    TZID:W. Europe Standard Time\r
    BEGIN:STANDARD\r
    DTSTART:16010101T030000\r
    TZOFFSETFROM:+0200\r
    TZOFFSETTO:+0100\r
    RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10\r
    END:STANDARD\r
    BEGIN:DAYLIGHT\r
    DTSTART:16010101T020000\r
    TZOFFSETFROM:+0100\r
    TZOFFSETTO:+0200\r
    RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3\r
    END:DAYLIGHT\r
    END:VTIMEZONE\r
    BEGIN:VEVENT\r
    ORGANIZER;CN="Heiko M.":mailto:heiko@slyy.ai\r
    ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Alice:mailto:alice@example.com\r
    DESCRIPTION;LANGUAGE=de-DE:Agenda:\\n- Angebot\\, Termine\\n\r
     - Lager\r
    UID:040000008200E00074C5B7101A82E008000000001\r
    SUMMARY;LANGUAGE=de-DE:Wochenfazit\r
    DTSTART;TZID=W. Europe Standard Time:20261127T100000\r
    DTEND;TZID=W. Europe Standard Time:20261127T103000\r
    RRULE:FREQ=WEEKLY;BYDAY=FR\r
    EXDATE;TZID=W. Europe Standard Time:20261225T100000\r
    LOCATION;LANGUAGE=de-DE:https://vid.rocket.re-cloud.io/slyy-abcdefghijkmnpqrstu\r
    SEQUENCE:2\r
    BEGIN:VALARM\r
    TRIGGER:-PT15M\r
    ACTION:DISPLAY\r
    END:VALARM\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    func testParseOutlookInvite() throws {
        let r = ICalendarReader.read(outlookInvite)
        XCTAssertEqual(r.method, "REQUEST")
        let e = try XCTUnwrap(r.events.first)
        XCTAssertEqual(e.summary, "Wochenfazit")
        XCTAssertEqual(e.notes, "Agenda:\n- Angebot, Termine\n- Lager")
        XCTAssertEqual(e.timeZoneID, "Europe/Berlin")
        XCTAssertEqual(e.start, ISO8601DateFormatter().date(from: "2026-11-27T09:00:00Z"))
        XCTAssertEqual(e.duration, 1800)
        XCTAssertEqual(e.organizer?.name, "Heiko M.")
        XCTAssertEqual(e.attendees.first?.email, "alice@example.com")
        XCTAssertEqual(e.status(of: "ALICE@example.com"), .needsAction)
        XCTAssertEqual(e.recurrence?.frequency, .weekly)
        XCTAssertEqual(e.videoURL?.host, "vid.rocket.re-cloud.io")
        XCTAssertEqual(e.alarmMinutes, 15)
        XCTAssertEqual(e.sequence, 2)
    }

    func testWeeklyExpansionAcrossDSTAndExdate() {
        let e = ICalendarReader.read(outlookInvite).events[0]
        let from = date("20261201T000000")
        let to = date("20270501T000000")
        let occ = ICalendarReader.expand([e], from: from, to: to)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        // Every Friday 10:00 Berlin time, both in winter (CET) and after the March DST switch (CEST).
        XCTAssertTrue(occ.allSatisfy { cal.component(.hour, from: $0.start) == 10 && cal.component(.weekday, from: $0.start) == 6 })
        XCTAssertFalse(occ.contains { cal.dateComponents([.month, .day], from: $0.start) == DateComponents(month: 12, day: 25) })
        XCTAssertTrue(occ.contains { cal.dateComponents([.month, .day], from: $0.start) == DateComponents(month: 4, day: 2) })
        XCTAssertEqual(occ.count, 22 - 1) // 22 Fridays Dec 4 – Apr 30, minus Christmas
    }

    func testMonthlyAndYearlyRules() {
        let start = date("20260130T090000")
        let last = RecurrenceRule("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3")!
        let occ = last.occurrences(start: start, zone: berlin, rangeEnd: date("20270101T000000"))
        XCTAssertEqual(occ.map { ICalTime.format($0, zone: berlin) }, ["20260130T090000", "20260227T090000", "20260327T090000"])

        let monthDay = RecurrenceRule("FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=31;UNTIL=20260930T000000Z")!
        let md = monthDay.occurrences(start: date("20260131T080000"), zone: berlin, rangeEnd: date("20270101T000000"))
        // Every 2nd month from January on the 31st: Jan, Mar, May, Jul (Sep has no 31st), until end of September.
        XCTAssertEqual(md.map { ICalTime.formatDate($0, zone: berlin) }, ["20260131", "20260331", "20260531", "20260731"])
        let yearly = RecurrenceRule("FREQ=YEARLY;COUNT=3")!.occurrences(start: date("20261127T120000"), zone: berlin, rangeEnd: date("20400101T000000"))
        XCTAssertEqual(yearly.map { ICalTime.formatDate($0, zone: berlin) }, ["20261127", "20271127", "20281127"])
        let weekdays = RecurrenceRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=4")!.occurrences(start: date("20261130T080000"), zone: berlin, rangeEnd: date("20280101T000000"))
        XCTAssertEqual(weekdays.map { ICalTime.formatDate($0, zone: berlin) }, ["20261130", "20261202", "20261214", "20261216"])
    }

    func testRoundTripWithVideoAndAttendees() throws {
        let url = JitsiRoom.newURL()
        var e = CalendarEvent(summary: "Planung, Q1; Budget", notes: "Line 1\nLine 2", start: date("20261202T140000"), end: date("20261202T150000"), timeZoneID: "Europe/Berlin")
        e.organizer = EmailAddress(name: "Alice", address: "alice@example.com")
        e.attendees = [Attendee(email: "alice@example.com", name: "Alice", status: .accepted), Attendee(email: "bob@example.com", name: "Bob, B.")]
        e.videoURL = url
        e.recurrence = RecurrenceRule(frequency: .weekly, count: 4)
        let ics = ICalendarWriter.request(e)
        XCTAssertTrue(ics.contains("METHOD:REQUEST"))
        XCTAssertTrue(ics.contains("BEGIN:VTIMEZONE"))
        XCTAssertTrue(ics.contains("TZID:Europe/Berlin"))
        XCTAssertTrue(ics.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let back = try XCTUnwrap(ICalendarReader.read(ics).events.first)
        XCTAssertEqual(back.summary, e.summary)
        XCTAssertEqual(back.notes, e.notes)
        XCTAssertEqual(back.start, e.start)
        XCTAssertEqual(back.end, e.end)
        XCTAssertEqual(back.videoURL, url)
        XCTAssertEqual(back.location, url.absoluteString)
        XCTAssertEqual(back.attendees.map(\.name), ["Alice", "Bob, B."])
        XCTAssertEqual(back.recurrence?.count, 4)
        XCTAssertEqual(back.alarmMinutes, 10)
    }

    func testReplyAndCancel() throws {
        let invite = ICalendarReader.read(outlookInvite).events[0]
        let reply = ICalendarWriter.reply(to: invite, attendee: EmailAddress(name: "Alice", address: "alice@example.com"), status: .accepted)
        let r = ICalendarReader.read(reply)
        XCTAssertEqual(r.method, "REPLY")
        XCTAssertEqual(r.events.first?.uid, invite.uid)
        XCTAssertEqual(r.events.first?.attendees.map(\.status), [.accepted])
        XCTAssertEqual(r.events.first?.sequence, 2)

        let cancel = ICalendarReader.read(ICalendarWriter.cancel(invite))
        XCTAssertEqual(cancel.method, "CANCEL")
        XCTAssertTrue(cancel.events.first?.isCancelled == true)
        XCTAssertEqual(cancel.events.first?.sequence, 3)
    }

    func testUpdateKeepsUnknownPropertiesAndExceptions() throws {
        let original = """
        BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:x\r\nBEGIN:VEVENT\r\nUID:u1\r\nDTSTART:20261201T090000Z\r\nDTEND:20261201T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nX-CUSTOM:keep me\r\nSUMMARY:Old\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:u1\r\nRECURRENCE-ID:20261203T090000Z\r\nDTSTART:20261203T110000Z\r\nDTEND:20261203T120000Z\r\nSUMMARY:Moved\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n
        """
        let root = ICalComponent.parse(original)!
        var e = ICalendarReader.read(original).events.first { $0.recurrenceID == nil }!
        e.summary = "New"
        let updated = ICalendarWriter.object(e, keeping: root)
        XCTAssertTrue(updated.contains("X-CUSTOM:keep me"))
        XCTAssertTrue(updated.contains("SUMMARY:New"))
        XCTAssertTrue(updated.contains("SUMMARY:Moved"))
        let all = ICalendarReader.read(updated).events
        let occ = ICalendarReader.expand(all, from: ICalTime.parse("20261201", tzid: nil)!.date, to: ICalTime.parse("20261210", tzid: nil)!.date)
        XCTAssertEqual(occ.count, 5)
        XCTAssertEqual(occ.filter { $0.summary == "Moved" }.count, 1)
    }

    func testAllDayEvent() throws {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:h\r\nDTSTART;VALUE=DATE:20261224\r\nDTEND;VALUE=DATE:20261227\r\nSUMMARY:Feiertage\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let e = try XCTUnwrap(ICalendarReader.read(ics, defaultZone: berlin).events.first)
        XCTAssertTrue(e.isAllDay)
        XCTAssertEqual(e.duration, 3 * 86400)
        let out = ICalendarWriter.object(e)
        XCTAssertTrue(out.contains("DTSTART;VALUE=DATE:2026122"))
    }

    func testGeneratedVTimezone() {
        let tz = ICalTime.vtimezone(for: berlin, referenceYear: 2026)
        let s = tz.serialize()
        XCTAssertTrue(s.contains("BYMONTH=3;BYDAY=-1SU"))
        XCTAssertTrue(s.contains("BYMONTH=10;BYDAY=-1SU"))
        XCTAssertTrue(s.contains("TZOFFSETTO:+0200"))
        XCTAssertTrue(s.contains("DTSTART:19700329T020000"), s) // last Sunday of March 1970
        XCTAssertTrue(s.contains("DTSTART:19701025T030000"), s)
        let tokyo = ICalTime.vtimezone(for: TimeZone(identifier: "Asia/Tokyo")!).serialize()
        XCTAssertTrue(tokyo.contains("TZOFFSETTO:+0900"))
    }

    func testDurations() {
        XCTAssertEqual(ICalendarReader.parseDuration("-PT15M"), -900)
        XCTAssertEqual(ICalendarReader.parseDuration("P1DT2H"), 93600)
        XCTAssertEqual(ICalendarReader.parseDuration("P1W"), 604800)
    }
}

/// Live CalDAV tests on the local Radicale (SLYY_IT=1), in a calendar made and deleted for the run.
final class CalDAVIntegrationTests: XCTestCase {
    func testCalendarLifecycle() async throws {
        let alice = try TestAccount.local()
        let home = try await alice.caldav().discover()
        XCTAssertTrue(home.absoluteString.contains("alice"))
        try await alice.withTestCalendar { client, cal in
            let cals = try await client.calendars()
            XCTAssertTrue(cals.contains { $0.url == cal.url })

            let start = Date().addingTimeInterval(3600)
            var e = CalendarEvent(summary: alice.tagged("Live test"), start: start, end: start.addingTimeInterval(1800), timeZoneID: "Europe/Berlin")
            e.videoURL = JitsiRoom.newURL()
            e.recurrence = RecurrenceRule(frequency: .daily, count: 3)
            let created = try await client.put(ics: ICalendarWriter.object(e), uid: e.uid, calendarURL: cal.url)

            let objs = try await client.objects(in: cal, from: start.addingTimeInterval(-86400), to: start.addingTimeInterval(5 * 86400))
            let obj = try XCTUnwrap(objs.first { $0.events.first?.uid == e.uid })
            XCTAssertEqual(obj.events.first?.videoURL, e.videoURL)
            let occ = ICalendarReader.expand(obj.events, from: start.addingTimeInterval(-60), to: start.addingTimeInterval(5 * 86400))
            XCTAssertEqual(occ.count, 3)

            // Update with the ETag, keeping the original object.
            var changed = obj.events[0]
            changed.summary = alice.tagged("Live test (moved)")
            changed.sequence += 1
            try await client.put(ics: ICalendarWriter.object(changed, keeping: ICalComponent.parse(obj.ics)), uid: e.uid, calendarURL: cal.url, objectURL: obj.url, etag: obj.etag ?? created.etag)
            let reread = try await client.object(at: obj.url)
            XCTAssertEqual(reread.events.first?.summary, alice.tagged("Live test (moved)"))

            // A stale ETag must be rejected.
            do {
                try await client.put(ics: ICalendarWriter.object(changed), uid: e.uid, calendarURL: cal.url, objectURL: obj.url, etag: "\"stale\"")
                XCTFail("expected conflict")
            } catch CalDAVError.conflict {}

            try await client.delete(objectURL: obj.url, etag: reread.etag)
            let after = try await client.objects(in: cal, from: start.addingTimeInterval(-86400), to: start.addingTimeInterval(5 * 86400))
            XCTAssertFalse(after.contains { $0.url == obj.url })
        }
        let left = try await alice.caldav().calendars()
        XCTAssertFalse(left.contains { $0.name.contains(alice.token) }, "the run's calendar is gone")
    }
}
