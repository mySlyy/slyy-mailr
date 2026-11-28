import XCTest
@testable import SlyyMailKit

/// Live tests against local dev servers (see Tools/dev-servers/README.md).
/// Run with SLYY_IT=1; skipped otherwise (e.g. on CI without servers).
final class MailIntegrationTests: XCTestCase {
    var imapEndpoint: ServerEndpoint { (try? TestAccount.local().settings.imap) ?? ServerEndpoint(host: "127.0.0.1", port: 1143, security: .plain) }
    var smtpEndpoint: ServerEndpoint { (try? TestAccount.local().settings.smtp) ?? ServerEndpoint(host: "127.0.0.1", port: 1025, security: .plain) }

    override func setUp() async throws {
        _ = try TestAccount.local() // skips without SLYY_IT=1
    }

    func login(_ user: String = "alice@example.com") async throws -> IMAPClient {
        let c = IMAPClient(endpoint: imapEndpoint)
        try await c.connect(user: user, password: "secret")
        return c
    }

    func testLoginFailure() async throws {
        let c = IMAPClient(endpoint: imapEndpoint)
        do {
            try await c.connect(user: "alice@example.com", password: "wrong")
            XCTFail("expected failure")
        } catch IMAPError.authenticationFailed {
        }
    }

    func testFoldersAndSpecialUse() async throws {
        let c = try await login()
        let name = "Test-Ä-\(Int.random(in: 1000...9999))"
        try await c.createFolder(name)
        let folders = try await c.listFolders()
        XCTAssertEqual(folders.first?.specialUse, .inbox)
        XCTAssertNotNil(folders.first { $0.specialUse == .sent })
        XCTAssertNotNil(folders.first { $0.specialUse == .drafts })
        let created = try XCTUnwrap(folders.first { $0.path == name })
        try await c.renameFolder(created.serverPath, to: name + "-x")
        try await c.deleteFolder(ModifiedUTF7.encode(name + "-x"))
        let after = try await c.listFolders()
        XCTAssertFalse(after.contains { $0.path.hasPrefix(name) })
        await c.logout()
    }

    func testSendReceiveFlagsMoveSearch() async throws {
        let subject = "IT \(UUID().uuidString.prefix(8)) Grüße"
        let msg = OutgoingMessage(
            from: EmailAddress(name: "Bob", address: "bob@example.com"),
            to: [EmailAddress(name: "Alice", address: "alice@example.com")],
            subject: subject,
            text: "Hallo Alice\n.\nZeile mit Punkt",
            attachments: [OutgoingAttachment(filename: "notiz.txt", mimeType: "text/plain", data: Data("hi".utf8))]
        )
        let smtp = SMTPClient(endpoint: smtpEndpoint)
        try await smtp.connect(user: "bob@example.com", password: "secret")
        try await smtp.send(from: msg.from.address, recipients: msg.envelopeRecipients, data: msg.render())
        await smtp.quit()

        let c = try await login()
        var found: MessageSummary?
        for _ in 0..<20 {
            let page = try await c.summaries(folder: "INBOX", page: 0)
            found = page.messages.first { $0.subject == subject }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let s = try XCTUnwrap(found)
        XCTAssertFalse(s.isSeen)
        XCTAssertTrue(s.hasAttachments)
        XCTAssertEqual(s.from.first?.address, "bob@example.com")

        let raw = try await c.fetchMessage(folder: "INBOX", uid: s.uid)
        let parsed = ParsedMessage(data: raw)
        XCTAssertEqual(parsed.textBody, "Hallo Alice\r\n.\r\nZeile mit Punkt")
        XCTAssertEqual(parsed.attachments.first?.filename, "notiz.txt")

        try await c.setFlags(folder: "INBOX", uids: [s.uid], add: ["\\Seen", "\\Flagged"])
        let again = try await c.summaries(folder: "INBOX", uids: [s.uid])
        XCTAssertTrue(again.first?.isSeen == true && again.first?.isFlagged == true)

        let hits = try await c.search(folder: "INBOX", text: String(subject.split(separator: " ")[1]))
        XCTAssertEqual(hits.map(\.uid), [s.uid])
        let umlaut = try await c.search(folder: "INBOX", text: "Grüße")
        XCTAssertTrue(umlaut.contains { $0.uid == s.uid })

        try await c.move(folder: "INBOX", uids: [s.uid], to: "Archive")
        let archived = try await c.summaries(folder: "Archive", page: 0)
        let moved = try XCTUnwrap(archived.messages.first { $0.subject == subject })
        try await c.expunge(folder: "Archive", uids: [moved.uid])
        await c.logout()
    }

    func testAppendDraft() async throws {
        let c = try await login()
        let msg = OutgoingMessage(from: EmailAddress(address: "alice@example.com"), to: [], subject: "Draft \(UUID())", text: "wip")
        let uid = try await c.append(folder: "Drafts", message: msg.render(), flags: ["\\Draft", "\\Seen"])
        XCTAssertNotNil(uid)
        let list = try await c.summaries(folder: "Drafts", uids: [uid!])
        XCTAssertEqual(list.first?.subject, msg.subject)
        XCTAssertTrue(list.first?.isDraft == true)
        try await c.expunge(folder: "Drafts", uids: [uid!])
        await c.logout()
    }

    func testIdleWakesOnNewMail() async throws {
        let watcher = try await login()
        let idle = Task { try await watcher.idle(folder: "INBOX", timeout: 20) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let other = try await login()
        let m = OutgoingMessage(from: EmailAddress(address: "alice@example.com"), to: [], subject: "idle \(UUID())", text: "x")
        let uid = try await other.append(folder: "INBOX", message: m.render())
        let start = Date()
        let result = try await idle.value
        XCTAssertEqual(result, .changed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        try await other.expunge(folder: "INBOX", uids: [uid!])
        await other.logout()
        await watcher.logout()
    }

    func testIdleStopsOnTimeout() async throws {
        let c = try await login()
        let r = try await c.idle(folder: "INBOX", timeout: 1)
        XCTAssertEqual(r, .timeout)
        // Connection must still be usable afterwards.
        _ = try await c.listFolders()
        await c.logout()
    }
}
