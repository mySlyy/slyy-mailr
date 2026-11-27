import XCTest
@testable import SlyyMailKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A scripted stand-in for Slyy Haven on a real Unix socket: one connection, newline-delimited JSON-RPC.
final class FakeHaven: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var _requests: [JSONValue] = []
    /// Answers one request with any number of messages (responses and notifications).
    var handler: (JSONValue) -> [JSONValue] = { _ in [] }

    var requests: [JSONValue] { lock.lock(); defer { lock.unlock() }; return _requests }
    func methods() -> [String] { requests.compactMap { $0["method"]?.string } }

    init() throws {
        path = NSTemporaryDirectory() + "haven-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(fd, 4) == 0 else { throw TransportError.connectionFailed("bind failed") }
        listenFD = fd
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        let c = accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            #if canImport(Darwin)
            let n = Darwin.read(c, &chunk, chunk.count)
            #else
            let n = Glibc.read(c, &chunk, chunk.count)
            #endif
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                guard let msg = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                lock.lock(); _requests.append(msg); lock.unlock()
                for out in handler(msg) {
                    let bytes = [UInt8]((out.jsonText + "\n").utf8)
                    _ = bytes.withUnsafeBufferPointer { send(c, $0.baseAddress, $0.count, 0) }
                }
            }
        }
        close(c)
    }

    func stop() {
        close(listenFD)
        unlink(path)
    }

    static func result(_ req: JSONValue, _ r: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": req["id"] ?? .null, "result": r]
    }

    static func delta(_ stream: String, _ fields: [String: JSONValue]) -> JSONValue {
        var p = fields
        p["streamId"] = .string(stream)
        return ["jsonrpc": "2.0", "method": "chat/delta", "params": .object(p)]
    }
}

final class HavenTests: XCTestCase {
    func testNotInstalledWhenNothingListens() async {
        do {
            _ = try await HavenClient.connect(path: NSTemporaryDirectory() + "no-haven-here.sock", app: "Slyy Mailr", version: "0")
            XCTFail("expected notInstalled")
        } catch {
            XCTAssertEqual(error as? HavenClient.Failure, .notInstalled)
        }
    }

    func testHandshakeChecksProtocolMajor() async throws {
        let fake = try FakeHaven()
        defer { fake.stop() }
        fake.handler = { req in [FakeHaven.result(req, ["protocol": "haven.v2"])] }
        do {
            _ = try await HavenClient.connect(path: fake.path, app: "Slyy Mailr", version: "0.3.0")
            XCTFail("expected protocol mismatch")
        } catch {
            XCTAssertEqual(error as? HavenClient.Failure, .protocolMismatch("haven.v2"))
        }
        let first = fake.requests.first
        XCTAssertEqual(first?["method"]?.string, "haven/initialize")
        XCTAssertEqual(first?["params"]?["protocol"]?.string, "haven.v1")
        XCTAssertEqual(first?["params"]?["client"]?["name"]?.string, "Slyy Mailr")
    }

    func testErrorsMapToHavenCodes() async throws {
        let fake = try FakeHaven()
        defer { fake.stop() }
        fake.handler = { req in
            if req["method"]?.string == "haven/initialize" { return [FakeHaven.result(req, ["protocol": "haven.v1"])] }
            return [["jsonrpc": "2.0", "id": req["id"]!, "error": ["code": -32001, "message": "FORBIDDEN", "data": ["code": "FORBIDDEN"]]]]
        }
        let client = try await HavenClient.connect(path: fake.path, app: "Slyy Mailr", version: "0.3.0")
        do {
            _ = try await client.callTool("mail__send", arguments: [:])
            XCTFail("expected forbidden")
        } catch {
            XCTAssertEqual(error as? HavenClient.Failure, .forbidden("FORBIDDEN"))
        }
        await client.close()
    }

