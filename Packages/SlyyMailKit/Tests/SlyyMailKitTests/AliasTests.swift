import XCTest
@testable import SlyyMailKit

final class AliasTests: XCTestCase {
    var account: AccountSettings {
        var a = AccountSettings(email: "anna@slyy.ai", displayName: "Anna Weber",
                                imap: ServerEndpoint(host: "h", port: 993, security: .tls), smtp: ServerEndpoint(host: "h", port: 587, security: .startTLS))
        a.aliases = [SenderIdentity(name: "Slyy Info", email: "info@slyy.ai", signature: "Slyy Team"), SenderIdentity(email: "rechnung@slyy.ai"), SenderIdentity(email: "")]
        return a
    }

    func testDefaultSender() {
        var a = account
        XCTAssertEqual(a.defaultIdentity.email, "anna@slyy.ai", "no default: the account address")
        a.defaultSender = "INFO@slyy.ai"
        XCTAssertEqual(a.defaultIdentity.email, "info@slyy.ai")
        XCTAssertEqual(a.defaultIdentity.signature, "Slyy Team")
        a.defaultSender = "gone@slyy.ai"
        XCTAssertEqual(a.defaultIdentity.email, "anna@slyy.ai", "a removed alias falls back to the account address")

        a.defaultSender = "info@slyy.ai"
        let direct = ParsedMessage(data: Data("From: k@x.de\r\nTo: anna@slyy.ai\r\nSubject: R\r\n\r\nx\r\n".utf8))
        XCTAssertEqual(a.identity(forReplyTo: direct).email, "anna@slyy.ai", "mail to the account address is answered from it")
        let toRechnung = ParsedMessage(data: Data("From: k@x.de\r\nTo: rechnung@slyy.ai\r\nSubject: R\r\n\r\nx\r\n".utf8))
        XCTAssertEqual(a.identity(forReplyTo: toRechnung).email, "rechnung@slyy.ai", "the addressed alias beats the default")
        let list = ParsedMessage(data: Data("From: k@x.de\r\nTo: team@lists.x.de\r\nDelivered-To: anna@slyy.ai\r\nSubject: R\r\n\r\nx\r\n".utf8))
        XCTAssertEqual(a.identity(forReplyTo: list).email, "info@slyy.ai", "list mail that names none of my addresses: the default")

        // Settings saved before 0.3.1 have no defaultSender.
        let old = try! JSONDecoder().decode(AccountSettings.self, from: JSONEncoder().encode(account))
        XCTAssertNil(old.defaultSender)
    }

    func testIdentitiesAndMine() {
        XCTAssertEqual(account.identities.map(\.email), ["anna@slyy.ai", "info@slyy.ai", "rechnung@slyy.ai"], "blank aliases are ignored")
        XCTAssertTrue(account.isMine("INFO@slyy.ai"))
        XCTAssertFalse(account.isMine("heiko@slyy.ai"))
    }

    func testReplyComesFromTheAddressTheMailWasSentTo() {
        let toInfo = ParsedMessage(data: Data("From: Kunde <k@x.de>\r\nTo: info@slyy.ai\r\nSubject: Frage\r\nMessage-ID: <q@x>\r\n\r\nHallo\r\n".utf8))
        XCTAssertEqual(account.identity(forReplyTo: toInfo).email, "info@slyy.ai")
        let bcc = ParsedMessage(data: Data("From: k@x.de\r\nTo: list@x.de\r\nDelivered-To: rechnung@slyy.ai\r\nSubject: R\r\n\r\nx\r\n".utf8))
        XCTAssertEqual(account.identity(forReplyTo: bcc).email, "rechnung@slyy.ai", "Delivered-To catches Bcc/list mail")
        let direct = ParsedMessage(data: Data("From: k@x.de\r\nTo: anna@slyy.ai\r\nSubject: R\r\n\r\nx\r\n".utf8))
        XCTAssertEqual(account.identity(forReplyTo: direct).email, "anna@slyy.ai")
    }

