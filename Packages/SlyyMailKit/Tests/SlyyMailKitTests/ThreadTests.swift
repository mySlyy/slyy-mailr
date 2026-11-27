import XCTest
@testable import SlyyMailKit

final class ThreadTests: XCTestCase {
    func summary(_ uid: UInt32, _ subject: String, id: String?, inReplyTo: String? = nil, refs: [String]? = nil, minutes: Double, from: String = "a@x.de", seen: Bool = true) -> MessageSummary {
        MessageSummary(uid: uid, folder: "INBOX", flags: seen ? ["\\Seen"] : [], date: Date(timeIntervalSince1970: minutes * 60), size: 1,
                       from: [EmailAddress(address: from)], to: [], cc: [], subject: subject, messageID: id,
                       hasAttachments: false, isInvite: false, inReplyTo: inReplyTo, references: refs)
    }

    /// The inbox has only Ashant's latest mail; my two replies are in Sent. The list must still show a
    /// conversation of 3 (with a fold arrow), but never pull in Sent-only conversations.
    func testInboxConversationIncludesMyRepliesFromSent() {
        func sent(_ uid: UInt32, _ subject: String, id: String, inReplyTo: String?, refs: [String], minutes: Double) -> MessageSummary {
            var m = summary(uid, subject, id: id, inReplyTo: inReplyTo, refs: refs, minutes: minutes, from: "ach@slyy.ai")
            m.folder = "Sent"
            return m
        }
        let inbox = [
            summary(10, "Re: Deployed: PR #471", id: "<3@x>", inReplyTo: "<2@x>", refs: ["<1@x>", "<2@x>"], minutes: 30, from: "ach@slyy.ai", seen: false),
            summary(11, "Slyy.AI Introduction", id: "<r1@x>", minutes: 5, from: "robbie@x.de"),
        ]
        let sentBox = [
            sent(1, "Deployed: PR #471", id: "<1@x>", inReplyTo: nil, refs: [], minutes: 10),
            sent(2, "Re: Deployed: PR #471", id: "<2@x>", inReplyTo: "<1@x>", refs: ["<1@x>"], minutes: 20),
            sent(3, "Unrelated", id: "<u@x>", inReplyTo: nil, refs: [], minutes: 25),
            // A Bcc copy that is in the inbox too: shown once.
            sent(4, "Re: Deployed: PR #471", id: "<3@x>", inReplyTo: "<2@x>", refs: ["<1@x>", "<2@x>"], minutes: 30),
        ]
        let threads = MessageThreads.group(inbox, companions: sentBox)
        XCTAssertEqual(threads.count, 2, "the Sent-only conversation stays out")
        let pr = threads.first { $0.subject == "Deployed: PR #471" }
        XCTAssertEqual(pr?.count, 3)
        XCTAssertEqual(pr?.messages.map(\.uid), [1, 2, 10])
        XCTAssertEqual(pr?.messages.filter { $0.folder == "INBOX" }.count, 1)
        XCTAssertEqual(MessageThreads.group(inbox, companions: []).count, 2)
    }

    func testIDsAndBaseSubject() {
        XCTAssertEqual(MessageThreads.ids(in: "<a@x>  <b@y>\r\n <c@z>"), ["<a@x>", "<b@y>", "<c@z>"])
        XCTAssertEqual(MessageThreads.baseSubject("Re: AW: Fwd: Angebot"), "Angebot")
        XCTAssertEqual(MessageThreads.baseSubject("RE[2]: Planung"), "Planung")
        XCTAssertEqual(MessageThreads.baseSubject("WG: Lieferavis"), "Lieferavis")
    }

