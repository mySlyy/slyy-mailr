import XCTest
@testable import SlyyMailKit

/// Runs the numbered cases in Fixtures/thread_cases.json (T-THR-…).
final class ThreadingTests: XCTestCase {
    struct Cases: Decodable {
        struct Subject: Decodable { let id, input, normalized: String; let isReply: Bool }
        struct IDs: Decodable { let id, header: String; let expected: [String] }
        struct Mail: Decodable {
            let key: String
            let folder: String?
            let context: Bool?
            let messageID, inReplyTo, references: String?
            let subject: String
            let minutes: Double
            let from: String?
            let seen: Bool?
        }
        struct Expected: Decodable { let messages: [String]; let unread: Bool?; let senders: [String]? }
        struct Thread: Decodable { let id, title: String; let messages: [Mail]; let expected: [Expected] }
        struct Summary: Decodable { let id, headers: String; let inReplyTo: String?; let references: [String] }
        let subjects: [Subject]
        let messageIDs: [IDs]
        let threads: [Thread]
        let imapSummaries: [Summary]
    }

    func cases() throws -> Cases {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "thread_cases", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }

    func testSubjects() throws {
        for c in try cases().subjects {
            XCTAssertEqual(Threader.normalizedSubject(c.input), c.normalized, c.id)
            XCTAssertEqual(Threader.isReply(c.input), c.isReply, c.id)
        }
    }

    func testMessageIDs() throws {
        for c in try cases().messageIDs {
            XCTAssertEqual(MessageHeaders.messageIDs(c.header), c.expected, c.id)
        }
    }

    func testThreads() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for c in try cases().threads {
            var keys: [String: String] = [:]
            var primary: [MessageSummary] = [], context: [MessageSummary] = []
            for (i, m) in c.messages.enumerated() {
                let s = MessageSummary(
                    uid: UInt32(i + 1), folder: m.folder ?? "INBOX", flags: m.seen == false ? [] : ["\\Seen"],
                    date: base.addingTimeInterval(m.minutes * 60), size: 1000,
                    from: [EmailAddress(address: m.from ?? "\(m.key)@x")], to: [], cc: [], subject: m.subject,
                    messageID: m.messageID, hasAttachments: false, isInvite: false,
                    inReplyTo: m.inReplyTo.flatMap { MessageHeaders.messageIDs($0).first },
                    references: MessageHeaders.messageIDs(m.references ?? ""))
                keys[s.id] = m.key
                if m.context == true { context.append(s) } else { primary.append(s) }
            }
            let got = Threader.conversations(primary, context: context)
            XCTAssertEqual(got.map { $0.messages.map { keys[$0.id]! } }, c.expected.map(\.messages), "\(c.id) \(c.title)")
            for (g, e) in zip(got, c.expected) {
                if let u = e.unread { XCTAssertEqual(g.isUnread, u, c.id) }
                if let s = e.senders { XCTAssertEqual(g.senders.map(\.address), s, c.id) }
                XCTAssertEqual(g.count, e.messages.count, c.id)
                XCTAssertEqual(g.date, g.messages.map(\.date).max(), c.id)
                XCTAssertEqual(g.latest.id, g.messages.last?.id, c.id)
            }
        }
    }

    func testIMAPSummaryCarriesThreadingHeaders() throws {
        XCTAssertTrue(IMAPClient.summaryItems.contains("IN-REPLY-TO REFERENCES"))
        for c in try cases().imapSummaries {
            let raw = Data("* 1 FETCH (UID 7 FLAGS (\\Seen) BODY[HEADER.FIELDS (SUBJECT MESSAGE-ID IN-REPLY-TO REFERENCES)] {\(c.headers.utf8.count)}\r\n\(c.headers))".utf8)
            guard case .untagged(let line) = IMAPParser.parse(raw) else { return XCTFail(c.id) }
            let s = try XCTUnwrap(IMAPClient.summary(from: line, folder: "INBOX"), c.id)
            XCTAssertEqual(s.inReplyTo, c.inReplyTo, c.id)
            XCTAssertEqual(s.references, c.references, c.id)
        }
    }

    /// T-THR-080: lists cached before threading (no inReplyTo/references keys) still load.
    func testLegacyCachedSummaryDecodes() throws {
        let json = #"[{"uid":3,"folder":"INBOX","flags":["\\Seen"],"date":1800000000,"size":10,"from":[],"to":[],"cc":[],"subject":"Alt","messageID":"<a@x>","hasAttachments":false,"isInvite":false}]"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let list = try dec.decode([MessageSummary].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.references, [])
        XCTAssertNil(list.first?.inReplyTo)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        var s = try XCTUnwrap(list.first)
        s.references = ["<a@x>"]
        XCTAssertEqual(try dec.decode(MessageSummary.self, from: enc.encode(s)), s)
    }

    /// T-THR-081: reply references parsed from a garbled header feed the reply's References.
    func testParsedMessageUsesRobustReferences() {
        let m = ParsedMessage(data: Data("Message-ID: <c@x>\r\nReferences: <a@x>,<b@x>\r\nSubject: x\r\n\r\nbody".utf8))
        XCTAssertEqual(m.references, ["<a@x>", "<b@x>"])
    }
}
