import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
private let sysClose = Darwin.close
private let sysRead = Darwin.read
private let sysBind = Darwin.bind
private let sysListen = Darwin.listen
private let sysAccept = Darwin.accept
private let tcpStream = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc
private let sysClose = Glibc.close
private let sysRead = Glibc.read
private let sysBind = Glibc.bind
private let sysListen = Glibc.listen
private let sysAccept = Glibc.accept
private let tcpStream = Int32(SOCK_STREAM.rawValue)
#endif

/// Receives the browser's redirect once, on 127.0.0.1 only, then closes. The port is picked by the system.
public final class OAuthCallbackReceiver: @unchecked Sendable {
    public let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    public init() throws {
        let fd = socket(AF_INET, tcpStream, 0)
        guard fd >= 0 else { throw TransportError.connectionFailed("socket() failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysBind(fd, $0, len) } } == 0
        guard ok, sysListen(fd, 4) == 0 else {
            _ = sysClose(fd)
            throw TransportError.connectionFailed("cannot listen on 127.0.0.1")
        }
        var bound = sockaddr_in()
        var blen = len
        _ = withUnsafeMutablePointer(to: &bound) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) } }
        self.fd = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, Int32(SHUT_RDWR))
        _ = sysClose(fd)
    }

    /// Waits for `GET /callback?...` and returns its query parameters. Other paths (favicon) get a 404 and are ignored.
    public func waitForCallback(timeout: TimeInterval = 300, page: String = OAuthCallbackReceiver.donePage) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { [self] in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                    let ready = poll(&pfd, 1, min(left, 1000))
                    if ready < 0 { return cont.resume(throwing: OAuthError.cancelled) }
                    if ready == 0 {
                        lock.lock(); let isClosed = closed; lock.unlock()
                        if isClosed { return cont.resume(throwing: OAuthError.cancelled) }
                        continue
                    }
                    let c = sysAccept(fd, nil, nil)
                    if c < 0 { continue }
                    var buf = [UInt8](repeating: 0, count: 16384)
                    let n = sysRead(c, &buf, buf.count)
                    let request = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
                    let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let isCallback = target.hasPrefix("/callback")
                    Self.respond(c, status: isCallback ? "200 OK" : "404 Not Found", body: isCallback ? page : "")
                    _ = sysClose(c)
                    if isCallback {
                        close()
                        return cont.resume(returning: Self.query(target))
                    }
                }
                close()
                cont.resume(throwing: OAuthError.timedOut)
            }
        }
    }

    static func query(_ target: String) -> [String: String] {
        guard let comps = URLComponents(string: "http://127.0.0.1" + target) else { return [:] }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    private static func respond(_ c: Int32, status: String, body: String) {
        let bytes = [UInt8]("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)".utf8)
        _ = bytes.withUnsafeBufferPointer { send(c, $0.baseAddress, $0.count, 0) }
    }

    public static let donePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Slyy Mailr</title>
    <style>body{font:16px -apple-system,system-ui,sans-serif;margin:15vh auto;max-width:28em;padding:0 1em;color:#0a0a0a}
    .dot{display:inline-block;width:12px;height:12px;border-radius:50%;background:#2B3BFF;margin-right:8px}</style></head>
    <body><p><span class="dot"></span><b>Signed in.</b></p><p>You can close this window and go back to Slyy Mailr.</p></body></html>
    """
}

/// One browser sign-in: PKCE, state with the local port, the redirect, the token exchange.
public struct OAuthSignIn {
    public let provider: OAuthProvider
    public init(provider: OAuthProvider) { self.provider = provider }

    /// `open` shows the URL in the browser. Returns the tokens.
    public func run(loginHint: String?, open: @Sendable (URL) async -> Void, session: URLSession = .shared) async throws -> OAuthTokens {
        let receiver = try OAuthCallbackReceiver()
        defer { receiver.close() }
        let verifier = PKCE.verifier()
        let nonce = PKCE.nonce()
        let state = "\(nonce)~\(receiver.port)"
        await open(provider.authorizationURL(state: state, codeChallenge: PKCE.challenge(for: verifier), loginHint: loginHint))
        let reply = try await withTaskCancellationHandler {
            try await receiver.waitForCallback()
        } onCancel: {
            receiver.close()
        }
        if let error = reply["error"] { throw OAuthError.denied(reply["error_description"] ?? error) }
        guard reply["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = reply["code"], !code.isEmpty else { throw OAuthError.denied("no code") }
        return try await provider.exchange(code: code, verifier: verifier, session: session)
    }
}
