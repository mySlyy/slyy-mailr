import XCTest
@testable import SlyyMailKit

/// Calendar round trip against the real mailcow SOGo with the mailbox from the secrets. Started by hand only
/// (GitHub Actions → "SOGo calendar test"). Safeguards come from TestAccount: a calendar made for the run and
/// deleted after, invitations only to the mailbox's own alias (SLYY_SOGO_ALIAS), and every mail of the run
/// (token in the subject) deleted from Inbox, Sent, Trash and Drafts at the end, also after a failure.
final class SOGoTests: XCTestCase {
    func testCalendarRoundTripOnSOGo() async throws {
        let me = try await TestAccount.mailcow()
        print("SOGo: IMAP \(me.settings.imap.host):\(me.settings.imap.port), SMTP \(me.settings.smtp.host):\(me.settings.smtp.port), CalDAV \(me.settings.caldavURL)")
        XCTAssertFalse(me.settings.caldavURL.isEmpty, "account setup finds SOGo's CalDAV address")
        let mail = me.mail()
        let before = try await me.caldav().calendars()
        print("SOGo: \(before.count) calendar(s) before the test")

        var failure: Error?
        do {
            try await me.withTestCalendar { caldav, calendar in
                try await calendarSteps(me, caldav: caldav, calendar: calendar)
                if let alias = TestAccount.env["SLYY_SOGO_ALIAS"], !alias.isEmpty {
                    try await invitationSteps(me, alias: alias, mail: mail, calendar: calendar)
                } else {
                    print("SOGo: no SLYY_SOGO_ALIAS, invitation steps skipped")
                }
            }
        } catch {
            failure = error
        }

        let after = try await me.caldav().calendars()
        XCTAssertEqual(Set(after.map(\.url)), Set(before.map(\.url)), "the mailbox's own calendars are unchanged, the test calendar is gone")
        let removed = await me.cleanUp(mail)
        print("SOGo: removed \(removed) test mail(s)")
        await mail.disconnect()
        if let failure { throw failure }
    }

    /// Events: create, read back, change (ETag, stale ETag refused), a weekly series across the DST change, delete.
    func calendarSteps(_ me: TestAccount, caldav: CalDAVClient, calendar: CalDAVCalendar) async throws {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date().addingTimeInterval(3 * 86400))!
        var e = CalendarEvent(summary: me.tagged("single"), location: "Raum 2", notes: "Umlaute: äöü ß", start: start, end: start.addingTimeInterval(1800), timeZoneID: tz.identifier)
        let stored = try await caldav.put(ics: ICalendarWriter.object(e), uid: e.uid, calendarURL: calendar.url)
        print("SOGo: created event, etag \(stored.etag ?? "none")")

        let objects = try await caldav.objects(in: calendar, from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(7200))
        let back = try XCTUnwrap(objects.first { $0.events.contains { $0.uid == e.uid } }?.events.first)
        XCTAssertEqual(back.summary, e.summary)
        XCTAssertEqual(back.notes, "Umlaute: äöü ß", "UTF-8 survives SOGo")
        XCTAssertEqual(back.start, start)
        XCTAssertEqual(back.end, start.addingTimeInterval(1800))

        e.summary = me.tagged("single changed")
        e.sequence = 1
        let changed = try await caldav.put(ics: ICalendarWriter.object(e), uid: e.uid, calendarURL: calendar.url, objectURL: stored.url, etag: stored.etag)
        if let old = stored.etag, changed.etag != nil {
            do {
                _ = try await caldav.put(ics: ICalendarWriter.object(e), uid: e.uid, calendarURL: calendar.url, objectURL: stored.url, etag: old)
                XCTFail("SOGo accepted a stale ETag")
            } catch CalDAVError.conflict {
            }
        }
        let reread = try await caldav.object(at: changed.url)
        XCTAssertEqual(reread.events.first?.summary, me.tagged("single changed"))

        let seriesStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        var series = CalendarEvent(summary: me.tagged("weekly"), start: seriesStart, end: seriesStart.addingTimeInterval(3600), timeZoneID: tz.identifier)
        series.recurrence = RecurrenceRule(frequency: .weekly, count: 30)
        _ = try await caldav.put(ics: ICalendarWriter.object(series), uid: series.uid, calendarURL: calendar.url)
        let span = seriesStart.addingTimeInterval(32 * 7 * 86400)
        let window = try await caldav.objects(in: calendar, from: seriesStart, to: span)
        let occurrences = ICalendarReader.expand(window.flatMap(\.events).filter { $0.uid == series.uid }, from: seriesStart.addingTimeInterval(-60), to: span)
        XCTAssertEqual(occurrences.count, 30)
        XCTAssertEqual(Set(occurrences.map { cal.component(.hour, from: $0.start) }), [9], "same local hour before and after the DST change")

        try await caldav.delete(objectURL: changed.url, etag: changed.etag)
        let afterDelete = try await caldav.objects(in: calendar, from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(7200))
        XCTAssertFalse(afterDelete.contains { $0.events.contains { $0.uid == e.uid } })
    }

    /// Invitations through SOGo: invite the alias, accept as the alias, the organizer applies the reply, cancel.
    /// Counts the invitations per save, to show whether SOGo also sends its own.
    func invitationSteps(_ me: TestAccount, alias: String, mail: MailService, calendar: CalDAVCalendar) async throws {
        let attendee = me.asAddress(alias)
        let attendeeMail = attendee.mail()
        defer { Task { await attendeeMail.disconnect() } }
        let orgCal = me.calendar(mail), attCal = attendee.calendar(attendeeMail)

        let title = me.tagged("Abstimmung")
        let start = Calendar.current.date(byAdding: .day, value: 4, to: Date())!
        var e = CalendarEvent(summary: title, start: start, end: start.addingTimeInterval(3600), timeZoneID: "Europe/Berlin")
        e.calendarURL = calendar.url
        e.attendees = [Attendee(email: alias, name: "CI Alias")]
        e.videoURL = JitsiRoom.newURL()
        let saved = try await orgCal.save(e)

        let invites = try await TestAccount.waitForMail(mail, timeout: 90, settle: 3) { $0.subject.contains(title) && !$0.subject.hasPrefix("Accepted") && !$0.subject.hasPrefix("Cancelled") }
        print("SOGo: \(invites.count) invitation mail(s) for one save" + (invites.count > 1 ? " (SOGo also sends its own)" : ""))
        let parsed = try await mail.message(invites[0], markSeen: false)
        let ics = try XCTUnwrap(parsed.calendarParts.first)
        XCTAssertEqual(ICalendarReader.read(ics).method, "REQUEST")
        let invite = try XCTUnwrap(ICalendarReader.read(ics).events.first)
        XCTAssertEqual(invite.uid, e.uid)
        XCTAssertEqual(invite.videoURL, e.videoURL)

        try await attCal.respond(to: invite, status: .accepted)
        let reply = try await TestAccount.waitForMail(mail, subjectContains: "Accepted: \(title)", timeout: 90)[0]
        let replyMessage = try await mail.message(reply, markSeen: false)
        try await orgCal.apply(itip: try XCTUnwrap(replyMessage.calendarParts.first))
        let obj = try await orgCal.findObject(uid: e.uid)
        XCTAssertEqual(obj?.events.first?.status(of: alias), .accepted, "the organizer's copy shows the acceptance")

        try await orgCal.delete(saved)
        try await TestAccount.waitForMail(mail, subjectContains: "Cancelled: \(title)", timeout: 90)
    }
}
