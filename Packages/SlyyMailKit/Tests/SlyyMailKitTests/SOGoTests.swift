import XCTest
@testable import SlyyMailKit

/// Calendar round trip against the real mailcow SOGo, with a real mailbox. Runs only when started by hand
/// (GitHub Actions → "SOGo calendar test"), with a mailcow app password from the repository secrets.
///
/// Safeguards:
/// - everything happens in a calendar made for this run ("Slyy Mailr CI <run>"), deleted at the end;
///   the mailbox's own calendars are only read;
/// - invitations go from the mailbox to its own alias (SLYY_SOGO_ALIAS), so nobody else gets mail;
/// - every mail of the run carries the run's token in its subject and is deleted from Inbox, Sent and Trash at the end.
///
/// Env: SLYY_SOGO_USER (login, e.g. ach@mc1.simplify-erp.de), SLYY_SOGO_PASSWORD (app password),
/// SLYY_SOGO_ALIAS (an alias delivering to the same mailbox), SLYY_SOGO_RUN (a run id for the token).
final class SOGoTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func testCalendarRoundTripOnSOGo() async throws {
        guard let user = env["SLYY_SOGO_USER"], !user.isEmpty, let password = env["SLYY_SOGO_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("SOGo test not configured (SLYY_SOGO_USER / SLYY_SOGO_PASSWORD)")
        }
        let alias = env["SLYY_SOGO_ALIAS"] ?? ""
        let token = "SlyyCI-\(env["SLYY_SOGO_RUN"] ?? String(UUID().uuidString.prefix(6)))"

        // 1. Discovery: the account's servers and SOGo's CalDAV address, as account setup finds them.
        var organizer = await AutoConfig.discover(email: user)
        organizer.username = user
        organizer.displayName = "Slyy Mailr CI"
        print("SOGo: IMAP \(organizer.imap.host):\(organizer.imap.port), SMTP \(organizer.smtp.host):\(organizer.smtp.port), CalDAV \(organizer.caldavURL)")
        XCTAssertTrue(organizer.caldavURL.contains("/SOGo/dav") || !organizer.caldavURL.isEmpty, "CalDAV found: \(organizer.caldavURL)")
        let mail = MailService(account: organizer, password: password)
        let caldav = CalDAVClient(baseURL: try XCTUnwrap(URL(string: organizer.caldavURL)), username: user, password: password)

        let before = try await caldav.calendars()
        print("SOGo: \(before.count) calendar(s) before the test")
        let testCal = try await caldav.makeCalendar(name: "Slyy Mailr CI \(token)")
        var failure: Error?
        do {
            try await calendarSteps(caldav: caldav, calendar: testCal, token: token)
            if alias.isEmpty {
                print("SOGo: no SLYY_SOGO_ALIAS, invitation steps skipped")
            } else {
                try await invitationSteps(organizer: organizer, password: password, alias: alias, mail: mail, calendar: testCal, token: token)
            }
        } catch {
            failure = error
        }

