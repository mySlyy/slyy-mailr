import XCTest
@testable import SlyyMailKit

/// Without UIDPLUS a plain EXPUNGE removes every \Deleted message in the folder, so moving or
/// deleting our messages must not take along messages another client only marked as deleted.
final class ExpungeFallbackTests: XCTestCase {
    override func tearDown() { Transport.factory = nil }

    /// A tiny stateful mailbox (UIDs 1...5) without UIDPLUS and MOVE.
    final class Mailbox: @unchecked Sendable {
        var flags: [UInt32: Set<String>] = [1: [], 2: [], 3: [], 4: ["\\Deleted"], 5: ["\\Deleted"]]
        var copied: [UInt32] = []

        static func parseSet(_ s: String) -> [UInt32] {
            s.split(separator: ",").flatMap { r -> [UInt32] in
                let b = r.split(separator: ":").compactMap { UInt32($0) }
                return b.count == 2 ? Array(b[0]...b[1]) : b
            }
        }

        func handle(_ line: String) -> [String] {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return [] }
            let tag = parts[0], cmd = parts[1].uppercased()
            switch cmd {
            case "CAPABILITY": return ["* CAPABILITY IMAP4rev1 IDLE", "\(tag) OK"]
            case "SELECT": return ["* \(flags.count) EXISTS", "* OK [UIDVALIDITY 1] ok", "* OK [UIDNEXT 6] ok", "\(tag) OK [READ-WRITE] selected"]
            case "EXPUNGE":
                let gone = flags.filter { $0.value.contains("\\Deleted") }.keys
                for u in gone { flags[u] = nil }
                return gone.map { _ in "* 1 EXPUNGE" } + ["\(tag) OK expunged"]
            case "UID" where parts.count >= 4:
                switch parts[2].uppercased() {
                case "SEARCH":
                    guard parts[3].uppercased() == "DELETED" else { return ["\(tag) BAD unsupported"] }
                    let hits = flags.filter { $0.value.contains("\\Deleted") }.keys.sorted().map(String.init)
                    return ["* SEARCH" + hits.map { " " + $0 }.joined(), "\(tag) OK"]
                case "STORE" where parts.count >= 6:
                    let uids = Mailbox.parseSet(parts[3])
                    let flag = parts[5].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    for u in uids where flags[u] != nil {
                        if parts[4].hasPrefix("+") { flags[u]!.insert(flag) } else { flags[u]!.remove(flag) }
                    }
                    return ["\(tag) OK"]
                case "COPY":
                    copied += Mailbox.parseSet(parts[3])
                    return ["\(tag) OK"]
                case "EXPUNGE", "MOVE":
                    return ["\(tag) BAD not advertised"]
                default: return ["\(tag) BAD"]
                }
            default: return ["\(tag) OK"]
            }
        }
    }

    func client(_ box: Mailbox) async throws -> (IMAPClient, ScriptedServer) {
        let server = ScriptedServer(greeting: "* OK ready") { box.handle($0) }
        Transport.factory = { _ in server }
        let c = IMAPClient(endpoint: ServerEndpoint(host: "imap.test", port: 143, security: .plain))
        try await c.connect(user: "r3@example.com", password: "secret")
        return (c, server)
    }

    func testMoveWithoutUIDPLUSKeepsOtherDeletedMessages() async throws {
        let box = Mailbox()
        let (c, server) = try await client(box)
        try await c.move(folder: "INBOX", uids: [2], to: "Archive")
        XCTAssertEqual(box.copied, [2])
        XCTAssertNil(box.flags[2], "the archived message is gone from INBOX")
        XCTAssertEqual(box.flags[4], ["\\Deleted"], "marked by another client: kept and still marked")
        XCTAssertEqual(box.flags[5], ["\\Deleted"], "marked by another client: kept and still marked")
        XCTAssertEqual(box.flags[1], [])
        XCTAssertEqual(box.flags[3], [])
        let cmds = server.received.map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        let tail = Array(cmds.drop { !$0.hasPrefix("UID COPY") })
        XCTAssertEqual(Array(tail.prefix(6)), [
            "UID COPY 2 \"Archive\"",
            "UID STORE 2 +FLAGS.SILENT (\\Deleted)",
            "UID SEARCH DELETED",
            "UID STORE 4:5 -FLAGS.SILENT (\\Deleted)",
            "EXPUNGE",
            "UID STORE 4:5 +FLAGS.SILENT (\\Deleted)",
        ])
    }

    func testExpungeWithoutUIDPLUSAndNoOtherDeletedIsPlain() async throws {
        let box = Mailbox()
        box.flags[4] = []
        box.flags[5] = []
        let (c, server) = try await client(box)
        try await c.expunge(folder: "INBOX", uids: [1, 3])
        XCTAssertEqual(box.flags.keys.sorted(), [2, 4, 5])
        XCTAssertFalse(server.received.contains { $0.contains("-FLAGS") }, "nothing to unmark")
    }
}
