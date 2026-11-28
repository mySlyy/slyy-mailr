import XCTest
@testable import SlyyMailKit

/// End to end on the local stand-ins: Alice invites Bob with a video call; Bob accepts from his inbox;
/// Alice's calendar records it; Alice cancels. (SOGoTests runs the same flow against the real mailcow SOGo.)
final class InviteFlowTests: XCTestCase {
    func testInviteAcceptReply() async throws {
        let alice = try TestAccount.local("alice@example.com", name: "Alice")
        let bob = try TestAccount.local("bob@example.com", name: "Bob")
        let aliceMail = alice.mail(), bobMail = bob.mail()
        let aliceCal = alice.calendar(aliceMail), bobCal = bob.calendar(bobMail)

        let title = alice.tagged("Abstimmung")
        let start = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        var e = CalendarEvent(summary: title, start: start, end: start.addingTimeInterval(3600), timeZoneID: "Europe/Berlin")
        e.attendees = [Attendee(email: "bob@example.com", name: "Bob")]
        e.videoURL = JitsiRoom.newURL()
        let saved = try await aliceCal.save(e)
        XCTAssertEqual(saved.organizer?.address, "alice@example.com")
        XCTAssertEqual(saved.attendees.first?.status, .accepted) // organizer added as CHAIR

        // Bob receives the invite with the video link and accepts.
        let inviteMail = try await TestAccount.waitForMail(bobMail, subjectContains: title)[0]
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
        let replyMail = try await TestAccount.waitForMail(aliceMail, subjectContains: "Accepted: \(title)")[0]
        let reply = try await aliceMail.message(replyMail)
        try await aliceCal.apply(itip: try XCTUnwrap(reply.calendarParts.first), from: try XCTUnwrap(reply.from.first).address)
        let aliceObj = try await aliceCal.findObject(uid: e.uid)
        XCTAssertEqual(aliceObj?.events.first?.status(of: "bob@example.com"), .accepted)

        // Alice cancels; Bob applies the CANCEL and the event disappears from his calendar.
        try await aliceCal.delete(saved)
        let cancelMail = try await TestAccount.waitForMail(bobMail, subjectContains: "Cancelled: \(title)")[0]
        let cancel = try await bobMail.message(cancelMail)
        try await bobCal.apply(itip: try XCTUnwrap(cancel.calendarParts.first), from: try XCTUnwrap(cancel.from.first).address)
        let gone = try await bobCal.findObject(uid: e.uid)
        XCTAssertNil(gone)

        // Regular sends are filed in Sent (iTIP mails are not).
        let filed = alice.tagged("Filed")
        try await aliceMail.send(OutgoingMessage(from: alice.address, to: [bob.address], subject: filed, text: "x"))
        let sentAfter = try await aliceMail.messages(in: try await aliceMail.folderPath(.sent), page: 0).messages
        XCTAssertTrue(sentAfter.contains { $0.subject == filed })

        await alice.cleanUp(aliceMail)
        await bob.cleanUp(bobMail)
        await aliceMail.disconnect()
        await bobMail.disconnect()
    }
}