    func testGroupsByHeaders() {
        let list = [
            summary(1, "Angebot", id: "<1@x>", minutes: 1, from: "j@schott.de"),
            summary(2, "Re: Angebot", id: "<2@x>", inReplyTo: "<1@x>", refs: ["<1@x>"], minutes: 5, from: "anna@slyy.ai"),
            summary(3, "Re: Angebot", id: "<3@x>", inReplyTo: "<2@x>", refs: ["<1@x>", "<2@x>"], minutes: 9, from: "j@schott.de", seen: false),
            summary(4, "Lieferavis", id: "<4@x>", minutes: 7),
            // missing root (deleted): still one thread via the shared reference
            summary(5, "Re: Planung", id: "<5@x>", inReplyTo: "<gone@x>", refs: ["<gone@x>"], minutes: 2),
            summary(6, "Re: Planung", id: "<6@x>", inReplyTo: "<5@x>", refs: ["<gone@x>", "<5@x>"], minutes: 3),
        ]
        let threads = MessageThreads.group(list)
        XCTAssertEqual(threads.count, 3)
        let angebot = threads[0]
        XCTAssertEqual(angebot.messages.map(\.uid), [1, 2, 3])
        XCTAssertEqual(angebot.subject, "Angebot")
        XCTAssertEqual(angebot.unreadCount, 1)
        XCTAssertEqual(angebot.participants(me: "anna@slyy.ai"), ["j@schott.de", "Me"])
        XCTAssertEqual(threads[1].messages.map(\.uid), [4])
        XCTAssertEqual(threads[2].messages.map(\.uid), [5, 6])
    }

    func testSubjectFallbackOnlyForHeaderlessReplies() {
        let list = [
            summary(1, "Termin", id: "<1@x>", minutes: 1),
            summary(2, "AW: Termin", id: "<2@x>", minutes: 2),           // client stripped headers → joins
            summary(3, "Termin", id: "<3@x>", minutes: 3),               // a new mail with the same subject → separate
        ]
        let threads = MessageThreads.group(list)
        XCTAssertEqual(threads.count, 2)
        XCTAssertTrue(threads.contains { $0.messages.map(\.uid) == [1, 2] })
    }

    func testOldCacheWithoutThreadFieldsStillDecodes() throws {
        let json = #"[{"uid":1,"folder":"INBOX","flags":[],"date":0,"size":1,"from":[],"to":[],"cc":[],"subject":"x","hasAttachments":false,"isInvite":false}]"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let list = try dec.decode([MessageSummary].self, from: Data(json.utf8))
        XCTAssertNil(list[0].references)
    }
}

final class ThreadIntegrationTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SLYY_IT"] == "1", "integration tests disabled")
    }

    func account(_ email: String, _ name: String) -> AccountSettings {
        AccountSettings(email: email, displayName: name, imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .plain), smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .plain))
    }

    func wait(_ mail: MailService, _ subject: String, from: String) async throws -> MessageSummary {
        for _ in 0..<40 {
            if let m = try await mail.messages(in: "INBOX", page: 0).messages.first(where: { $0.subject == subject && $0.from.first?.address == from }) { return m }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw XCTSkip("mail did not arrive")
    }

    func testConversationIncludesMyRepliesFromSent() async throws {
        let alice = MailService(account: account("alice@example.com", "Alice"), password: "secret")
        let bob = MailService(account: account("bob@example.com", "Bob"), password: "secret")
        let topic = "Thread \(UUID().uuidString.prefix(6))"

        try await bob.send(OutgoingMessage(from: EmailAddress(name: "Bob", address: "bob@example.com"), to: [EmailAddress(address: "alice@example.com")], subject: topic, text: "first"))
        let first = try await wait(alice, topic, from: "bob@example.com")

        // Alice replies (filed in her Sent folder).
        let parsedFirst = try await alice.message(first)
        var reply = parsedFirst.draft(.reply, me: EmailAddress(name: "Alice", address: "alice@example.com"))
        reply.text = "second"
        try await alice.send(reply)

        // Bob answers Alice's reply.
        let replyAtBob = try await wait(bob, "Re: \(topic)", from: "alice@example.com")
        var again = try await bob.message(replyAtBob).draft(.reply, me: EmailAddress(name: "Bob", address: "bob@example.com"))
        again.text = "third"
        try await bob.send(again)
        let third = try await wait(alice, "Re: \(topic)", from: "bob@example.com")

        // Grouping in Alice's inbox: both of Bob's mails are one thread.
        let inbox = try await alice.messages(in: "INBOX", page: 0).messages.filter { $0.subject.contains(topic) }
        XCTAssertEqual(MessageThreads.group(inbox).count, 1)

        // The conversation view includes Alice's own reply from Sent, in order.
        let convo = try await alice.conversation(of: third)
        XCTAssertEqual(convo.count, 3)
        XCTAssertEqual(convo.map { $0.from.first?.address }, ["bob@example.com", "alice@example.com", "bob@example.com"])
        let sent = try await alice.folderPath(.sent)
        XCTAssertEqual(convo[1].folder, sent)
        await alice.disconnect()
        await bob.disconnect()
    }
}
