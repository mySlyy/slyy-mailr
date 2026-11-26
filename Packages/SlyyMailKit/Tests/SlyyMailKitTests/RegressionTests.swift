import XCTest
@testable import SlyyMailKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

/// Serves canned HTTP responses for autoconfig tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = "\(url.host ?? "")\(url.path)"
        guard let (status, body) = StubURLProtocol.routes[key] else {
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/xml"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AutoConfigRegressionTests: XCTestCase {
    let mailcowConfig = """
    <?xml version="1.0"?><clientConfig version="1.1"><emailProvider id="mail.mc1.simplify-erp.de"><domain>%EMAILDOMAIN%</domain>
    <incomingServer type="imap"><hostname>mail.mc1.simplify-erp.de</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username></incomingServer>
    <incomingServer type="imap"><hostname>mail.mc1.simplify-erp.de</hostname><port>143</port><socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username></incomingServer>
    <outgoingServer type="smtp"><hostname>mail.mc1.simplify-erp.de</hostname><port>465</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username></outgoingServer>
    <outgoingServer type="smtp"><hostname>mail.mc1.simplify-erp.de</hostname><port>587</port><socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username></outgoingServer>
    </emailProvider></clientConfig>
    """

    var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override func tearDown() {
        AutoConfig.mxLookup = { await DNS.mxHosts(for: $0) }
        AutoConfig.davProbe = { await AutoConfig.probeDAV($0, session: $1) }
        StubURLProtocol.routes = [:]
    }

    /// slyy.ai today: autoconfig.slyy.ai has a wrong certificate, imap.slyy.ai is the web server,
    /// mail is on the MX host, which serves autoconfig and SOGo CalDAV.
    func testSlyyAIUsesMXHostNotWildcardDomain() async {
        StubURLProtocol.routes = ["mail.mc1.simplify-erp.de/mail/config-v1.1.xml": (200, mailcowConfig)]
        AutoConfig.mxLookup = { domain in domain == "slyy.ai" ? ["mail.mc1.simplify-erp.de"] : [] }
        AutoConfig.davProbe = { url, _ in url.host == "mail.mc1.simplify-erp.de" && url.path == "/.well-known/caldav" }
        let s = await AutoConfig.discover(email: "anna@slyy.ai", session: session)
        XCTAssertEqual(s.imap, ServerEndpoint(host: "mail.mc1.simplify-erp.de", port: 993, security: .tls))
        XCTAssertEqual(s.smtp.host, "mail.mc1.simplify-erp.de")
        XCTAssertNotEqual(s.smtp.security, .plain)
        XCTAssertEqual(s.username, "anna@slyy.ai")
        XCTAssertEqual(s.caldavURL, "https://mail.mc1.simplify-erp.de/")
    }

    func testDomainAutoconfigWinsWhenItWorks() async {
        StubURLProtocol.routes = ["autoconfig.example.org/mail/config-v1.1.xml": (200, mailcowConfig.replacingOccurrences(of: "mail.mc1.simplify-erp.de", with: "mx.example.org"))]
        AutoConfig.mxLookup = { _ in XCTFail("MX lookup not needed"); return [] }
        AutoConfig.davProbe = { _, _ in false }
        let s = await AutoConfig.discover(email: "x@example.org", session: session)
        XCTAssertEqual(s.imap.host, "mx.example.org")
        XCTAssertEqual(s.caldavURL, "", "no CalDAV found means calendar off, not a broken URL")
    }

    func testGuessUsesMXHostWhenNoAutoconfig() async {
        AutoConfig.mxLookup = { _ in ["mx1.provider.net"] }
        AutoConfig.davProbe = { url, _ in url.path.hasPrefix("/SOGo/dav") }
        let s = await AutoConfig.discover(email: "x@example.org", session: session)
        XCTAssertEqual(s.imap, ServerEndpoint(host: "mx1.provider.net", port: 993, security: .tls))
        XCTAssertEqual(s.smtp, ServerEndpoint(host: "mx1.provider.net", port: 587, security: .startTLS))
        XCTAssertEqual(s.caldavURL, "https://example.org/SOGo/dav/")
    }

    func testParseMX() {
        // preference 10, "mail.mc1.simplify-erp.de"
        var bytes: [UInt8] = [0, 10]
        for label in ["mail", "mc1", "simplify-erp", "de"] { bytes.append(UInt8(label.count)); bytes += Array(label.utf8) }
        bytes.append(0)
        XCTAssertEqual(DNS.parseMX(bytes)?.0, 10)
        XCTAssertEqual(DNS.parseMX(bytes)?.1, "mail.mc1.simplify-erp.de")
        XCTAssertNil(DNS.parseMX([0, 1]))
    }
}

