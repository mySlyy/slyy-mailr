import XCTest
@testable import SlyyMailKit

/// A tiny stateful IMAP server: folders with UIDs, Message-IDs and \Deleted flags; UIDPLUS optional.
final class FakeIMAPStore: @unchecked Sendable {
    struct Mail { var uid: UInt32; var messageID: String; var deleted = false }
    let uidplus: Bool
    var folders: [String: [Mail]] = ["INBOX": [], "Drafts": [], "Sent": [], "Trash": []]
    var nextUID: UInt32 = 1
    var selected: String?
    private(set) var log: [String] = []
    // APPEND in progress (LITERAL+: the message lines follow the command line)
    private var appendTag: String?
    private var appendFolder = ""
    private var appendRemaining = 0
    private var appendMessageID = ""

    init(uidplus: Bool) { self.uidplus = uidplus }

    func server() -> ScriptedServer {
        ScriptedServer(greeting: "* OK ready") { [self] line in handle(line) }
    }

    func uids(_ folder: String) -> [UInt32] { (folders[folder] ?? []).map(\.uid) }

    private static func quoted(_ s: Substring) -> String? {
        guard let a = s.firstIndex(of: "\"") else { return nil }
        let rest = s[s.index(after: a)...]
        guard let b = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<b])
    }

    private static func uidSet(_ s: String) -> Set<UInt32> {
        var out = Set<UInt32>()
        for part in s.split(separator: ",") {
            let r = part.split(separator: ":").compactMap { UInt32($0) }
            if r.count == 2 { for u in r[0]...r[1] { out.insert(u) } } else if let u = r.first { out.insert(u) }
        }
        return out
    }

    private func handle(_ line: String) -> [String] {
        log.append(line)
        if let tag = appendTag {
            if appendMessageID.isEmpty, line.lowercased().hasPrefix("message-id:") {
                appendMessageID = line.dropFirst("message-id:".count).trimmingCharacters(in: .whitespaces)
            }
            if appendRemaining > 0 {
                appendRemaining -= line.utf8.count + 2
                if appendRemaining >= 0 { return [] }
            }
            appendTag = nil
            let uid = nextUID
            nextUID += 1
            folders[appendFolder, default: []].append(Mail(uid: uid, messageID: appendMessageID))
            return [uidplus ? "\(tag) OK [APPENDUID 1 \(uid)] Append completed" : "\(tag) OK Append completed"]
        }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return [] }
        let tag = parts[0], rest = parts.count > 2 ? parts[2] : ""
        switch parts[1].uppercased() {
        case "CAPABILITY":
            return ["* CAPABILITY IMAP4rev1 LITERAL+ IDLE\(uidplus ? " UIDPLUS" : "")", "\(tag) OK"]
        case "LOGIN": return ["\(tag) OK logged in"]
        case "LIST": return [
            #"* LIST (\HasNoChildren) "/" "INBOX""#,
            #"* LIST (\HasNoChildren \Drafts) "/" "Drafts""#,
            #"* LIST (\HasNoChildren \Sent) "/" "Sent""#,
            #"* LIST (\HasNoChildren \Trash) "/" "Trash""#,
            "\(tag) OK"]
        case "SELECT", "EXAMINE":
            selected = FakeIMAPStore.quoted(Substring(rest)) ?? rest
            return ["* \(folders[selected!]?.count ?? 0) EXISTS", "* OK [UIDVALIDITY 1] ok", "* OK [UIDNEXT \(nextUID)] ok", "\(tag) OK [READ-WRITE] selected"]
        case "APPEND":
            appendTag = tag
            appendFolder = FakeIMAPStore.quoted(Substring(rest)) ?? ""
            appendMessageID = ""
            if let open = rest.lastIndex(of: "{"), let n = Int(rest[rest.index(after: open)...].filter(\.isNumber)) { appendRemaining = n }
            return []
        case "EXPUNGE":
            folders[selected ?? ""]?.removeAll { $0.deleted }
            return ["\(tag) OK"]
        case "UID":
            guard let f = selected else { return ["\(tag) BAD no mailbox"] }
            let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
            switch args.first?.uppercased() {
            case "SEARCH":
                let q = args.count > 1 ? args[1] : ""
                let hits: [UInt32]
                if q.uppercased().hasPrefix("HEADER MESSAGE-ID") {
                    let id = FakeIMAPStore.quoted(Substring(q)) ?? ""
                    hits = (folders[f] ?? []).filter { $0.messageID.contains(id) }.map(\.uid)
                } else if q.uppercased() == "DELETED" {
                    hits = (folders[f] ?? []).filter(\.deleted).map(\.uid)
                } else {
                    hits = []
                }
                return ["* SEARCH" + hits.map { " \($0)" }.joined(), "\(tag) OK"]
            case "STORE":
                let a = (args.count > 1 ? args[1] : "").split(separator: " ", maxSplits: 1).map(String.init)
                let set = FakeIMAPStore.uidSet(a.first ?? "")
                let add = a.count > 1 && a[1].hasPrefix("+")
                if a.count > 1, a[1].contains("\\Deleted") {
                    for i in folders[f]!.indices where set.contains(folders[f]![i].uid) { folders[f]![i].deleted = add }
                }
                return ["\(tag) OK"]
            case "EXPUNGE":
                guard uidplus else { return ["\(tag) BAD no UIDPLUS"] }
                let set = FakeIMAPStore.uidSet(args.count > 1 ? args[1] : "")
                folders[f]?.removeAll { $0.deleted && set.contains($0.uid) }
                return ["\(tag) OK"]
            default: return ["\(tag) OK"]
            }
        case "LOGOUT": return ["* BYE", "\(tag) OK"]
        default: return ["\(tag) OK"]
        }
    }
}

