import XCTest
@testable import SlyyMailKit

/// Who an integration test runs as, and the helpers every such test needs. Two targets, same code:
/// - `.local`: the stand-in servers in Tools/dev-servers (Dovecot, SMTP sink, Radicale), enabled with SLYY_IT=1;
/// - `.mailcow`: the real mailbox from SLYY_SOGO_USER / SLYY_SOGO_PASSWORD (a mailcow app password), manual runs only.
/// Every run has a token: put it into subjects and calendar names, and `cleanUp` removes what the run created.
struct TestAccount: Sendable {
    enum Target: Sendable { case local, mailcow }

    let target: Target
    var settings: AccountSettings
    let password: String
    /// Unique per test run; part of every subject and calendar name this run creates.
    let token: String

    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static let runToken = "T-\(env["SLYY_SOGO_RUN"] ?? String(UUID().uuidString.prefix(6)))"

    // MARK: Accounts

    /// A user on the local stand-in servers (all users share the password "secret"). Skips without SLYY_IT=1.
    static func local(_ email: String = "alice@example.com", name: String = "") throws -> TestAccount {
        try XCTSkipUnless(env["SLYY_IT"] == "1", "integration tests disabled (set SLYY_IT=1, see Tools/dev-servers)")
        let imap = ServerEndpoint(host: "127.0.0.1", port: Int(env["SLYY_IMAP_PORT"] ?? "1143") ?? 1143, security: .plain)
        let smtp = ServerEndpoint(host: "127.0.0.1", port: Int(env["SLYY_SMTP_PORT"] ?? "1025") ?? 1025, security: .plain)
        let caldav = env["SLYY_CALDAV_URL"] ?? "http://127.0.0.1:5232/"
        return TestAccount(target: .local, settings: AccountSettings(email: email, displayName: name, imap: imap, smtp: smtp, caldavURL: caldav),
                           password: "secret", token: runToken)
    }

    /// The real mailcow mailbox, its servers found the way account setup finds them. Skips without the secrets.
    static func mailcow() async throws -> TestAccount {
        guard let user = env["SLYY_SOGO_USER"], !user.isEmpty, let pw = env["SLYY_SOGO_PASSWORD"], !pw.isEmpty else {
            throw XCTSkip("mailcow test not configured (SLYY_SOGO_USER / SLYY_SOGO_PASSWORD)")
        }
        var s = await AutoConfig.discover(email: user)
        s.username = user
        s.displayName = "Slyy Mailr CI"
        return TestAccount(target: .mailcow, settings: s, password: pw, token: runToken)
    }

    /// The same login answering as another of its addresses (an alias delivering to the same mailbox).
    func asAddress(_ email: String) -> TestAccount {
        var copy = self
        copy.settings.email = email
        return copy
    }

    // MARK: Services

    var address: EmailAddress { settings.address }
    func mail() -> MailService { MailService(account: settings, password: password) }
    func calendar(_ mail: MailService) -> CalendarService { CalendarService(account: settings, password: password, mail: mail) }

    func caldav() throws -> CalDAVClient {
        CalDAVClient(baseURL: try XCTUnwrap(URL(string: settings.caldavURL), "no CalDAV address"), username: settings.username, password: password)
    }

    func imap() async throws -> IMAPClient {
        let c = IMAPClient(endpoint: settings.imap)
        try await c.connect(user: settings.username, password: password)
        return c
    }

    /// "<token> <text>": subjects and names this run creates (and `cleanUp` finds).
    func tagged(_ text: String) -> String { "\(token) \(text)" }

    // MARK: Waiting and cleaning up

    /// Mails in `folder` that match, once at least `count` are there (polls up to `timeout` seconds).
    /// With `settle`, waits a moment more for late copies (e.g. a server's own invitation).
    @discardableResult
    static func waitForMail(_ mail: MailService, folder: String = "INBOX", atLeast count: Int = 1, timeout: TimeInterval = 20,
                            settle: TimeInterval = 0, where match: @escaping @Sendable (MessageSummary) -> Bool) async throws -> [MessageSummary] {
        let deadline = Date().addingTimeInterval(timeout)
        var hits: [MessageSummary] = []
        repeat {
            hits = ((try? await mail.messages(in: folder, page: 0).messages) ?? []).filter(match)
            if hits.count >= count {
                if settle > 0 {
                    try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                    hits = ((try? await mail.messages(in: folder, page: 0).messages) ?? []).filter(match)
                }
                return hits
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        XCTFail("no mail matching the test arrived in \(folder) within \(Int(timeout)) s")
        throw XCTSkip("mail did not arrive")
    }

    /// Mails whose subject contains `text`.
    @discardableResult
    static func waitForMail(_ mail: MailService, subjectContains text: String, atLeast count: Int = 1, timeout: TimeInterval = 20, settle: TimeInterval = 0) async throws -> [MessageSummary] {
        try await waitForMail(mail, atLeast: count, timeout: timeout, settle: settle) { $0.subject.contains(text) }
    }

    /// A calendar made for this run, deleted afterwards even when `body` fails.
    func withTestCalendar(_ body: (CalDAVClient, CalDAVCalendar) async throws -> Void) async throws {
        let client = try caldav()
        let cal = try await client.makeCalendar(name: tagged("calendar"))
        do {
            try await body(client, cal)
        } catch {
            try? await client.deleteCalendar(cal)
            throw error
        }
        try await client.deleteCalendar(cal)
    }

    /// Permanently removes this run's mails (subject contains the token) from Inbox, Sent, Trash and Drafts.
    @discardableResult
    func cleanUp(_ mail: MailService) async -> Int {
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