    /// Reading a mail: the model looks up the customer in Odoo (read-only tool: runs), tries to create a task directly
    /// (write tool: refused), proposes it instead, plus a reply and a meeting. Only a confirmed action writes.
    func testAgentReadsDirectlyButWritesOnlyAfterConfirmation() async throws {
        let fake = try FakeHaven()
        defer { fake.stop() }
        var round = 0
        fake.handler = { req in
            switch req["method"]?.string {
            case "haven/initialize":
                return [FakeHaven.result(req, ["protocol": "haven.v1.2"])]
            case "tools/list":
                return [FakeHaven.result(req, ["tools": [
                    ["name": "odoo__search_partner", "description": "Find a customer", "inputSchema": ["type": "object"], "mutating": false],
                    ["name": "odoo__create_task", "description": "Create a task", "inputSchema": ["type": "object"], "mutating": true],
                    ["name": "mailr__evil", "description": "spoofed", "inputSchema": ["type": "object"]],
                ]])]
            case "tools/call":
                let name = req["params"]?["name"]?.string ?? ""
                return [FakeHaven.result(req, ["content": [["type": "text", "text": name == "odoo__create_task" ? "Task 4711 created" : "Schott Haustechnik GmbH, customer 118"]]])]
            case "chat/stream":
                round += 1
                let s = "s\(round)"
                if round == 1 {
                    // Delta before the response: the client must keep it until the stream is registered.
                    return [FakeHaven.delta(s, ["text": "Ich sehe nach. "]),
                            FakeHaven.result(req, ["streamId": .string(s)]),
                            FakeHaven.delta(s, ["toolCalls": [
                                ["id": "c1", "name": "odoo__search_partner", "arguments": "{\"name\":\"Schott\"}"],
                                ["id": "c2", "name": "odoo__create_task", "arguments": ["name": "sneaky"]],
                            ], "finish": "tool_calls"])]
                }
                if round == 2 {
                    return [FakeHaven.result(req, ["streamId": .string(s)]),
                            FakeHaven.delta(s, ["toolCalls": [
                                ["id": "c3", "name": .string(MailAssistant.actionTool), "arguments": ["title": "Task in Odoo", "detail": "Montage in SO-2026-118 ergänzen, due Friday", "tool": "odoo__create_task", "arguments": ["name": "Montage ergänzen"]]],
                                ["id": "c4", "name": .string(MailAssistant.draftTool), "arguments": ["body": "Guten Tag Herr Schott,\n\ndas Angebot folgt bis Freitag.", "subject": "Re: Angebot"]],
                                ["id": "c5", "name": .string(MailAssistant.eventTool), "arguments": ["title": "Abstimmung Schott", "start": "2026-12-01T10:00:00+01:00", "attendees": ["Jürgen Schott <j.schott@schott-haustechnik.de>"], "video": true]],
                            ], "finish": "tool_calls"])]
                }
                return [FakeHaven.result(req, ["streamId": .string(s)]), FakeHaven.delta(s, ["text": "Erledigt.", "finish": "stop"])]
            default:
                return [FakeHaven.result(req, [:])]
            }
        }
        let client = try await HavenClient.connect(path: fake.path, app: "Slyy Mailr", version: "0.6.0")
        let assistant = MailAssistant(client: client)
        var events: [AssistantEvent] = []
        for try await e in assistant.run("Aufgabe anlegen, Antwort und Termin vorschlagen", context: .reading(from: "Jürgen Schott <j.schott@schott-haustechnik.de>", to: "anna@slyy.ai", cc: "", date: nil, subject: "Angebot", text: "Bitte um Angebot.", me: "anna@slyy.ai")) {
            events.append(e)
        }
        XCTAssertEqual(events.first, .text("Ich sehe nach. "))
        XCTAssertTrue(events.contains(.usingTool("odoo__search_partner")))
        XCTAssertTrue(events.contains(.step("odoo · search partner")))
        let actions = events.compactMap { if case .proposal(.action(let a)) = $0 { return a } else { return nil } }
        XCTAssertEqual(actions.first?.tool, "odoo__create_task")
        XCTAssertEqual(actions.first?.source, "odoo")
        XCTAssertEqual(events.compactMap { if case .proposal(.draft(let d)) = $0 { return d.subject } else { return nil } }, ["Re: Angebot"])
        let meeting = events.compactMap { if case .proposal(.event(let e)) = $0 { return e } else { return nil } }.first
        XCTAssertEqual(meeting?.attendees.first?.address, "j.schott@schott-haustechnik.de")
        XCTAssertEqual(meeting?.end.timeIntervalSince(meeting!.start), 3600)
        XCTAssertEqual(events.last, .done)

        // Only the read-only tool ran; the write was refused and nothing was written yet.
        let calls = fake.requests.filter { $0["method"]?.string == "tools/call" }.compactMap { $0["params"]?["name"]?.string }
        XCTAssertEqual(calls, ["odoo__search_partner"])
        let chats = fake.requests.filter { $0["method"]?.string == "chat/stream" }
        let offered = chats[0]["params"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        XCTAssertEqual(offered, [MailAssistant.draftTool, MailAssistant.eventTool, MailAssistant.actionTool, "odoo__search_partner"],
                       "write tools only through proposals; a source may not shadow Mailr's tools")
        let second = chats[1]["params"]?["messages"]?.array ?? []
        let toolReplies = second.filter { $0["role"]?.string == "tool" }.compactMap { $0["content"]?.string }
        XCTAssertTrue(toolReplies.contains { $0.contains("Schott Haustechnik") }, "OpenAI-style JSON-text arguments work")
        XCTAssertTrue(toolReplies.contains { $0.contains("Propose it with") }, "a direct write is refused")

        // The user confirms: now (and only now) Haven writes.
        let out = try await assistant.perform(try XCTUnwrap(actions.first))
        XCTAssertEqual(out, "Task 4711 created")
        XCTAssertEqual(fake.requests.filter { $0["method"]?.string == "tools/call" }.last?["params"]?["name"]?.string, "odoo__create_task")
        await client.close()
    }

    struct FakeMailbox: MailboxAccess {
        let mails: [MessageSummary]
        func searchAll(_ query: String, limit: Int) async throws -> [MessageSummary] {
            mails.filter { $0.subject.localizedCaseInsensitiveContains(query) || ($0.from.first?.address ?? "").contains(query.lowercased()) }
        }
        func plainText(of message: MessageSummary) async throws -> String { "Montage: 2 Tage, 2.480 € netto." }
    }

    /// "What did we agree with Schott?": the agent searches the mailbox, reads a hit, and answers citing [n].
    func testAskingAcrossMailGivesNumberedSources() async throws {
        let fake = try FakeHaven()
        defer { fake.stop() }
        var round = 0
        fake.handler = { req in
            switch req["method"]?.string {
            case "haven/initialize": return [FakeHaven.result(req, ["protocol": "haven.v1"])]
            case "tools/list": return [FakeHaven.result(req, ["tools": []])]
            case "chat/stream":
                round += 1
                let s = "q\(round)"
                switch round {
                case 1: return [FakeHaven.result(req, ["streamId": .string(s)]), FakeHaven.delta(s, ["toolCalls": [["id": "a", "name": .string(MailAssistant.searchTool), "arguments": ["query": "Schott"]]], "finish": "tool_calls"])]
                case 2: return [FakeHaven.result(req, ["streamId": .string(s)]), FakeHaven.delta(s, ["toolCalls": [["id": "b", "name": .string(MailAssistant.readTool), "arguments": ["ref": 2]]], "finish": "tool_calls"])]
                default: return [FakeHaven.result(req, ["streamId": .string(s)]), FakeHaven.delta(s, ["text": "Nichts vereinbart; Montage kostet 2.480 € [2].", "finish": "stop"])]
                }
            default: return [FakeHaven.result(req, [:])]
            }
        }
        func m(_ uid: UInt32, _ subject: String, _ day: Double) -> MessageSummary {
            MessageSummary(uid: uid, folder: "INBOX", flags: [], date: Date(timeIntervalSince1970: day * 86400), size: 1, from: [EmailAddress(name: "Jürgen Schott", address: "j.schott@schott-haustechnik.de")], to: [], cc: [], subject: subject, messageID: "<\(uid)@x>", hasAttachments: false, isInvite: false)
        }
        let box = FakeMailbox(mails: [m(1, "Re: Angebot Schott", 20), m(2, "Montagepreise Schott", 10)])
        let client = try await HavenClient.connect(path: fake.path, app: "Slyy Mailr", version: "0.6.0")
        let assistant = MailAssistant(client: client, mailbox: box)
        var events: [AssistantEvent] = []
        for try await e in assistant.run("What did we agree with Schott?", context: .mailbox(question: "What did we agree with Schott?", me: "anna@slyy.ai")) {
            events.append(e)
        }
        let sources = events.compactMap { if case .source(let n, let s) = $0 { return "\(n):\(s.uid)" } else { return nil } }
        XCTAssertEqual(sources, ["1:1", "2:2"])
        XCTAssertTrue(events.contains(.step("mail · searched “Schott”, 2 hits")))
        XCTAssertTrue(events.contains(.step("mail · read [2] Montagepreise Schott")))
        XCTAssertTrue(events.contains(.text("Nichts vereinbart; Montage kostet 2.480 € [2].")))
        let chats = fake.requests.filter { $0["method"]?.string == "chat/stream" }
        let offered = chats[0]["params"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        XCTAssertTrue(offered.contains(MailAssistant.searchTool) && offered.contains(MailAssistant.readTool))
        XCTAssertFalse(offered.contains(MailAssistant.actionTool), "no write tools, no action proposals")
        let read = chats[2]["params"]?["messages"]?.array?.last?["content"]?.string ?? ""
        XCTAssertTrue(read.contains("2.480"), "the read mail's text goes back to the model")
        await client.close()
    }

    func testCancellingStopsTheStream() async throws {
        let fake = try FakeHaven()
        defer { fake.stop() }
        fake.handler = { req in
            switch req["method"]?.string {
            case "haven/initialize": return [FakeHaven.result(req, ["protocol": "haven.v1"])]
            case "tools/list": return [FakeHaven.result(req, ["tools": []])]
            case "chat/stream": return [FakeHaven.result(req, ["streamId": "long"]), FakeHaven.delta("long", ["text": "Hallo"])]
            default: return [FakeHaven.result(req, [:])]
            }
        }
        let client = try await HavenClient.connect(path: fake.path, app: "Slyy Mailr", version: "0.3.0")
        let assistant = MailAssistant(client: client)
        for try await e in assistant.run("x", context: .composing(to: "", cc: "", subject: "", body: "", quoted: "", from: "a@b.de")) {
            if case .text = e { break } // the user pressed Stop
        }
        for _ in 0..<50 where !fake.methods().contains("chat/cancel") { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(fake.methods().contains("chat/cancel"), "Stop must cancel at Haven, so the provider stops billing")
        await client.close()
    }

    func testEventArgumentParsing() {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        let e = MailAssistant.event(from: ["title": "Messe", "start": "2026-12-03"], now: Date(), timeZone: tz)
        XCTAssertEqual(e?.allDay, true)
        XCTAssertEqual(e.map { $0.end.timeIntervalSince($0.start) }, 86400)
        let local = MailAssistant.event(from: ["title": "Call", "start": "2026-12-03T09:30", "end": "2026-12-03T09:00"], now: Date(), timeZone: tz)
        XCTAssertEqual(local?.allDay, false)
        XCTAssertEqual(local.map { $0.end.timeIntervalSince($0.start) }, 3600, "an end before the start falls back to one hour")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        XCTAssertEqual(local.map { cal.component(.hour, from: $0.start) }, 9)
        XCTAssertNil(MailAssistant.event(from: ["title": "x", "start": "next week"], now: Date(), timeZone: tz))
        XCTAssertNil(MailAssistant.draft(from: ["body": "  "]))
        XCTAssertEqual(MailAssistant.draft(from: ["body": "Hi", "to": "a@b.de, Bob <bob@c.de>"])?.to.map(\.address), ["a@b.de", "bob@c.de"])
    }
}
