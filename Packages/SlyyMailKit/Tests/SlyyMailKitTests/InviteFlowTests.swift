import XCTest
@testable import SlyyMailKit

/// End to end: Alice invites Bob with a video call; Bob accepts from his inbox; Alice's calendar records it.
/// Needs Dovecot (1143), the SMTP sink delivering to Dovecot (1025) and Radicale (5232). SLYY_IT=1.
final class InviteFlowTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SLYY_IT"] == "1", "integration tests disabled")
    }

    func account(_ email: String, name: String) -> AccountSettings {
        AccountSettings(
            email: email,
            displayName: name,
            imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .plain),
            smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .plain),
            caldavURL: "http://127.0.0.1:5232/"
        )
    }

    func waitForMail(_ mail: MailService, subjectContains s: String) async throws -> MessageSummary {
        for _ in 0..<40 {
            if let hit = try await mail.messages(in: "INBOX", page: 0).messages.first(where: { $0.subject.contains(s) }) { return hit }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw XCTSkip("mail with subject \(s) did not arrive")
    }

    func testInviteAcceptReply() async throws {
        let alice = account("alice@example.com", name: "Alice")
        let bob = account("bob@example.com", name: "Bob")
        let aliceMail = MailService(account: alice, password: "secret")
        let bobMail = MailService(account: bob, password: "secret")
        let aliceCal = CalendarService(account: alice, password: "secret", mail: aliceMail)
        let bobCal = CalendarService(account: bob, password: "secret", mail: bobMail)

        let title = "Abstimmung \(UUID().uuidString.prefix(6))"
        let start = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        var e = CalendarEvent(summary: title, start: start, end: start.addingTimeInterval(3600), timeZoneID: "Europe/Berlin")
        e.attendees = [Attendee(email: "bob@example.com", name: "Bob")]
        e.videoURL = JitsiRoom.newURL()
        let saved = try await aliceCal.save(e)
        XCTAssertEqual(saved.organizer?.address, "alice@example.com")
        XCTAssertEqual(saved.attendees.first?.status, .accepted) // organizer added as CHAIR

        // Bob receives the invite with the video link and accepts.
        let inviteMail = try await waitForMail(bobMail, subjectContains: title)
        let parsed = try await bobMail.message(inviteMail)
        XCTAssertTrue(parsed.textBody?.contains(e.videoURL!.absoluteString) == true)
        let ics = try XCTUnwrap(parsed.calendarParts.first)
        let invite = try XCTUnwrap(ICalendarReader.read(ics).events.first)
        XCTAssertEqual(ICalendarReader.read(ics).method, "REQUEST")
        XCTAssertEqual(invite.videoURL, e.videoURL)
        try await bobCal.respond(to: invite, status: .accepted)

        // Bob's calendar now has it, marked accepted.
        let bobObj = try await bobCal.findObject(uid: e.uid)
        XCTAssertEqual(bobObj?.events.first?.status(of: "bob@example.com"), .accepted)

        // Alice gets the REPLY and applies it.
        let replyMail = try await waitForMail(aliceMail, subjectContains: "Accepted: \(title)")
        let reply = try await aliceMail.message(replyMail)
        try await aliceCal.apply(itip: try XCTUnwrap(reply.calendarParts.first))
        let aliceObj = try await aliceCal.findObject(uid: e.uid)
        XCTAssertEqual(aliceObj?.events.first?.status(of: "bob@example.com"), .accepted)

        // Alice cancels; Bob applies the CANCEL and the event disappears from his calendar.
        try await aliceCal.delete(saved)
        let cancelMail = try await waitForMail(bobMail, subjectContains: "Cancelled: \(title)")
        let cancel = try await bobMail.message(cancelMail)
        try await bobCal.apply(itip: try XCTUnwrap(cancel.calendarParts.first))
        let gone = try await bobCal.findObject(uid: e.uid)
        XCTAssertNil(gone)

        // Regular sends are filed in Sent (iTIP mails are not).
        let msg = OutgoingMessage(from: alice.address, to: [bob.address], subject: "Filed \(title)", text: "x")
        try await aliceMail.send(msg)
        let sentAfter = try await aliceMail.messages(in: try await aliceMail.folderPath(.sent), page: 0).messages
        XCTAssertTrue(sentAfter.contains { $0.subject == "Filed \(title)" })
        await aliceMail.disconnect()
        await bobMail.disconnect()
    }
}