/// Saving drafts: every autosave replaces the previous copy, with or without UIDPLUS (APPENDUID).
final class DraftTests: XCTestCase {
    override func tearDown() { Transport.factory = nil }

    let account = AccountSettings(email: "r4@example.com", displayName: "", imap: ServerEndpoint(host: "imap.test", port: 143, security: .plain),
                                  smtp: ServerEndpoint(host: "smtp.test", port: 25, security: .plain), caldavURL: "")

    func smtpServer() -> ScriptedServer {
        var inData = false
        return ScriptedServer(greeting: "220 smtp.test ready") { line in
            if inData {
                if line == "." { inData = false; return ["250 queued"] }
                return []
            }
            let cmd = line.split(separator: " ").first.map { String($0).uppercased() } ?? ""
            switch cmd {
            case "EHLO": return ["250-smtp.test", "250 AUTH PLAIN"]
            case "AUTH": return ["235 ok"]
            case "DATA": inData = true; return ["354 go ahead"]
            case "QUIT": return ["221 bye"]
            default: return ["250 ok"]
            }
        }
    }

    func setUp(_ store: FakeIMAPStore) {
        let smtp = smtpServer()
        Transport.factory = { ep in ep.host == "smtp.test" ? smtp : store.server() }
    }

    func draft(_ id: String = "<draft-1@example.com>", text: String) -> OutgoingMessage {
        OutgoingMessage(from: EmailAddress(address: "r4@example.com"), to: [EmailAddress(address: "x@example.com")],
                        subject: "Draft", text: text, messageID: id)
    }

    func testAutosavesWithoutUIDPLUSLeaveOneDraft() async throws {
        let store = FakeIMAPStore(uidplus: false)
        setUp(store)
        let mail = MailService(account: account, password: "secret")
        let first = try await mail.saveDraft(draft(text: "one"), replacing: nil)
        XCTAssertNotNil(first, "UID found by Message-ID when APPEND reports none")
        let second = try await mail.saveDraft(draft(text: "two"), replacing: first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.uids("Drafts"), [second].compactMap { $0 }, "the previous copy is replaced")
        XCTAssertEqual(store.uids("Drafts").count, 1, "one draft after two autosaves")
        // Even if the caller lost the UID, the old copies go (found by Message-ID).
        let third = try await mail.saveDraft(draft(text: "three"), replacing: nil)
        XCTAssertEqual(store.uids("Drafts"), [third].compactMap { $0 })
        XCTAssertEqual(store.uids("Drafts").count, 1)
        await mail.disconnect()
    }

    func testOtherDraftsStay() async throws {
        let store = FakeIMAPStore(uidplus: false)
        setUp(store)
        let mail = MailService(account: account, password: "secret")
        let other = try await mail.saveDraft(draft("<other@example.com>", text: "other"), replacing: nil)
        let a = try await mail.saveDraft(draft(text: "one"), replacing: nil)
        let b = try await mail.saveDraft(draft(text: "two"), replacing: a)
        XCTAssertEqual(store.uids("Drafts"), [other, b].compactMap { $0 })
        XCTAssertEqual(store.uids("Drafts").count, 2)
        await mail.disconnect()
    }

    func testSendRemovesDraftWithoutUIDPLUS() async throws {
        let store = FakeIMAPStore(uidplus: false)
        setUp(store)
        let mail = MailService(account: account, password: "secret")
        let uid = try await mail.saveDraft(draft(text: "one"), replacing: nil)
        _ = try await mail.saveDraft(draft(text: "two"), replacing: uid)
        // The UID got lost (e.g. older app state): the draft is still found by its Message-ID.
        try await mail.send(draft(text: "final"), replacingDraft: nil)
        XCTAssertEqual(store.uids("Drafts"), [], "no draft copy left after sending")
        XCTAssertEqual(store.uids("Sent").count, 1)
        await mail.disconnect()
    }

    func testUIDPLUSUsesAppendUID() async throws {
        let store = FakeIMAPStore(uidplus: true)
        setUp(store)
        let mail = MailService(account: account, password: "secret")
        let first = try await mail.saveDraft(draft(text: "one"), replacing: nil)
        let second = try await mail.saveDraft(draft(text: "two"), replacing: first)
        XCTAssertEqual(store.uids("Drafts"), [second].compactMap { $0 })
        XCTAssertFalse(store.log.contains { $0.contains("SEARCH") })
        try await mail.send(draft(text: "final"), replacingDraft: second)
        XCTAssertEqual(store.uids("Drafts"), [])
        await mail.disconnect()
    }
}

