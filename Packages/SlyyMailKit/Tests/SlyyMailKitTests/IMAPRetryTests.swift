import XCTest
@testable import SlyyMailKit

/// One scripted IMAP connection that can drop: the handler returns nil to close the connection
/// after a command arrived but before any reply (the server may already have carried it out).
final class DroppingIMAPConnection: ByteStream, @unchecked Sendable {
    var readTimeout: TimeInterval = 5
    private let lock = NSLock()
    private var outbox = Data()
    private var inbox = Data()
    private var literalBytesToSkip = 0
    private var closed = false
    let handler: (String) -> [String]?

    init(handler: @escaping (String) -> [String]?) {
        self.handler = handler
        outbox = Data("* OK ready\r\n".utf8)
    }

    func read(maxLength: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(readTimeout)
        while Date() < deadline {
            let chunk: Data? = try lock.withLock {
                if !outbox.isEmpty {
                    let c = outbox.prefix(maxLength)
                    outbox = Data(outbox.dropFirst(c.count))
                    return Data(c)
                }
                if closed { throw TransportError.closed }
                return nil
            }
            if let chunk { return chunk }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw TransportError.timeout
    }

    func write(_ data: Data) async throws {
        try lock.withLock {
            if closed { throw TransportError.closed }
            feed(data)
        }
    }

    private func feed(_ data: Data) {
        inbox.append(data)
        while !closed {
            if literalBytesToSkip > 0 {
                let n = min(literalBytesToSkip, inbox.count)
                guard n > 0 else { return }
                inbox = Data(inbox.dropFirst(n))
                literalBytesToSkip -= n
                continue
            }
            guard let nl = inbox.firstIndex(of: 0x0A) else { return }
            var line = String(decoding: inbox[inbox.startIndex..<nl], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            inbox = Data(inbox[(nl + 1)...])
            // Non-synchronizing literal (LITERAL+): the message data follows; it is not a command.
            if line.hasSuffix("+}"), let open = line.lastIndex(of: "{"), let n = Int(line[line.index(after: open)..<line.index(line.endIndex, offsetBy: -2)]) {
                literalBytesToSkip = n
            }
            guard let replies = handler(line) else {
                closed = true
                outbox = Data()
                return
            }
            for r in replies { outbox.append(Data((r + "\r\n").utf8)) }
        }
    }

    func startTLS() async throws {}
    func close() { lock.withLock { closed = true } }
}

/// After a dropped connection MailService reconnects, but replays only operations that are safe to repeat:
/// a replayed APPEND would file a second copy in Sent/Drafts, a replayed COPY a second copy in the target.
final class IMAPRetryTests: XCTestCase {
    override func tearDown() { Transport.factory = nil }

    /// Every connection runs `script`; `dropOn` names the command (e.g. "APPEND") whose first occurrence drops the connection.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var connections = 0
        private(set) var commands: [String] = []
        private var dropped = false
        let dropOn: String

        init(dropOn: String) { self.dropOn = dropOn }

        func count(_ prefix: String) -> Int { lock.withLock { commands.filter { $0.hasPrefix(prefix) }.count } }

        func connect() -> ByteStream {
            lock.withLock { connections += 1 }
            return DroppingIMAPConnection { [self] line in
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2, parts[0].hasPrefix("S") else { return [] }
                let tag = parts[0]
                var cmd = parts[1].uppercased()
                if cmd == "UID", parts.count > 2 { cmd += " " + (parts[2].split(separator: " ").first.map { $0.uppercased() } ?? "") }
                let drop: Bool = lock.withLock {
                    commands.append(cmd)
                    if !dropped && cmd == dropOn { dropped = true; return true }
                    return false
                }
                if drop { return nil }
                switch cmd {
                case "CAPABILITY": return ["* CAPABILITY IMAP4rev1 LITERAL+ UIDPLUS MOVE", "\(tag) OK"]
                case "LIST": return [
                    #"* LIST (\HasNoChildren) "/" "INBOX""#,
                    #"* LIST (\HasNoChildren \Drafts) "/" "Drafts""#,
                    #"* LIST (\HasNoChildren \Sent) "/" "Sent""#,
                    "\(tag) OK"]
                case "SELECT": return ["* 1 EXISTS", "* OK [UIDVALIDITY 1] ok", "* OK [UIDNEXT 8] ok", "\(tag) OK [READ-WRITE] selected"]
                case "APPEND": return ["\(tag) OK [APPENDUID 1 8] appended"]
                case "UID SEARCH": return ["* SEARCH 7", "\(tag) OK"]
                case "UID FETCH":
                    let body = "Subject: hi\r\n\r\nhello\r\n"
                    if line.contains("BODY.PEEK[]") {
                        return ["* 1 FETCH (UID 7 BODY[] {\(body.utf8.count)}\r\n\(body))", "\(tag) OK"]
                    }
                    return ["* 1 FETCH (UID 7 FLAGS () RFC822.SIZE 20 BODY[HEADER.FIELDS (SUBJECT)] {\(body.utf8.count)}\r\n\(body))", "\(tag) OK"]
                case "LOGOUT": return ["* BYE", "\(tag) OK"]
                default: return ["\(tag) OK"]
                }
            }
        }
    }

    func service(_ server: Server) -> MailService {
        Transport.factory = { _ in server.connect() }
        let account = AccountSettings(email: "r6@example.com", imap: ServerEndpoint(host: "imap.test", port: 143, security: .plain), smtp: ServerEndpoint(host: "smtp.test", port: 587, security: .plain))
        return MailService(account: account, password: "secret")
    }

    let summary = MessageSummary(uid: 7, folder: "INBOX", flags: ["\\Seen"], date: Date(), size: 1, from: [], to: [], cc: [], subject: "x", messageID: nil, hasAttachments: false, isInvite: false)

    func testDroppedAppendIsNotReplayed() async throws {
        let server = Server(dropOn: "APPEND")
        let mail = service(server)
        let draft = OutgoingMessage(from: EmailAddress(name: "", address: "r6@example.com"), to: [], subject: "draft", text: "hi")
        do {
            _ = try await mail.saveDraft(draft, replacing: nil)
            XCTFail("the dropped APPEND must surface as an error")
        } catch is TransportError {}
        XCTAssertEqual(server.count("APPEND"), 1, "APPEND must not be sent again: the server may have stored it already")
        // The dead connection was discarded: the next call reconnects and works.
        let found = try await mail.search(in: "INBOX", text: "hi")
        XCTAssertEqual(found.map(\.uid), [7])
        XCTAssertEqual(server.connections, 2)
    }

    func testDroppedMoveIsNotReplayed() async throws {
        let server = Server(dropOn: "UID MOVE")
        let mail = service(server)
        do {
            try await mail.move([summary], to: "Archive")
            XCTFail("the dropped MOVE must surface as an error")
        } catch is TransportError {}
        XCTAssertEqual(server.count("UID MOVE"), 1)
    }

    func testDroppedSearchIsRetried() async throws {
        let server = Server(dropOn: "UID SEARCH")
        let mail = service(server)
        let found = try await mail.search(in: "INBOX", text: "hi")
        XCTAssertEqual(found.map(\.uid), [7])
        XCTAssertEqual(server.count("UID SEARCH"), 2)
        XCTAssertEqual(server.connections, 2)
    }

    func testDroppedFetchIsRetried() async throws {
        let server = Server(dropOn: "UID FETCH")
        let mail = service(server)
        let m = try await mail.message(summary, markSeen: false)
        XCTAssertEqual(server.count("UID FETCH"), 2)
        XCTAssertEqual(server.connections, 2)
        XCTAssertEqual(m.subject, "hi")
    }
}
