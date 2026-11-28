import XCTest
@testable import SlyyMailKit

/// Counts the connections a fake IMAP server has open, and the LOGOUTs it received.
final class ConnectionLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened = 0, _open = 0, _maxOpen = 0, _logouts = 0, _selects = 0
    var opened: Int { lock.withLock { _opened } }
    var open: Int { lock.withLock { _open } }
    var maxOpen: Int { lock.withLock { _maxOpen } }
    var logouts: Int { lock.withLock { _logouts } }
    var selects: Int { lock.withLock { _selects } }
    func didOpen() { lock.withLock { _opened += 1; _open += 1; _maxOpen = max(_maxOpen, _open) } }
    func didClose() { lock.withLock { _open -= 1 } }
    func didLogout() { lock.withLock { _logouts += 1 } }
    func didSelect() { lock.withLock { _selects += 1 } }
}

/// One connection to an IMAP server that logs in fine but refuses every SELECT/EXAMINE with NO.
final class RefusingIMAPConnection: ByteStream, @unchecked Sendable {
    var readTimeout: TimeInterval = 5
    private let lock = NSLock()
    private var outbox = Data("* OK ready\r\n".utf8)
    private var inbox = Data()
    private var closed = false
    private let ledger: ConnectionLedger

    init(ledger: ConnectionLedger) {
        self.ledger = ledger
        ledger.didOpen()
    }

    func read(maxLength: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(readTimeout)
        while Date() < deadline {
            let chunk: Data? = try lock.withLock {
                if closed { throw TransportError.closed }
                guard !outbox.isEmpty else { return nil }
                let c = outbox.prefix(maxLength)
                outbox = Data(outbox.dropFirst(c.count))
                return Data(c)
            }
            if let chunk { return chunk }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw TransportError.timeout
    }

    func write(_ data: Data) async throws {
        try lock.withLock {
            if closed { throw TransportError.closed }
            inbox.append(data)
            while let nl = inbox.firstIndex(of: 0x0A) {
                var line = String(decoding: inbox[inbox.startIndex..<nl], as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                inbox = Data(inbox[(nl + 1)...])
                for r in reply(to: line) { outbox.append(Data((r + "\r\n").utf8)) }
            }
        }
    }

    private func reply(to line: String) -> [String] {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return [] }
        let tag = parts[0]
        switch parts[1].uppercased() {
        case "CAPABILITY": return ["* CAPABILITY IMAP4rev1 IDLE", "\(tag) OK done"]
        case "SELECT", "EXAMINE":
            ledger.didSelect()
            return ["\(tag) NO [UNAVAILABLE] Mailbox is temporarily unavailable"]
        case "LOGOUT":
            ledger.didLogout()
            return ["* BYE", "\(tag) OK bye"]
        default: return ["\(tag) OK"]
        }
    }

    func startTLS() async throws {}

    func close() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if wasOpen { ledger.didClose() }
    }
}

final class MailWatcherTests: XCTestCase {
    override func tearDown() { Transport.factory = nil }

    /// R9: a refused SELECT must not leak the logged-in connection; each retry reuses at most one connection.
    func testWatcherClosesConnectionWhenServerRefusesInbox() async throws {
        let ledger = ConnectionLedger()
        Transport.factory = { _ in RefusingIMAPConnection(ledger: ledger) }
        let account = AccountSettings(email: "r9@example.com",
                                      imap: ServerEndpoint(host: "imap.test", port: 143, security: .plain),
                                      smtp: ServerEndpoint(host: "smtp.test", port: 25, security: .plain))
        let watcher = MailWatcher(account: account, password: "secret")
        await watcher.setBackoffUnit(5_000_000)  // 5 ms per step instead of 1 s
        await watcher.start { }

        let deadline = Date().addingTimeInterval(10)
        while ledger.selects < 4 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await watcher.stop()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertGreaterThanOrEqual(ledger.selects, 4, "the watcher keeps retrying")
        XCTAssertEqual(ledger.maxOpen, 1, "at most one connection open at a time")
        XCTAssertEqual(ledger.open, 0, "no connection left open after stop")
        XCTAssertGreaterThanOrEqual(ledger.logouts, ledger.selects, "each refused connection logs out before the retry")
    }
}