/// UIDPLUS path on the local Dovecot (the local SMTP sink only knows alice/bob, so no send here).
final class DraftIntegrationTests: XCTestCase {
    func testAutosaveReplacesDraft() async throws {
        let acc = try TestAccount.local("r4@example.com")
        let mail = acc.mail()
        let subject = acc.tagged("Draft autosave")
        var msg = OutgoingMessage(from: acc.address, to: [acc.address], subject: subject, text: "one")
        let first = try await mail.saveDraft(msg, replacing: nil)
        XCTAssertNotNil(first)
        msg.text = "two"
        let second = try await mail.saveDraft(msg, replacing: first)
        XCTAssertNotNil(second)
        let drafts = try await mail.folderPath(.drafts)
        let copies = try await mail.messages(in: drafts, page: 0).messages.filter { $0.subject == subject }
        XCTAssertEqual(copies.map(\.uid), [second].compactMap { $0 }, "one draft after two autosaves")
        await acc.cleanUp(mail)
        await mail.disconnect()
    }
}

final class TrashUndoIntegrationTests: XCTestCase {
    /// Delete moves one message to the Trash; undo moves it back to its folder; the other message is untouched.
    func testRestoreFromTrash() async throws {
        let acc = try TestAccount.local("r9@example.com")
        let mail = acc.mail()
        let imap = try await acc.imap()
        let keep = OutgoingMessage(from: acc.address, to: [acc.address], subject: acc.tagged("keep"), text: "stays")
        let gone = OutgoingMessage(from: acc.address, to: [acc.address], subject: acc.tagged("undo me"), text: "comes back")
        _ = try await imap.append(folder: "INBOX", message: keep.render())
        _ = try await imap.append(folder: "INBOX", message: gone.render())
        await imap.logout()

        let inbox = try await mail.messages(in: "INBOX", page: 0).messages
        let target = try XCTUnwrap(inbox.first { $0.subject == gone.subject })
        try await mail.delete([target])
        var now = try await mail.messages(in: "INBOX", page: 0).messages
        XCTAssertFalse(now.contains { $0.subject == gone.subject })
        XCTAssertTrue(now.contains { $0.subject == keep.subject })

        let restored = try await mail.restoreFromTrash([target])
        XCTAssertEqual(restored, 1)
        now = try await mail.messages(in: "INBOX", page: 0).messages
        XCTAssertTrue(now.contains { $0.subject == gone.subject }, "back in the Inbox")
        let trash = try await mail.folderPath(.trash)
        let inTrash = try await mail.messages(in: trash, page: 0).messages
        XCTAssertFalse(inTrash.contains { $0.subject == gone.subject }, "no copy left in the Trash")
        await acc.cleanUp(mail)
        await mail.disconnect()
    }
}

final class UnreadFilterIntegrationTests: XCTestCase {
    func testUnreadReturnsOnlyUnseen() async throws {
        let acc = try TestAccount.local("r9@example.com")
        let mail = acc.mail()
        let imap = try await acc.imap()
        let a = OutgoingMessage(from: acc.address, to: [acc.address], subject: acc.tagged("unread one"), text: "x")
        let b = OutgoingMessage(from: acc.address, to: [acc.address], subject: acc.tagged("read one"), text: "y")
        _ = try await imap.append(folder: "INBOX", message: a.render())
        _ = try await imap.append(folder: "INBOX", message: b.render(), flags: ["\\Seen"])
        await imap.logout()
        let unread = try await mail.unread(in: "INBOX").filter { $0.subject.contains(acc.token) }
        XCTAssertEqual(unread.map(\.subject), [a.subject])
        await acc.cleanUp(mail)
        await mail.disconnect()
    }
}

final class PhraseSearchIntegrationTests: XCTestCase {
    func testQuotedPhraseOnTheServer() async throws {
        let acc = try TestAccount.local("r9@example.com")
        let mail = acc.mail()
        let imap = try await acc.imap()
        let inOrder = OutgoingMessage(from: acc.address, to: [acc.address], subject: acc.tagged("one"), text: "We offer private CLOUD AI for SMEs.")
        let reversed = OutgoingMessage(from: acc.address, to: [acc.address], subject: acc.tagged("two"), text: "AI in the cloud, not the other way.")
        _ = try await imap.append(folder: "INBOX", message: inOrder.render())
        _ = try await imap.append(folder: "INBOX", message: reversed.render())
        await imap.logout()
        let phrase = try await mail.search(in: "INBOX", text: "\"cloud ai\"").filter { $0.subject.contains(acc.token) }
        XCTAssertEqual(phrase.map(\.subject), [inOrder.subject], "the phrase, any case")
        let words = try await mail.search(in: "INBOX", text: "cloud ai").filter { $0.subject.contains(acc.token) }
        XCTAssertEqual(Set(words.map(\.subject)), [inOrder.subject, reversed.subject], "loose words: both")
        await acc.cleanUp(mail)
        await mail.disconnect()
    }
}