        // 4. Clean up, whatever happened: the test calendar, then every mail with the token.
        try? await caldav.deleteCalendar(testCal)
        let after = try await caldav.calendars()
        XCTAssertFalse(after.contains { $0.url == testCal.url }, "test calendar removed")
        XCTAssertEqual(Set(after.map(\.url)), Set(before.map(\.url)), "the mailbox's own calendars are unchanged")
        let removed = await deleteMails(containing: token, mail: mail)
        print("SOGo: removed \(removed) test mail(s)")
        await mail.disconnect()
        if let failure { throw failure }
    }

    /// 2. Events: create, read back, change (ETag), a weekly series across the DST change, delete.
    func calendarSteps(caldav: CalDAVClient, calendar: CalDAVCalendar, token: String) async throws {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date().addingTimeInterval(3 * 86400))!
        var e = CalendarEvent(summary: "\(token) single", location: "Raum 2", notes: "Umlaute: äöü ß", start: start, end: start.addingTimeInterval(1800), timeZoneID: tz.identifier)
        let stored = try await caldav.put(ics: ICalendarWriter.object(e), uid: e.uid, calendarURL: calendar.url)
        print("SOGo: created \(stored.url) etag \(stored.etag ?? "none")")

        let objects = try await caldav.objects(in: calendar, from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(7200))
        let back = try XCTUnwrap(objects.first { $0.events.contains { $0.uid == e.uid } }?.events.first)
        XCTAssertEqual(back.summary, e.summary)
        XCTAssertEqual(back.notes, "Umlaute: äöü ß", "UTF-8 survives SOGo")
        XCTAssertEqual(back.start, start)
        XCTAssertEqual(back.end, start.addingTimeInterval(1800))

        // Change with the ETag; a stale ETag must be refused.
        e.summary = "\(token) single changed"
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
        XCTAssertEqual(reread.events.first?.summary, "\(token) single changed")

        // A weekly series at 09:00 local time keeps 09:00 across the DST change (VTIMEZONE round trip).
        let seriesStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        var series = CalendarEvent(summary: "\(token) weekly", start: seriesStart, end: seriesStart.addingTimeInterval(3600), timeZoneID: tz.identifier)
        series.recurrence = RecurrenceRule(frequency: .weekly, count: 30)
        _ = try await caldav.put(ics: ICalendarWriter.object(series), uid: series.uid, calendarURL: calendar.url)
        let window = try await caldav.objects(in: calendar, from: seriesStart, to: seriesStart.addingTimeInterval(32 * 7 * 86400))
        let occurrences = ICalendarReader.expand(window.flatMap(\.events).filter { $0.uid == series.uid }, from: seriesStart.addingTimeInterval(-60), to: seriesStart.addingTimeInterval(32 * 7 * 86400))
        XCTAssertEqual(occurrences.count, 30)
        XCTAssertEqual(Set(occurrences.map { cal.component(.hour, from: $0.start) }), [9], "same local hour before and after the DST change")

        try await caldav.delete(objectURL: changed.url, etag: changed.etag)
        let afterDelete = try await caldav.objects(in: calendar, from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(7200))
        XCTAssertFalse(afterDelete.contains { $0.events.contains { $0.uid == e.uid } })
    }

    /// 3. Invitations through SOGo: invite the alias, accept as the alias, the organizer applies the reply, cancel.
    func invitationSteps(organizer: AccountSettings, password: String, alias: String, mail: MailService, calendar: CalDAVCalendar, token: String) async throws {
        var attendee = organizer
        attendee.email = alias // same login, answering as the alias
        let attendeeMail = MailService(account: attendee, password: password)
        defer { Task { await attendeeMail.disconnect() } }
        let orgCal = CalendarService(account: organizer, password: password, mail: mail)
        let attCal = CalendarService(account: attendee, password: password, mail: attendeeMail)

        let title = "\(token) Abstimmung"
        let start = Calendar.current.date(byAdding: .day, value: 4, to: Date())!
        var e = CalendarEvent(summary: title, start: start, end: start.addingTimeInterval(3600), timeZoneID: "Europe/Berlin")
        e.calendarURL = calendar.url
        e.attendees = [Attendee(email: alias, name: "CI Alias")]
        e.videoURL = JitsiRoom.newURL()
        let saved = try await orgCal.save(e)

        let invites = try await waitForMails(mail, subjectContains: title, atLeast: 1)
        print("SOGo: \(invites.count) invitation mail(s) arrived for one save" + (invites.count > 1 ? " (SOGo also sent its own)" : ""))
        let parsed = try await mail.message(try XCTUnwrap(invites.first), markSeen: false)
        let ics = try XCTUnwrap(parsed.calendarParts.first)
        XCTAssertEqual(ICalendarReader.read(ics).method, "REQUEST")
        let invite = try XCTUnwrap(ICalendarReader.read(ics).events.first)
        XCTAssertEqual(invite.uid, e.uid)
        XCTAssertEqual(invite.videoURL, e.videoURL)

        try await attCal.respond(to: invite, status: .accepted)
        let replies = try await waitForMails(mail, subjectContains: "Accepted: \(title)", atLeast: 1)
        let reply = try await mail.message(try XCTUnwrap(replies.first), markSeen: false)
        try await orgCal.apply(itip: try XCTUnwrap(reply.calendarParts.first))
        let obj = try await orgCal.findObject(uid: e.uid)
        XCTAssertEqual(obj?.events.first?.status(of: alias), .accepted, "the organizer's copy shows the acceptance")

        try await orgCal.delete(saved)
        let cancels = try await waitForMails(mail, subjectContains: "Cancelled: \(title)", atLeast: 1)
        XCTAssertFalse(cancels.isEmpty)
    }

    func waitForMails(_ mail: MailService, subjectContains s: String, atLeast n: Int) async throws -> [MessageSummary] {
        var hits: [MessageSummary] = []
        for _ in 0..<45 {
            hits = (try? await mail.search(in: "INBOX", text: s))?.filter { $0.subject.contains(s) } ?? []
            if hits.count >= n {
                try await Task.sleep(nanoseconds: 3_000_000_000) // a moment for a second copy (SOGo's own) to arrive
                return (try? await mail.search(in: "INBOX", text: s))?.filter { $0.subject.contains(s) } ?? hits
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        XCTFail("no mail with “\(s)” arrived within 90 s")
        return hits
    }

    /// Permanently removes every mail of this run (Inbox, Sent, Trash), matched by the token in the subject.
    func deleteMails(containing token: String, mail: MailService) async -> Int {
        var folders = ["INBOX"]
        for use in [SpecialUse.sent, .trash, .drafts] {
            if let f = try? await mail.folder(use) { folders.append(f.serverPath) }
        }
        var count = 0
        for f in folders {
            let hits = ((try? await mail.search(in: f, text: token)) ?? []).filter { $0.subject.contains(token) }
            guard !hits.isEmpty else { continue }
            if (try? await mail.withIMAP { try await $0.expunge(folder: f, uids: hits.map(\.uid)) }) != nil { count += hits.count }
        }
        return count
    }
}
