import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OAuth 2.0 (authorization code + PKCE) for mail providers that sign in in the browser instead of with a password.
/// No SDKs: the browser shows the provider's own login page, a local one-shot listener receives the code,
/// tokens live in the Keychain, and IMAP/SMTP log in with XOAUTH2.
// CLEANUP(C1): OAuth sign-in flow is not used by the app (Google uses app passwords). Keep for Microsoft or remove; see docs/CLEANUP.md.
public struct OAuthProvider: Sendable, Equatable {
    public var name: String
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scope: String
    public var clientID: String
    /// Some providers want the app's client secret at the token endpoint even with PKCE.
    public var clientSecret: String?
    /// The redirect registered with the provider. For a desktop app this is a small https page that forwards
    /// the code to `http://127.0.0.1:<port>/callback` (the port travels in `state`).
    public var redirectURI: String

    public init(name: String, authorizeURL: URL, tokenURL: URL, scope: String, clientID: String, clientSecret: String?, redirectURI: String) {
        self.name = name
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.scope = scope
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    /// The login page to open in the browser. `state` carries a random nonce and the local port: "<nonce>~<port>".
    public func authorizationURL(state: String, codeChallenge: String, loginHint: String?) -> URL {
        var c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var q = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let loginHint, !loginHint.isEmpty { q.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        c.queryItems = q
        return c.url!
    }

    func tokenRequest(_ params: [String: String]) -> URLRequest {
        var all = params
        all["client_id"] = clientID
        if let clientSecret, !clientSecret.isEmpty { all["client_secret"] = clientSecret }
        var r = URLRequest(url: tokenURL)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(all.sorted { $0.key < $1.key }.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)
        return r
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public func exchange(code: String, verifier: String, session: URLSession = .shared, now: Date = Date()) async throws -> OAuthTokens {
        try await tokens(tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "code_verifier": verifier]), session: session, now: now, previousRefresh: nil)
    }

    public func refresh(_ refreshToken: String, session: URLSession = .shared, now: Date = Date()) async throws -> OAuthTokens {
        try await tokens(tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "redirect_uri": redirectURI]), session: session, now: now, previousRefresh: refreshToken)
    }

    private func tokens(_ request: URLRequest, session: URLSession, now: Date, previousRefresh: String?) async throws -> OAuthTokens {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let access = json["access_token"] as? String else {
            let reason = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(status)"
            throw OAuthError.tokenRefused(reason)
        }
        let expires = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        return OAuthTokens(accessToken: access, refreshToken: (json["refresh_token"] as? String) ?? previousRefresh,
                           expiresAt: now.addingTimeInterval(expires))
    }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public enum OAuthError: Error, LocalizedError, Equatable {
    case cancelled
    case stateMismatch
    case denied(String)
    case tokenRefused(String)
    case notSignedIn
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .stateMismatch: return "The sign-in answer did not belong to this request. Please try again."
        case .denied(let r): return "The provider did not allow access: \(r)"
        case .tokenRefused(let r): return "The provider refused the sign-in: \(r)"
        case .notSignedIn: return "Please sign in again."
        case .timedOut: return "Sign-in took too long. Please try again."
        }
    }
}

/// PKCE (RFC 7636): a random verifier and its S256 challenge.
public enum PKCE {
    public static func verifier() -> String {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in chars[Int(rng.next(upperBound: UInt32(chars.count)))] })
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256Digest.hash(Data(verifier.utf8)))
    }

    public static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func nonce() -> String {
        var rng = SystemRandomNumberGenerator()
        return base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }))
    }
}

/// SHA-256 (FIPS 180-4) in plain Swift, so PKCE needs no CryptoKit and runs everywhere the library does.
public enum SHA256Digest {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ data: Data) -> Data {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return Data(h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } })
    }
}

/// Keeps a valid access token: refreshes a few minutes before it expires and reports a new refresh token
/// (some providers rotate them) so the caller can store it in the Keychain.
public actor OAuthTokenStore {
    public let provider: OAuthProvider
    private var tokens: OAuthTokens
    private let session: URLSession
    private let onRefresh: @Sendable (OAuthTokens) -> Void
    private var refreshing: Task<OAuthTokens, Error>?

    public init(provider: OAuthProvider, tokens: OAuthTokens, session: URLSession = .shared, onRefresh: @escaping @Sendable (OAuthTokens) -> Void = { _ in }) {
        self.provider = provider
        self.tokens = tokens
        self.session = session
        self.onRefresh = onRefresh
    }

    public func accessToken(now: Date = Date()) async throws -> String {
        if tokens.expiresAt.timeIntervalSince(now) > 120 { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { throw OAuthError.notSignedIn }
        if let refreshing { return try await refreshing.value.accessToken }
        let t = Task { [provider, session] in try await provider.refresh(refresh, session: session, now: now) }
        refreshing = t
        defer { refreshing = nil }
        let fresh = try await t.value
        tokens = fresh
        onRefresh(fresh)
        return fresh.accessToken
    }
}

/// SASL XOAUTH2 initial response (IMAP and SMTP of Google and Microsoft 365).
public enum XOAUTH2 {
    public static func initialResponse(user: String, accessToken: String) -> String {
        Data("user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
    }
}
