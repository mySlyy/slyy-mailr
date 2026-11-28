import XCTest
@testable import SlyyMailKit

/// A meeting added in the writer: the mail itself is the invitation (iTIP REQUEST part), no separate invitation mail.
final class MeetingInviteTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
    let org = EmailAddress(name: "Ann Org", address: "ann@example.com")
    let video = URL(string: "https://vid.example.com/slyy-abcdefghijkmnpqrstuv")!

    func meeting(title: String = "Planning") -> MeetingInvite {
        MeetingInvite(uid: "meet-1", title: title, start: start, minutes: 45, videoURL: video, timeZoneID: "Europe/Berlin")
    }

    func testEventHasOrganizerAndRecipientsOnce() {
        let e = meeting().event(organizer: org, attendees: [
            EmailAddress(name: "Bob", address: "bob@example.com"),
            EmailAddress(name: "", address: "ANN@example.com"), // the sender in Cc: not twice
            EmailAddress(name: "", address: "Bob@Example.com"),
            EmailAddress(name: "", address: "carol@example.com"),
        ])
        XCTAssertEqual(e.uid, "meet-1")
        XCTAssertEqual(e.organizer?.address, "ann@example.com")
        XCTAssertEqual(e.attendees.map(\.email), ["ann@example.com", "bob@example.com", "carol@example.com"])
        XCTAssertEqual(e.attendees[0].status, .accepted)
        XCTAssertEqual(e.attendees[0].role, "CHAIR")
        XCTAssertEqual(e.attendees[1].status, .needsAction)
        XCTAssertEqual(e.end, start.addingTimeInterval(45 * 60))
        XCTAssertEqual(e.videoURL, video)
        XCTAssertEqual(meeting(title: "  ").event(organizer: org, attendees: [], fallbackTitle: "Treffen").summary, "Treffen")
    }

    func testMailCarriesRequestPart() throws {
        let e = meeting().event(organizer: org, attendees: [EmailAddress(name: "Bob", address: "bob@example.com")])
        let plain = OutgoingMessage(from: org, to: [EmailAddress(name: "Bob", address: "bob@example.com")], subject: "Planning",
                                    text: "See you there.", html: "<p>See you there.</p>")
        let msg = plain.invitation(for: e)
        XCTAssertEqual(msg.calendar?.method, "REQUEST")
        XCTAssertTrue(msg.text.hasPrefix("Planning\n"))
        XCTAssertTrue(msg.text.contains(video.absoluteString))
        XCTAssertTrue(msg.text.hasSuffix("See you there."))
        XCTAssertTrue(msg.html?.contains(video.absoluteString) == true)

        let raw = String(decoding: msg.render(), as: UTF8.self)
        XCTAssertTrue(raw.contains("text/calendar; charset=utf-8; method=REQUEST"))
        let parsed = ParsedMessage(data: msg.render())
        XCTAssertFalse(parsed.calendarParts.isEmpty) // the text/calendar alternative (and invite.ics)
        let ics = try XCTUnwrap(parsed.calendarParts.first).replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertTrue(ics.contains("METHOD:REQUEST"))
        XCTAssertTrue(ics.contains("ORGANIZER;CN=Ann Org:mailto:ann@example.com"), ics)
        XCTAssertTrue(ics.contains("mailto:bob@example.com"))
        XCTAssertTrue(ics.contains("ATTENDEE"))
        XCTAssertTrue(ics.contains("DTSTART;TZID=Europe/Berlin:20270115T090000"), ics)
        XCTAssertTrue(ics.contains(video.absoluteString))
        XCTAssertTrue(parsed.textBody?.contains("See you there.") == true)

        // Read back as an invite, as the recipient's mail app does.
        let r = ICalendarReader.read(ics)
        XCTAssertEqual(r.method, "REQUEST")
        let got = try XCTUnwrap(r.events.first)
        XCTAssertEqual(got.uid, "meet-1")
        XCTAssertEqual(got.start, start)
        XCTAssertEqual(got.videoURL, video)
        XCTAssertEqual(Set(got.attendees.map(\.email)), ["ann@example.com", "bob@example.com"])
    }

    /// The meeting round-trips through the draft journal (ComposeDraft is Codable).
    func testCodable() throws {
        let data = try JSONEncoder().encode(meeting())
        XCTAssertEqual(try JSONDecoder().decode(MeetingInvite.self, from: data), meeting())
    }

    /// The video link edited in the writer: only full http(s) links with a host are taken.
    func testParseEditedLink() {
        XCTAssertEqual(JitsiRoom.parseLink("  https://vid.example.com/MeetAnn \n")?.absoluteString, "https://vid.example.com/MeetAnn")
        XCTAssertEqual(JitsiRoom.parseLink("http://meet.example.org/room?x=1")?.host, "meet.example.org")
        XCTAssertNil(JitsiRoom.parseLink(""))
        XCTAssertNil(JitsiRoom.parseLink("vid.example.com/room"))
        XCTAssertNil(JitsiRoom.parseLink("https://"))
        XCTAssertNil(JitsiRoom.parseLink("ftp://example.com/room"))
        XCTAssertNil(JitsiRoom.parseLink("https://vid.example.com/my room"))
        XCTAssertNil(JitsiRoom.parseLink("javascript:alert(1)"))
    }

    /// On Radicale as r8 (SMTP not needed): the meeting is stored without CalendarService sending its own invitation
    /// mails, and saving it again (a Send retried after the mail failed) updates the same event.
    func testSavedWithoutSeparateInvitationLive() async throws {
        let r8 = try TestAccount.local("r8@example.com", name: "R8")
        let mail = r8.mail()
        try await r8.withTestCalendar { client, cal in
            let service = r8.calendar(mail)
            let m = MeetingInvite(title: r8.tagged("meeting"), start: Date().addingTimeInterval(3 * 86400), minutes: 30, videoURL: video)
            var e = m.event(organizer: EmailAddress(name: "R8", address: "r8@example.com"),
                            attendees: [EmailAddress(name: "", address: "nobody@example.invalid")])
            e.calendarURL = cal.url
            let saved = try await service.save(e, notify: false)
            let invite = OutgoingMessage(from: EmailAddress(name: "R8", address: "r8@example.com"),
                                         to: [EmailAddress(name: "", address: "nobody@example.invalid")], subject: m.title, text: "Hi").invitation(for: saved)
            XCTAssertTrue(invite.calendar?.ics.contains("UID:\(m.uid)") == true)

            var again = m.event(organizer: EmailAddress(name: "R8", address: "r8@example.com"), attendees: [EmailAddress(name: "", address: "nobody@example.invalid")])
            again.objectURL = saved.objectURL
            again.etag = saved.etag
            again.calendarURL = saved.calendarURL
            again.sequence = saved.sequence
            let resaved = try await service.save(again, notify: false)
            XCTAssertEqual(resaved.objectURL, saved.objectURL)
            let objects = try await client.objects(in: cal, from: m.start.addingTimeInterval(-3600), to: m.end.addingTimeInterval(3600))
            let stored = objects.flatMap(\.events).filter { $0.uid == m.uid }
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.first?.organizer?.address, "r8@example.com")
            XCTAssertEqual(Set(stored.first?.attendees.map(\.email) ?? []), ["r8@example.com", "nobody@example.invalid"])
            XCTAssertEqual(stored.first?.videoURL, video)
        }
    }
}

