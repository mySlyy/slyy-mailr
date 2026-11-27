import XCTest
@testable import SlyyMailKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stands in for the provider's token endpoint and records what was sent.
final class TokenEndpointStub: URLProtocol {
    nonisolated(unsafe) static var bodies: [String] = []
    nonisolated(unsafe) static var reply: (Int, String) = (200, "{}")

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "login.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        }
        Self.bodies.append(String(decoding: body, as: UTF8.self))
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [TokenEndpointStub.self]
        return URLSession(configuration: c)
    }
}

final class OAuthTests: XCTestCase {
    /// A provider like Microsoft 365 will be (generic OAuth groundwork; no real endpoint is contacted).
    let yahoo = OAuthProvider(name: "Test", authorizeURL: URL(string: "https://login.example.test/authorize")!,
                              tokenURL: URL(string: "https://login.example.test/token")!, scope: "mail",
                              clientID: "cid", clientSecret: "sec", redirectURI: "https://slyy.example/oauth/callback.html")

    func testSHA256AndPKCE() {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(SHA256Digest.hash(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256Digest.hash(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two blocks (56+ bytes) exercise the padding path.
        XCTAssertEqual(hex(SHA256Digest.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mJ92ZbjDDNOdhd6sLqvb1G6e0ZQ1Uw"), "Gd9NJPDH3Ecqy7l62U3YDqh_u4-sKLpK1RWozzetPic")
        let v = PKCE.verifier()
        XCTAssertEqual(v.count, 64)
        XCTAssertNotEqual(v, PKCE.verifier())
    }

    func testXOAUTH2InitialResponse() {
        XCTAssertEqual(XOAUTH2.initialResponse(user: "a@yahoo.com", accessToken: "tok"), "dXNlcj1hQHlhaG9vLmNvbQFhdXRoPUJlYXJlciB0b2sBAQ==")
    }

    func testAuthorizationURLCarriesPKCEAndState() {
        let url = yahoo.authorizationURL(state: "n0nce~51234", codeChallenge: "chal", loginHint: "anna@yahoo.de")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "login.example.test")
        XCTAssertEqual(q["client_id"], "cid")
        XCTAssertEqual(q["redirect_uri"], "https://slyy.example/oauth/callback.html")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge"], "chal")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], "n0nce~51234")
        XCTAssertEqual(q["login_hint"], "anna@yahoo.de")
        XCTAssertNil(q["client_secret"], "the secret never goes into the browser")
    }

    /// The whole browser round trip: the "browser" follows the redirect to the local receiver, the code is exchanged.
    func testSignInRoundTrip() async throws {
        TokenEndpointStub.bodies = []
        TokenEndpointStub.reply = (200, #"{"access_token":"AT1","refresh_token":"RT1","expires_in":3600,"token_type":"bearer"}"#)
        let tokens = try await OAuthSignIn(provider: yahoo).run(loginHint: "anna@yahoo.de", open: { url in
            // What the provider + bounce page do: send code and state to http://127.0.0.1:<port>/callback.
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let state = q["state"]!
            let port = state.split(separator: "~").last!
            Task.detached {
                let cb = URL(string: "http://127.0.0.1:\(port)/callback?code=C0DE&state=\(state.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)")!
                _ = try? await URLSession(configuration: .ephemeral).data(from: cb)
            }
        }, session: TokenEndpointStub.session())
        XCTAssertEqual(tokens.accessToken, "AT1")
        XCTAssertEqual(tokens.refreshToken, "RT1")
        let body = try XCTUnwrap(TokenEndpointStub.bodies.first)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=C0DE"))
        XCTAssertTrue(body.contains("code_verifier="))
        XCTAssertTrue(body.contains("client_secret=sec"))
    }

    func testWrongStateIsRejected() async throws {
        do {
            _ = try await OAuthSignIn(provider: yahoo).run(loginHint: nil, open: { url in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
                let port = state.split(separator: "~").last!
                Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=X&state=forged")!) }
            }, session: TokenEndpointStub.session())
            XCTFail("expected stateMismatch")
        } catch {
            XCTAssertEqual(error as? OAuthError, .stateMismatch)
        }
    }

    func testTokenStoreRefreshesBeforeExpiry() async throws {
        TokenEndpointStub.bodies = []
        TokenEndpointStub.reply = (200, #"{"access_token":"AT2","expires_in":3600}"#)
        let now = Date()
        let saved = LockedBox<OAuthTokens?>(nil)
        let store = OAuthTokenStore(provider: yahoo, tokens: OAuthTokens(accessToken: "AT1", refreshToken: "RT1", expiresAt: now.addingTimeInterval(60)),
                                    session: TokenEndpointStub.session(), onRefresh: { saved.value = $0 })
        let fresh = try await store.accessToken(now: now)
        XCTAssertEqual(fresh, "AT2", "a token that expires within two minutes is refreshed")
        XCTAssertEqual(saved.value?.refreshToken, "RT1", "Yahoo may not send a new refresh token: the old one is kept")
        XCTAssertTrue(TokenEndpointStub.bodies.first?.contains("grant_type=refresh_token") == true)
        let again = try await store.accessToken(now: now)
        XCTAssertEqual(again, "AT2")
        XCTAssertEqual(TokenEndpointStub.bodies.count, 1, "a valid token is reused")

        TokenEndpointStub.reply = (400, #"{"error":"invalid_grant","error_description":"revoked"}"#)
        let stale = OAuthTokenStore(provider: yahoo, tokens: OAuthTokens(accessToken: "x", refreshToken: "bad", expiresAt: now), session: TokenEndpointStub.session())
        do { _ = try await stale.accessToken(now: now); XCTFail() } catch {
            XCTAssertEqual(error as? OAuthError, .tokenRefused("revoked"))
        }
    }

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

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
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

    func startTLS() async throws {}
    func close() {}
}

final class XOAUTH2LoginTests: XCTestCase {
    let good = XOAUTH2.initialResponse(user: "anna@yahoo.de", accessToken: "GOOD")
    let endpoint = ServerEndpoint(host: "imap.test", port: 143, security: .plain)

    override func tearDown() { Transport.factory = nil }

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
        try await c.connect(user: "anna@yahoo.de", password: "GOOD", oauth: true)
        XCTAssertTrue(server.received.contains { $0.contains("AUTHENTICATE XOAUTH2 \(good)") })
        XCTAssertFalse(server.received.contains { $0.contains(" LOGIN ") }, "no password LOGIN for OAuth accounts")
    }

    func testIMAPBadTokenFailsInsteadOfHanging() async throws {
        let server = imapServer()
        Transport.factory = { _ in server }
        let c = IMAPClient(endpoint: endpoint)
        do {
            try await c.connect(user: "anna@yahoo.de", password: "EXPIRED", oauth: true)
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
        try await ok.connect(user: "anna@yahoo.de", password: "GOOD", oauth: true)
        XCTAssertTrue(server.received.contains("AUTH XOAUTH2 \(good)"))
        server = makeServer() // a new connection gets a new greeting
        let bad = SMTPClient(endpoint: ServerEndpoint(host: "smtp.test", port: 587, security: .plain))
        do {
            try await bad.connect(user: "anna@yahoo.de", password: "EXPIRED", oauth: true)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("535"), "\(error)")
        }
    }
}
