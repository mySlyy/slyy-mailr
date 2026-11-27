import Foundation

public enum SMTPError: Error, LocalizedError, Equatable {
    case unexpectedReply(command: String, code: Int, text: String)
    case startTLSRequired
    case noAuthMechanism
    case recipientRejected(String, String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedReply(let c, let code, let t): return "SMTP \(c) failed (\(code)): \(t)"
        case .startTLSRequired: return "The SMTP server does not offer STARTTLS; refusing to send the password unencrypted."
        case .noAuthMechanism: return "The SMTP server offers no supported login method (PLAIN or LOGIN)."
        case .recipientRejected(let r, let t): return "Recipient \(r) was rejected: \(t)"
        }
    }
}

/// Minimal SMTP submission client (RFC 5321 / 6409): EHLO, STARTTLS, AUTH PLAIN/LOGIN, MAIL/RCPT/DATA.
public actor SMTPClient {
    public let endpoint: ServerEndpoint
    private var io: BufferedStream?
    private var extensions: [String: String] = [:]
    private let heloName: String

    public init(endpoint: ServerEndpoint, heloName: String = "slyy-mail.local") {
        self.endpoint = endpoint
        self.heloName = heloName
    }

    public struct Reply: Sendable {
        public var code: Int
        public var lines: [String]
        public var text: String { lines.joined(separator: " ") }
    }

    /// Connects, secures and authenticates.
    public func connect(user: String?, password: String?, oauth: Bool = false) async throws {
        let io = BufferedStream(try await Transport.connect(endpoint))
        self.io = io
        do {
            try expect(try await readReply(), 220, "greeting")
            try await ehlo()
            if endpoint.security == .startTLS {
                guard extensions["STARTTLS"] != nil else { throw SMTPError.startTLSRequired }
                try expect(try await send("STARTTLS"), 220, "STARTTLS")
                try await io.startTLS()
                try await ehlo()
            }
            if let user, let password, !user.isEmpty {
                if oauth {
                    try await authenticateXOAUTH2(user: user, token: password)
                } else {
                    try await authenticate(user: user, password: password)
                }
            }
        } catch {
            close()
            throw error
        }
    }

    private func ehlo() async throws {
        let r = try await send("EHLO \(heloName)")
        if r.code != 250 {
            try expect(try await send("HELO \(heloName)"), 250, "HELO")
            extensions = [:]
            return
        }
        extensions = [:]
        for line in r.lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let k = parts.first?.uppercased() else { continue }
            extensions[k] = parts.count > 1 ? parts[1] : ""
        }
    }

    private func authenticateXOAUTH2(user: String, token: String) async throws {
        let r = try await send("AUTH XOAUTH2 " + XOAUTH2.initialResponse(user: user, accessToken: token), redact: true)
        if r.code == 334 {
            // Error details come as a challenge; an empty line ends the exchange with the final failure.
            let final = try await send("")
            try expect(final, 235, "AUTH XOAUTH2")
            return
        }
        try expect(r, 235, "AUTH XOAUTH2")
    }

    private func authenticate(user: String, password: String) async throws {
        let mechs = Set((extensions["AUTH"] ?? "").uppercased().split(separator: " ").map(String.init))
        if mechs.contains("PLAIN") {
            let token = Data("\0\(user)\0\(password)".utf8).base64EncodedString()
            try expect(try await send("AUTH PLAIN \(token)", redact: true), 235, "AUTH PLAIN")
        } else if mechs.contains("LOGIN") {
            try expect(try await send("AUTH LOGIN"), 334, "AUTH LOGIN")
            try expect(try await send(Data(user.utf8).base64EncodedString(), redact: true), 334, "AUTH LOGIN")
            try expect(try await send(Data(password.utf8).base64EncodedString(), redact: true), 235, "AUTH LOGIN")
        } else {
            throw SMTPError.noAuthMechanism
        }
    }

    /// Sends one message. `recipients` must include Bcc addresses.
    public func send(from: String, recipients: [String], data: Data) async throws {
        guard let io else { throw TransportError.closed }
        let size = extensions["SIZE"] != nil ? " SIZE=\(data.count)" : ""
        let utf8 = extensions["SMTPUTF8"] != nil && !(from + recipients.joined()).unicodeScalars.allSatisfy(\.isASCII) ? " SMTPUTF8" : ""
        let body8 = extensions["8BITMIME"] != nil ? " BODY=8BITMIME" : ""
        try expect(try await send("MAIL FROM:<\(from)>\(size)\(body8)\(utf8)"), 250, "MAIL FROM")
        for r in recipients {
            let reply = try await send("RCPT TO:<\(r)>")
            guard reply.code == 250 || reply.code == 251 else { throw SMTPError.recipientRejected(r, reply.text) }
        }
        try expect(try await send("DATA"), 354, "DATA")
        try await io.write(SMTPClient.dotStuff(data))
        try await io.write(".\r\n")
        try expect(try await readReply(), 250, "DATA")
    }

    public func quit() async {
        _ = try? await send("QUIT")
        close()
    }

    public func close() {
        io?.close()
        io = nil
    }

    // MARK: Low level

    @discardableResult
    func send(_ line: String, redact: Bool = false) async throws -> Reply {
        guard let io else { throw TransportError.closed }
        try await io.write(line + "\r\n")
        return try await readReply()
    }

    func readReply() async throws -> Reply {
        guard let io else { throw TransportError.closed }
        var lines: [String] = []
        var code = 0
        while true {
            let raw = String(decoding: try await io.readLine(), as: UTF8.self)
            guard raw.count >= 3, let c = Int(raw.prefix(3)) else { throw SMTPError.unexpectedReply(command: "read", code: 0, text: raw) }
            code = c
            lines.append(raw.count > 4 ? String(raw.dropFirst(4)) : "")
            if raw.count == 3 || raw[raw.index(raw.startIndex, offsetBy: 3)] == " " { break }
        }
        return Reply(code: code, lines: lines)
    }

    private func expect(_ r: Reply, _ code: Int, _ command: String) throws {
        guard r.code == code else { throw SMTPError.unexpectedReply(command: command, code: r.code, text: r.text) }
    }

    /// Normalises line endings to CRLF, doubles leading dots, and ensures a trailing CRLF.
    static func dotStuff(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 64)
        var atLineStart = true
        var prev: UInt8 = 0
        for b in data {
            if b == 0x0A && prev != 0x0D { out.append(0x0D) }
            if atLineStart && b == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(b)
            atLineStart = b == 0x0A
            prev = b
        }
        if !(out.count >= 2 && out[out.count - 2] == 0x0D && out[out.count - 1] == 0x0A) {
            out.append(contentsOf: [0x0D, 0x0A])
        }
        return out
    }
}
