import XCTest
@testable import SlyyMailKit

/// Gmail's IMAP has no Archive folder (archiving = All Mail) and files sent mail by itself.
final class GmailTests: XCTestCase {
    override func tearDown() { Transport.factory = nil }

    func gmailServer() -> ScriptedServer {
        ScriptedServer(greeting: "* OK Gimap ready") { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return [] }
            let tag = parts[0], cmd = parts[1].uppercased()
            switch cmd {
            case "CAPABILITY": return ["* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE ID CHILDREN X-GM-EXT-1 UIDPLUS MOVE SPECIAL-USE", "\(tag) OK"]
            case "LOGIN": return ["\(tag) OK anna@gmail.com authenticated (Success)"]
            case "LIST": return [
                #"* LIST (\HasNoChildren) "/" "INBOX""#,
                #"* LIST (\HasChildren \Noselect) "/" "[Gmail]""#,
                #"* LIST (\All \HasNoChildren) "/" "[Gmail]/All Mail""#,
                #"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#,
                #"* LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash""#,
                #"* LIST (\Drafts \HasNoChildren) "/" "[Gmail]/Drafts""#,
                "\(tag) OK Success"]
            case "SELECT": return ["* 3 EXISTS", "* OK [UIDVALIDITY 1] UIDs valid", "* OK [UIDNEXT 9] Predicted next UID", "\(tag) OK [READ-WRITE] INBOX selected"]
            default: return ["\(tag) OK Success"]
            }
        }
    }

    func testArchiveMovesToAllMailAndCreatesNoLabel() async throws {
        let server = gmailServer()
        Transport.factory = { _ in server }
        let account = KnownProvider.google.settings(email: "anna@gmail.com")
        let mail = MailService(account: account, password: "app-password")
        let m = MessageSummary(uid: 7, folder: "INBOX", flags: [], date: Date(), size: 1, from: [], to: [], cc: [], subject: "x", messageID: nil, hasAttachments: false, isInvite: false)
        try await mail.archive([m])
        XCTAssertTrue(server.received.contains { $0.hasSuffix(#"UID MOVE 7 "[Gmail]/All Mail""#) }, "\(server.received)")
        XCTAssertFalse(server.received.contains { $0.uppercased().contains(" CREATE ") }, "no stray Archive label")
    }

    func testGmailSettings() {
        let s = KnownProvider.google.settings(email: "anna@gmail.com")
        XCTAssertEqual(s.imap, ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls))
        XCTAssertEqual(s.smtp, ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls))
        XCTAssertTrue(s.serverSavesSent, "no second Sent copy after sending through smtp.gmail.com")
        XCTAssertEqual(s.username, "anna@gmail.com")
    }
}
