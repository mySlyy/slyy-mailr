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
    func testParallelMailOperationsAllComplete() async throws {
        let alice = try TestAccount.local()
        let account = alice.settings
        let mail = alice.mail()
        let seed = try await alice.imap()
        var uids: [UInt32] = []
        for i in 0..<5 {
            let m = OutgoingMessage(from: account.address, to: [], subject: alice.tagged("parallel \(i)"), text: "body \(i)")
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
        let alice = try TestAccount.local()
        let account = alice.settings
        let mail = alice.mail()
        var e = CalendarEvent(summary: alice.tagged("Invite list"), start: Date().addingTimeInterval(86400), end: Date().addingTimeInterval(90000))
        e.organizer = EmailAddress(address: "bob@example.com")
        e.attendees = [Attendee(email: "alice@example.com")]
        try await mail.sendCalendarMail(to: [account.address], subject: "Invitation: \(e.summary)", text: "x", method: "REQUEST", ics: ICalendarWriter.request(e))
        let summary = e.summary
        let hit = try await TestAccount.waitForMail(mail, subjectContains: summary).first
        XCTAssertEqual(hit?.isInvite, true)
        await alice.cleanUp(mail)
        await mail.disconnect()
    }
}

/// IDLE and normal commands on one IMAPClient must share the connection's command slot:
/// nothing may be written between "IDLE" and "DONE", and a command issued meanwhile ends the IDLE and runs after it.
final class IMAPIdleSerializationTests: XCTestCase {
    override func tearDown() { Transport.factory = nil }

    final class IdleState: @unchecked Sendable {
        private let lock = NSLock()
        private var _idleTag: String?
        private var _violations: [String] = []
        /// Hold back "+ idling" / the STATUS reply until the test pushes them.
        var holdContinuation = false
        var holdStatus = false
        var idleTag: String? {
            get { lock.withLock { _idleTag } }
            set { lock.withLock { _idleTag = newValue } }
        }
        var violations: [String] {
            get { lock.withLock { _violations } }
            set { lock.withLock { _violations = newValue } }
        }
        private(set) var heldStatusTag: String?
        func holdStatusReply(_ tag: String) { lock.withLock { heldStatusTag = tag } }
    }