    func testReplyAllLeavesOutAllMyAddresses() {
        let m = ParsedMessage(data: Data("From: Heiko <heiko@slyy.ai>\r\nTo: info@slyy.ai, anna@slyy.ai, bob@x.de\r\nCc: rechnung@slyy.ai, carol@x.de\r\nSubject: Plan\r\nMessage-ID: <p@x>\r\n\r\nx\r\n".utf8))
        let id = account.identity(forReplyTo: m)
        let r = m.draft(.replyAll, me: id.address, myAddresses: account.myAddresses)
        XCTAssertEqual(r.from.address, "info@slyy.ai")
        XCTAssertEqual(r.to.map(\.address), ["heiko@slyy.ai", "bob@x.de"])
        XCTAssertEqual(r.cc.map(\.address), ["carol@x.de"])
    }

    func testReplyAllToMyOwnSentMessageKeepsRecipients() {
        let mine = ParsedMessage(data: Data("From: info@slyy.ai\r\nTo: k@x.de\r\nSubject: Angebot\r\n\r\nx\r\n".utf8))
        let r = mine.draft(.replyAll, me: EmailAddress(address: "info@slyy.ai"), myAddresses: account.myAddresses)
        XCTAssertEqual(r.to.map(\.address), ["k@x.de"], "replying to my own mail goes to its recipients")
    }

    func testSettingsFromOlderVersionsStillLoad() throws {
        var old = account
        old.aliases = nil
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "aliases")
        let decoded = try JSONDecoder().decode(AccountSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.identities.count, 1)
    }

    func testParticipantsTreatAliasesAsMe() {
        let s1 = MessageSummary(uid: 1, folder: "INBOX", flags: [], date: Date(), size: 1, from: [EmailAddress(name: "Kunde K", address: "k@x.de")], to: [], cc: [], subject: "a", messageID: "<1@x>", hasAttachments: false, isInvite: false)
        let s2 = MessageSummary(uid: 2, folder: "Sent", flags: [], date: Date().addingTimeInterval(5), size: 1, from: [EmailAddress(address: "info@slyy.ai")], to: [], cc: [], subject: "Re: a", messageID: "<2@x>", hasAttachments: false, isInvite: false, inReplyTo: "<1@x>", references: ["<1@x>"])
        let s3 = MessageSummary(uid: 3, folder: "Sent", flags: [], date: Date().addingTimeInterval(9), size: 1, from: [EmailAddress(address: "anna@slyy.ai")], to: [], cc: [], subject: "Re: a", messageID: "<3@x>", hasAttachments: false, isInvite: false, inReplyTo: "<2@x>", references: ["<1@x>", "<2@x>"])
        let t = MessageThreads.group([s1, s2, s3])[0]
        XCTAssertEqual(t.participants(mine: account.myAddresses), ["Kunde", "Me"])
    }
}

final class AliasIntegrationTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SLYY_IT"] == "1", "integration tests disabled")
    }

    func testSendFromAliasUsesAliasAsSenderAndEnvelope() async throws {
        var bob = AccountSettings(email: "bob@example.com", displayName: "Bob", imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .plain), smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .plain))
        bob.aliases = [SenderIdentity(name: "Example Sales", email: "sales@example.com")]
        let mail = MailService(account: bob, password: "secret")
        let subject = "Alias \(UUID().uuidString.prefix(6))"
        try await mail.send(OutgoingMessage(from: bob.identities[1].address, to: [EmailAddress(address: "alice@example.com")], subject: subject, text: "hi"))
        let alice = MailService(account: AccountSettings(email: "alice@example.com", imap: bob.imap, smtp: bob.smtp), password: "secret")
        var hit: MessageSummary?
        for _ in 0..<40 where hit == nil {
            hit = try await alice.messages(in: "INBOX", page: 0).messages.first { $0.subject == subject }
            if hit == nil { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        let m = try XCTUnwrap(hit)
        XCTAssertEqual(m.from.first?.address, "sales@example.com")
        XCTAssertEqual(m.from.first?.name, "Example Sales")
        let raw = String(decoding: try await alice.rawMessage(m), as: UTF8.self)
        XCTAssertTrue(raw.contains("Return-Path: <sales@example.com>"), "envelope sender is the alias")
        await mail.disconnect()
        await alice.disconnect()
    }
}