final class SmallRegressionTests: XCTestCase {
    func testInviteDetection() {
        XCTAssertTrue(IMAPClient.looksLikeInvite(contentType: HeaderValue("multipart/mixed; boundary=x"), contentClass: nil, subject: "Invitation: Planung"))
        XCTAssertTrue(IMAPClient.looksLikeInvite(contentType: HeaderValue("multipart/alternative"), contentClass: "urn:content-classes:calendarmessage", subject: "Wochenfazit"))
        XCTAssertTrue(IMAPClient.looksLikeInvite(contentType: HeaderValue("text/calendar; method=REQUEST"), contentClass: nil, subject: "x"))
        XCTAssertTrue(IMAPClient.looksLikeInvite(contentType: HeaderValue("multipart/mixed"), contentClass: nil, subject: "Einladung: ERP Wochenfazit"))
        XCTAssertFalse(IMAPClient.looksLikeInvite(contentType: HeaderValue("multipart/mixed"), contentClass: nil, subject: "Re: Angebot"))
    }

    func testJitsiURLNeverCrashesOnOddServerSettings() {
        XCTAssertEqual(JitsiRoom.newURL(server: "vid.rocket.re-cloud.io/").host, "vid.rocket.re-cloud.io")
        XCTAssertEqual(JitsiRoom.newURL(server: "  https://meet.example.org//  ").host, "meet.example.org")
        XCTAssertNotNil(JitsiRoom.newURL(server: "bad server name").host)
    }

    func testAsyncLockRunsOneAtATime() async {
        let lock = AsyncLock()
        actor Counter { var now = 0; var peak = 0; func enter() { now += 1; peak = max(peak, now) }; func leave() { now -= 1 } }
        let c = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<20 {
                g.addTask {
                    await lock.run {
                        await c.enter()
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await c.leave()
                    }
                }
            }
        }
        let peak = await c.peak
        XCTAssertEqual(peak, 1)
    }

    #if canImport(Glibc)
    /// A server that accepts but never speaks must not hang sign-in.
    func testSilentServerTimesOut() async throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        defer { close(fd) }

        let stream = try await Transport.connect(ServerEndpoint(host: "127.0.0.1", port: port, security: .plain), timeout: 1)
        let start = Date()
        do {
            _ = try await BufferedStream(stream).readLine()
            XCTFail("expected timeout")
        } catch TransportError.timeout {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        }
        stream.close()
    }
    #endif
}

/// Concurrent app activity on one account (list refresh, open message, folder counts, IDLE wake-ups)
/// must not hang or mix up replies. Needs the dev servers (SLYY_IT=1).
final class ConcurrencyRegressionTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SLYY_IT"] == "1", "integration tests disabled")
    }

    func testParallelMailOperationsAllComplete() async throws {
        let account = AccountSettings(email: "alice@example.com", imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .plain), smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .plain))
        let mail = MailService(account: account, password: "secret")
        let seed = IMAPClient(endpoint: account.imap)
        try await seed.connect(user: "alice@example.com", password: "secret")
        var uids: [UInt32] = []
        for i in 0..<5 {
            let m = OutgoingMessage(from: account.address, to: [], subject: "parallel \(i) \(UUID())", text: "body \(i)")
            if let u = try await seed.append(folder: "INBOX", message: m.render()) { uids.append(u) }
        }
        let start = Date()
        let list = try await mail.messages(in: "INBOX", page: 0).messages
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<4 { g.addTask { _ = try await mail.folders() } }
            for _ in 0..<4 { g.addTask { _ = try await mail.messages(in: "INBOX", page: 0) } }
            for s in list.prefix(5) { g.addTask { let p = try await mail.message(s, markSeen: false); XCTAssertEqual(p.subject, s.subject) } }
            g.addTask { _ = try await mail.messages(in: "Archive", page: 0) }
            g.addTask { _ = try await mail.search(in: "INBOX", text: "parallel") }
            try await g.waitForAll()
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        try await seed.expunge(folder: "INBOX", uids: uids)
        await seed.logout()
        await mail.disconnect()
    }

    func testInviteShowsAsInviteInList() async throws {
        let account = AccountSettings(email: "alice@example.com", imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .plain), smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .plain))
        let mail = MailService(account: account, password: "secret")
        var e = CalendarEvent(summary: "Invite list \(UUID().uuidString.prefix(6))", start: Date().addingTimeInterval(86400), end: Date().addingTimeInterval(90000))
        e.organizer = EmailAddress(address: "bob@example.com")
        e.attendees = [Attendee(email: "alice@example.com")]
        try await mail.sendCalendarMail(to: [account.address], subject: "Invitation: \(e.summary)", text: "x", method: "REQUEST", ics: ICalendarWriter.request(e))
        var hit: MessageSummary?
        for _ in 0..<40 where hit == nil {
            hit = try await mail.messages(in: "INBOX", page: 0).messages.first { $0.subject.contains(e.summary) }
            if hit == nil { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        XCTAssertEqual(hit?.isInvite, true)
        await mail.disconnect()
    }
}