final class DraftExtrasTests: XCTestCase {
    func testDraftKeepsMeetingAndVideoThroughSaveAndReopen() throws {
        let video = URL(string: "https://vid.rocket.re-cloud.io/MeetAshant")!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = MeetingInvite(title: "Abstimmung", start: start, minutes: 45, videoURL: video, timeZoneID: "Europe/Berlin")
        var m = OutgoingMessage(from: EmailAddress(name: "A", address: "a@example.com"), to: [EmailAddress(name: "", address: "b@example.com")],
                                subject: "Termin", text: JitsiRoom.descriptionBlock(video) + "\nHallo")
        m.extraHeaders = DraftExtras.headers(meeting: meeting, video: video)
        let parsed = ParsedMessage(data: m.render())
        XCTAssertEqual(DraftExtras.meeting(in: parsed.headers), meeting)
        XCTAssertEqual(DraftExtras.video(in: parsed.headers), video)
        XCTAssertEqual(JitsiRoom.stripDescriptionBlock(parsed.textBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "Hallo")
    }

    func testNoExtrasWithoutMeetingOrVideo() {
        XCTAssertTrue(DraftExtras.headers(meeting: nil, video: nil).isEmpty)
        let m = OutgoingMessage(from: EmailAddress(name: "", address: "a@example.com"), to: [], subject: "x", text: "y")
        let parsed = ParsedMessage(data: m.render())
        XCTAssertNil(DraftExtras.meeting(in: parsed.headers))
        XCTAssertNil(DraftExtras.video(in: parsed.headers))
        XCTAssertFalse(String(decoding: m.render(), as: UTF8.self).contains("X-Slyy"))
    }
}
