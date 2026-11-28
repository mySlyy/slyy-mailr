import XCTest
@testable import SlyyMailKit

final class KnownProviderTests: XCTestCase {
    func testKnownProviders() {
        XCTAssertEqual(KnownProvider.detect(email: "anna@gmail.com")?.kind, .google)
        XCTAssertNil(KnownProvider.detect(email: "anna@yahoo.de"), "Yahoo is not supported specially")
        XCTAssertEqual(KnownProvider.detect(email: "anna@firma.de", mxHosts: ["aspmx.l.google.com."])?.kind, .google, "Google Workspace by MX")
        XCTAssertTrue(KnownProvider.isWorkspace("anna@firma.de"))
        XCTAssertFalse(KnownProvider.isWorkspace("anna@gmail.com"))
        var workspace = AccountSettings(email: "anna@firma.de", imap: KnownProvider.google.imap, smtp: KnownProvider.google.smtp)
        XCTAssertEqual(KnownProvider.forSettings(workspace)?.kind, .google, "a Workspace domain is known by its servers")
        XCTAssertTrue(workspace.serverSavesSent, "Gmail files sent mail itself")
        workspace.smtp.host = "mail.firma.de"
        XCTAssertFalse(workspace.serverSavesSent)
        XCTAssertNil(KnownProvider.detect(email: "anna@slyy.ai", mxHosts: ["mail.mc1.simplify-erp.de"]))
        let s = KnownProvider.google.settings(email: "anna@gmail.com")
        XCTAssertEqual(s.imap.host, "imap.gmail.com")
        XCTAssertEqual(s.caldavURL, "", "Google calendars need OAuth: the calendar stays off with an app password")
        XCTAssertTrue(KnownProvider.needsAppPassword("[ALERT] Application-specific password required: https://support.google.com/mail/accounts/answer/185833"))
        XCTAssertFalse(KnownProvider.needsAppPassword("Mailbox full"))
    }
}

/// An in-memory server: every complete line the client writes goes to `handler`, whose replies the client reads.
final class ScriptedServer: ByteStream, @unchecked Sendable {
    var readTimeout: TimeInterval = 5
    private let lock = NSLock()
    private var outbox = Data()
    private var inbox = Data()
    private(set) var received: [String] = []
    let handler: (String) -> [String]

    init(greeting: String, handler: @escaping (String) -> [String]) {
        self.handler = handler
        outbox = Data((greeting + "\r\n").utf8)
    }

    func read(maxLength: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(readTimeout)
        while Date() < deadline {
            let chunk: Data? = lock.withLock {
                guard !outbox.isEmpty else { return nil }
                let c = outbox.prefix(maxLength)
                outbox = Data(outbox.dropFirst(c.count))
                return Data(c)
            }
            if let chunk { return chunk }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TransportError.timeout
    }

    func write(_ data: Data) async throws {
        lock.withLock { feed(data) }
    }

    private func feed(_ data: Data) {
        inbox.append(data)
        while let nl = inbox.firstIndex(of: 0x0A) {
            var line = String(decoding: inbox[inbox.startIndex..<nl], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            inbox = Data(inbox[(nl + 1)...])
            received.append(line)
            for r in handler(line) { outbox.append(Data((r + "\r\n").utf8)) }
        }
    }

    /// Sends lines the handler held back (e.g. a delayed reply).
    func push(_ lines: [String]) {
        lock.withLock { for r in lines { outbox.append(Data((r + "\r\n").utf8)) } }
    }

    func startTLS() async throws {}
    func close() {}
}

final class XOAUTH2LoginTests: XCTestCase {
    let good = XOAUTH2.initialResponse(user: "anna@example.com", accessToken: "GOOD")
    let endpoint = ServerEndpoint(host: "imap.test", port: 143, security: .plain)

    override func tearDown() { Transport.factory = nil }

    func testXOAUTH2InitialResponse() {
        XCTAssertEqual(XOAUTH2.initialResponse(user: "anna@example.com", accessToken: "tok"), "dXNlcj1hbm5hQGV4YW1wbGUuY29tAWF1dGg9QmVhcmVyIHRvawEB")
    }

    func imapServer() -> ScriptedServer {
        var authTag = ""
        return ScriptedServer(greeting: "* OK ready") { [good] line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            if line.isEmpty { return ["\(authTag) NO [AUTHENTICATIONFAILED] Invalid credentials"] }
            guard parts.count >= 2 else { return [] }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "CAPABILITY": return ["* CAPABILITY IMAP4rev1 SASL-IR AUTH=XOAUTH2", "\(tag) OK done"]
            case "AUTHENTICATE":
                authTag = tag
                // Failure arrives as a base64 JSON challenge; the client must answer with an empty line.
                return line.hasSuffix(good) ? ["\(tag) OK authenticated"] : ["+ eyJzdGF0dXMiOiI0MDAifQ=="]
            case "LOGOUT": return ["* BYE", "\(tag) OK bye"]
            default: return ["\(tag) OK"]
            }
        }
    }

    func testIMAPLogsInWithXOAUTH2() async throws {
        let server = imapServer()
        Transport.factory = { _ in server }
        let c = IMAPClient(endpoint: endpoint)
        try await c.connect(user: "anna@example.com", password: "GOOD", oauth: true)
        XCTAssertTrue(server.received.contains { $0.contains("AUTHENTICATE XOAUTH2 \(good)") })
        XCTAssertFalse(server.received.contains { $0.contains(" LOGIN ") }, "no password LOGIN for OAuth accounts")
    }

    func testIMAPBadTokenFailsInsteadOfHanging() async throws {
        let server = imapServer()
        Transport.factory = { _ in server }
        let c = IMAPClient(endpoint: endpoint)
        do {
            try await c.connect(user: "anna@example.com", password: "EXPIRED", oauth: true)
            XCTFail("expected authentication failure")
        } catch IMAPError.authenticationFailed(let text) {
            XCTAssertTrue(text.contains("Invalid credentials"))
        }
    }

    func testSMTPLogsInWithXOAUTH2() async throws {
        let good = self.good
        func makeServer() -> ScriptedServer {
            ScriptedServer(greeting: "220 smtp.test ready") { line in
                if line.hasPrefix("EHLO") { return ["250-smtp.test", "250 AUTH PLAIN LOGIN XOAUTH2"] }
                if line.hasPrefix("AUTH XOAUTH2") { return line.hasSuffix(good) ? ["235 2.7.0 Accepted"] : ["334 eyJzdGF0dXMiOiI0MDAifQ=="] }
                if line.isEmpty { return ["535 5.7.8 Authentication failed"] }
                if line == "QUIT" { return ["221 bye"] }
                return ["250 OK"]
            }
        }
        var server = makeServer()
        Transport.factory = { _ in server }
        let ok = SMTPClient(endpoint: ServerEndpoint(host: "smtp.test", port: 587, security: .plain))
        try await ok.connect(user: "anna@example.com", password: "GOOD", oauth: true)
        XCTAssertTrue(server.received.contains("AUTH XOAUTH2 \(good)"))
        server = makeServer() // a new connection gets a new greeting
        let bad = SMTPClient(endpoint: ServerEndpoint(host: "smtp.test", port: 587, security: .plain))
        do {
            try await bad.connect(user: "anna@example.com", password: "EXPIRED", oauth: true)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("535"), "\(error)")
        }
    }
}