    /// Scripted server that answers a command sent while idling with BAD, like Dovecot, and records it.
    func idleServer(_ state: IdleState) -> ScriptedServer {
        ScriptedServer(greeting: "* OK ready") { line in
            if let idleTag = state.idleTag {
                if line == "DONE" {
                    state.idleTag = nil
                    return ["\(idleTag) OK Idle completed"]
                }
                state.violations.append(line)
                let tag = line.split(separator: " ").first.map(String.init) ?? "*"
                return ["\(tag) BAD Expected DONE"]
            }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else {
                state.violations.append(line)
                return ["* BAD stray line"]
            }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "CAPABILITY": return ["* CAPABILITY IMAP4rev1 IDLE", "\(tag) OK done"]
            case "LOGIN": return ["\(tag) OK logged in"]
            case "SELECT": return ["* 3 EXISTS", "* OK [UIDVALIDITY 7] ok", "* OK [UIDNEXT 4] ok", "\(tag) OK [READ-WRITE] selected"]
            case "STATUS":
                if state.holdStatus { state.holdStatusReply(tag); return [] }
                return ["* STATUS INBOX (MESSAGES 3 UNSEEN 1)", "\(tag) OK status"]
            case "IDLE":
                state.idleTag = tag
                return state.holdContinuation ? [] : ["+ idling"]
            case "LOGOUT": return ["* BYE", "\(tag) OK bye"]
            default: return ["\(tag) OK"]
            }
        }
    }

    /// Asserts the client never wrote a command while the server was idling, and every IDLE was ended with DONE.
    func assertValidWire(_ server: ScriptedServer, _ state: IdleState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.violations, [], "commands written during IDLE", file: file, line: line)
        var idling = false
        for l in server.received {
            if l.hasSuffix(" IDLE") {
                XCTAssertFalse(idling, "IDLE while idling", file: file, line: line)
                idling = true
            } else if l == "DONE" {
                XCTAssertTrue(idling, "DONE outside IDLE", file: file, line: line)
                idling = false
            } else {
                XCTAssertFalse(idling, "\(l) between IDLE and DONE", file: file, line: line)
            }
        }
        XCTAssertFalse(idling, "IDLE never ended", file: file, line: line)
    }

    func connectedClient() async throws -> (IMAPClient, ScriptedServer, IdleState) {
        let state = IdleState()
        let server = idleServer(state)
        Transport.factory = { _ in server }
        let c = IMAPClient(endpoint: ServerEndpoint(host: "imap.test", port: 143, security: .plain))
        try await c.connect(user: "r7@example.com", password: "secret")
        try await c.select("INBOX")
        return (c, server, state)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition(), "timed out")
    }

    /// Wire order of IDLE, DONE and STATUS.
    func order(_ server: ScriptedServer) -> [String] {
        server.received.compactMap { l in
            if l.hasSuffix(" IDLE") { return "IDLE" }
            if l == "DONE" { return "DONE" }
            if l.contains(" STATUS ") { return "STATUS" }
            return nil
        }
    }

    /// The reported bug: a status check while IDLE is starting (written, "+ idling" not yet read).
    func testCommandIssuedWhileIdleStartsWaitsForDone() async throws {
        let (c, server, state) = try await connectedClient()
        state.holdContinuation = true
        let idling = Task { try await c.idle(folder: "INBOX", timeout: 30) }
        try await waitUntil { state.idleTag != nil }
        async let counts = c.status("INBOX")
        // STATUS must not reach the wire; DONE must wait for the continuation.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(order(server), ["IDLE"])
        server.push(["+ idling"])
        let (messages, unseen) = try await counts
        XCTAssertEqual(messages, 3)
        XCTAssertEqual(unseen, 1)
        let result = try await idling.value
        XCTAssertEqual(result, .timeout, "the IDLE was ended by the waiting command, not by a change")
        XCTAssertEqual(order(server), ["IDLE", "DONE", "STATUS"])
        assertValidWire(server, state)
        let connected = await c.isConnected
        XCTAssertTrue(connected)
        await c.logout()
    }

    func testCommandDuringRunningIdleEndsItFirst() async throws {
        let (c, server, state) = try await connectedClient()
        let idling = Task { try await c.idle(folder: "INBOX", timeout: 30) }
        try await waitUntil { state.idleTag != nil }
        let (messages, _) = try await c.status("INBOX")
        XCTAssertEqual(messages, 3)
        let result = try await idling.value
        XCTAssertEqual(result, .timeout)
        XCTAssertEqual(order(server), ["IDLE", "DONE", "STATUS"])
        assertValidWire(server, state)
        await c.logout()
    }

    func testIdleStartedWhileCommandInFlightWaitsForIt() async throws {
        let (c, server, state) = try await connectedClient()
        state.holdStatus = true
        async let counts = c.status("INBOX")
        try await waitUntil { state.heldStatusTag != nil }
        let idling = Task { try await c.idle(folder: "INBOX", timeout: 30) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(order(server), ["STATUS"], "IDLE must wait for the STATUS reply")
        server.push(["* STATUS INBOX (MESSAGES 3 UNSEEN 1)", "\(state.heldStatusTag ?? "") OK status"])
        let (messages, _) = try await counts
        XCTAssertEqual(messages, 3)
        try await waitUntil { state.idleTag != nil }
        await c.stopIdle()
        _ = try await idling.value
        XCTAssertEqual(order(server), ["STATUS", "IDLE", "DONE"])
        assertValidWire(server, state)
        await c.logout()
    }

    /// A command queued behind a waiting IDLE ends that IDLE as soon as it starts.
    func testCommandQueuedBehindWaitingIdleEndsIt() async throws {
        let (c, server, state) = try await connectedClient()
        state.holdStatus = true
        async let first = c.status("INBOX")
        try await waitUntil { state.heldStatusTag != nil }
        state.holdStatus = false
        let idling = Task { try await c.idle(folder: "INBOX", timeout: 30) }
        try await Task.sleep(nanoseconds: 50_000_000)
        async let second = c.status("INBOX")
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        server.push(["* STATUS INBOX (MESSAGES 3 UNSEEN 1)", "\(state.heldStatusTag ?? "") OK status"])
        _ = try await first
        let (messages, _) = try await second
        XCTAssertEqual(messages, 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the second STATUS must not wait for the IDLE timeout")
        _ = try await idling.value
        XCTAssertEqual(order(server), ["STATUS", "IDLE", "DONE", "STATUS"])
        assertValidWire(server, state)
        await c.logout()
    }
}
