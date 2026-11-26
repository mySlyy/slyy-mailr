import XCTest
@testable import SlyyMailKit

/// The exact connection code the Mac/iPhone app uses (URLSessionStreamTask, TLS and STARTTLS),
/// against the real slyy.ai mail server and a public one. No logins. Run on CI with SLYY_NET=1.
final class AppleTLSTests: XCTestCase {
    override func setUp() async throws {
        #if !canImport(Darwin)
        throw XCTSkip("TLS transport is Apple-only")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SLYY_NET"] == "1", "network tests disabled (SLYY_NET=1)")
        #endif
    }

    let slyyMail = "mail.mc1.simplify-erp.de"

    func testIMAPImplicitTLS() async throws {
        let caps = try await IMAPClient(endpoint: ServerEndpoint(host: slyyMail, port: 993, security: .tls)).probe()
        XCTAssertTrue(caps.contains("IMAP4REV1") || caps.contains("IMAP4rev1".uppercased()), "\(caps)")
        XCTAssertTrue(caps.contains("IDLE"))
    }

    func testIMAPStartTLS() async throws {
        let caps = try await IMAPClient(endpoint: ServerEndpoint(host: slyyMail, port: 143, security: .startTLS)).probe()
        XCTAssertFalse(caps.contains("STARTTLS"), "after the upgrade the server stops offering STARTTLS")
        XCTAssertFalse(caps.contains("LOGINDISABLED"), "login must be allowed once encrypted")
    }

    func testSMTPStartTLSAndImplicitTLS() async throws {
        let submission = SMTPClient(endpoint: ServerEndpoint(host: slyyMail, port: 587, security: .startTLS))
        try await submission.connect(user: nil, password: nil)
        await submission.quit()
        let smtps = SMTPClient(endpoint: ServerEndpoint(host: slyyMail, port: 465, security: .tls))
        try await smtps.connect(user: nil, password: nil)
        await smtps.quit()
    }

    func testWrongPasswordIsAReadableError() async throws {
        let c = IMAPClient(endpoint: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls))
        do {
            try await c.connect(user: "slyy-mailr-ci-check@gmail.com", password: "not-a-password")
            XCTFail("login should fail")
        } catch IMAPError.authenticationFailed {
        }
    }

    func testMXLookupForSlyyAI() async {
        let mx = await DNS.mxHosts(for: "slyy.ai")
        XCTAssertEqual(mx.first, slyyMail)
    }

    func testAutoConfigForSlyyAI() async {
        let s = await AutoConfig.discover(email: "someone@slyy.ai")
        XCTAssertEqual(s.imap.host, slyyMail)
        XCTAssertFalse(s.caldavURL.isEmpty, "SOGo calendar should be found")
    }
}
