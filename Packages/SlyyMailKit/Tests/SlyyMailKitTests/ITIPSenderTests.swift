import XCTest
@testable import SlyyMailKit

/// Incoming CANCEL/REPLY mails change the calendar only when they come from the organizer / the answering attendee.
final class ITIPSenderTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func stored() -> CalendarEvent {
        CalendarEvent(uid: "uid-1", summary: "Meeting", start: start, end: start.addingTimeInterval(3600),
                      organizer: EmailAddress(name: "Org", address: "org@example.com"),
                      attendees: [Attendee(email: "org@example.com"), Attendee(email: "att@example.com")])
    }

    func itip(_ ics: String) -> CalendarEvent { ICalendarReader.read(ics).events[0] }

    func testCancelOnlyFromOrganizer() throws {
        let cancel = itip(ICalendarWriter.cancel(stored()))
        XCTAssertNoThrow(try CalendarService.checkSender("ORG@Example.com", method: "CANCEL", itip: cancel, stored: [stored()]))
        XCTAssertThrowsError(try CalendarService.checkSender("mallory@example.com", method: "CANCEL", itip: cancel, stored: [stored()])) {
            XCTAssertEqual($0 as? ITIPError, .cancelNotFromOrganizer)
        }
        XCTAssertThrowsError(try CalendarService.checkSender("", method: "CANCEL", itip: cancel, stored: [stored()]))
        // The iTIP's own ORGANIZER must match the stored one too.
        var forged = stored()
        forged.organizer = EmailAddress(name: "", address: "mallory@example.com")
        XCTAssertThrowsError(try CalendarService.checkSender("org@example.com", method: "CANCEL", itip: itip(ICalendarWriter.cancel(forged)), stored: [stored()]))
        // A stored event without organizer can't be cancelled by mail.
        var noOrg = stored()
        noOrg.organizer = nil
        XCTAssertThrowsError(try CalendarService.checkSender("org@example.com", method: "CANCEL", itip: cancel, stored: [noOrg]))
    }

    func testReplyOnlyFromThatAttendee() throws {
        let reply = itip(ICalendarWriter.reply(to: stored(), attendee: EmailAddress(name: "", address: "att@example.com"), status: .declined))
        XCTAssertNoThrow(try CalendarService.checkSender("Att@Example.com", method: "REPLY", itip: reply, stored: [stored()]))
        XCTAssertThrowsError(try CalendarService.checkSender("mallory@example.com", method: "REPLY", itip: reply, stored: [stored()])) {
            XCTAssertEqual($0 as? ITIPError, .replyNotFromAttendee)
        }
        // Sender matches the reply's attendee, but that attendee isn't invited.
        let stranger = itip(ICalendarWriter.reply(to: stored(), attendee: EmailAddress(name: "", address: "mallory@example.com"), status: .accepted))
        XCTAssertThrowsError(try CalendarService.checkSender("mallory@example.com", method: "REPLY", itip: stranger, stored: [stored()]))
    }

    /// On Radicale as r2: a forged CANCEL/REPLY leaves the event alone, the genuine ones are applied.
    func testApplyChecksSenderLive() async throws {
        let r2 = try TestAccount.local("r2@example.com", name: "R2")
        let mail = r2.mail()
        try await r2.withTestCalendar { client, cal in
            let service = r2.calendar(mail)
            let begin = Date().addingTimeInterval(2 * 86400)

            // r2 is invited by org@: only org@ may cancel.
            let invited = CalendarEvent(summary: r2.tagged("invited"), start: begin, end: begin.addingTimeInterval(3600),
                                        organizer: EmailAddress(name: "Org", address: "org@example.com"),
                                        attendees: [Attendee(email: "org@example.com"), Attendee(email: "r2@example.com", status: .accepted)])
            _ = try await client.put(ics: ICalendarWriter.object(invited), uid: invited.uid, calendarURL: cal.url)
            let cancel = ICalendarWriter.cancel(invited)
            do {
                try await service.apply(itip: cancel, from: "mallory@example.com")
                XCTFail("forged CANCEL was applied")
            } catch ITIPError.cancelNotFromOrganizer {}
            let still = try await service.findObject(uid: invited.uid)
            XCTAssertNotNil(still, "a CANCEL from a stranger must not delete the event")
            try await service.apply(itip: cancel, from: "Org@example.com")
            let gone = try await service.findObject(uid: invited.uid)
            XCTAssertNil(gone)

            // r2 organizes with att@: only att@ may answer for att@.
            let mine = CalendarEvent(summary: r2.tagged("mine"), start: begin, end: begin.addingTimeInterval(3600),
                                     organizer: EmailAddress(name: "R2", address: "r2@example.com"),
                                     attendees: [Attendee(email: "r2@example.com", status: .accepted), Attendee(email: "att@example.com")])
            _ = try await client.put(ics: ICalendarWriter.object(mine), uid: mine.uid, calendarURL: cal.url)
            let reply = ICalendarWriter.reply(to: mine, attendee: EmailAddress(name: "", address: "att@example.com"), status: .declined)
            do {
                try await service.apply(itip: reply, from: "mallory@example.com")
                XCTFail("forged REPLY was applied")
            } catch ITIPError.replyNotFromAttendee {}
            let unchanged = try await service.findObject(uid: mine.uid)
            XCTAssertEqual(unchanged?.events.first?.status(of: "att@example.com"), .needsAction)
            try await service.apply(itip: reply, from: "att@example.com")
            let answered = try await service.findObject(uid: mine.uid)
            XCTAssertEqual(answered?.events.first?.status(of: "att@example.com"), .declined)
            XCTAssertEqual(answered?.events.first?.status(of: "r2@example.com"), .accepted)
        }
        await mail.disconnect()
    }
}
