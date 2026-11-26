import Foundation

public enum IMAPError: Error, LocalizedError, Equatable {
    case greeting(String)
    case commandFailed(command: String, status: String, text: String)
    case startTLSRequired
    case authenticationFailed(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .greeting(let t): return "Unexpected server greeting: \(t)"
        case .commandFailed(let c, let s, let t): return "IMAP \(c) failed (\(s)): \(t)"
        case .startTLSRequired: return "The server does not offer STARTTLS; refusing to send the password unencrypted."
        case .authenticationFailed(let t): return "Login failed: \(t)"
        case .protocolError(let t): return "IMAP protocol error: \(t)"
        }
    }
}

public enum SpecialUse: String, Codable, Sendable, CaseIterable {
    case inbox, drafts, sent, archive, junk, trash, all, flagged

    /// Display order in the sidebar.
    public var order: Int { Self.allCases.firstIndex(of: self) ?? 99 }

    static func from(flags: [String]) -> SpecialUse? {
        for f in flags.map({ $0.lowercased() }) {
            switch f {
            case "\\sent": return .sent
            case "\\drafts": return .drafts
            case "\\trash": return .trash
            case "\\junk": return .junk
            case "\\archive": return .archive
            case "\\all": return .all
            case "\\flagged": return .flagged
            default: continue
            }
        }
        return nil
    }

    /// Fallback by well-known names (English, German, common Outlook/Exchange names).
    static func from(name: String) -> SpecialUse? {
        switch name.lowercased() {
        case "inbox": return .inbox
        case "sent", "sent items", "sent messages", "sent mail", "gesendet", "gesendete elemente", "gesendete objekte": return .sent
        case "drafts", "draft", "entwürfe", "entwurf": return .drafts
        case "trash", "deleted items", "deleted messages", "papierkorb", "gelöschte elemente", "gelöschte objekte": return .trash
        case "junk", "spam", "junk e-mail", "junk-e-mail", "junk email": return .junk
        case "archive", "archiv", "archives": return .archive
        default: return nil
        }
    }
}

public struct IMAPFolder: Codable, Hashable, Sendable, Identifiable {
    /// Decoded path, e.g. "INBOX/Entwürfe".
    public var path: String
    /// Path as sent to the server (modified UTF-7).
    public var serverPath: String
    public var name: String
    public var delimiter: String
    public var flags: [String]
    public var specialUse: SpecialUse?
    public var unseen: Int
    public var total: Int

    public var id: String { serverPath }
    public var isSelectable: Bool { !flags.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame || $0.caseInsensitiveCompare("\\NonExistent") == .orderedSame } }
    /// Nesting level for indentation.
    public var depth: Int { delimiter.isEmpty ? 0 : path.components(separatedBy: delimiter).count - 1 }
}

public struct MessageSummary: Codable, Hashable, Sendable, Identifiable {
    public var uid: UInt32
    public var folder: String
    public var flags: Set<String>
    public var date: Date
    public var size: Int
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var subject: String
    public var messageID: String?
    public var hasAttachments: Bool
    public var isInvite: Bool

    public var id: String { "\(folder)#\(uid)" }
    public var isSeen: Bool { flags.contains("\\Seen") }
    public var isFlagged: Bool { flags.contains("\\Flagged") }
    public var isAnswered: Bool { flags.contains("\\Answered") }
    public var isDraft: Bool { flags.contains("\\Draft") }
}

public struct SelectedMailbox: Sendable, Equatable {
    public var path: String
    public var exists: Int
    public var uidValidity: UInt32
    public var uidNext: UInt32
}

public enum IdleResult: Sendable {
    case changed
    case timeout
}

/// IMAP4rev1 client. One instance = one connection; commands are serialised by the actor.
public actor IMAPClient {
    public let endpoint: ServerEndpoint
    private var io: BufferedStream?
    private var tagCounter = 0
    public private(set) var capabilities: Set<String> = []
    public private(set) var selected: SelectedMailbox?
    /// Set while an IDLE is running; other commands must wait (use a separate client for IDLE).
    private var idleDone: DoneSender?

    public init(endpoint: ServerEndpoint) {
        self.endpoint = endpoint
    }

    public var isConnected: Bool { io != nil }

    // MARK: Connection

    public func connect(user: String, password: String) async throws {
        let stream = try await Transport.connect(endpoint)
        let io = BufferedStream(stream)
        self.io = io
        do {
            let greeting = try await readResponse()
            guard case .untagged(let g) = greeting, let status = g.first?.text?.uppercased(), status == "OK" || status == "PREAUTH" else {
                throw IMAPError.greeting("\(greeting)")
            }
            try await refreshCapabilities()
            if endpoint.security == .startTLS {
                guard capabilities.contains("STARTTLS") else { throw IMAPError.startTLSRequired }
                _ = try await command("STARTTLS")
                try await io.startTLS()
                try await refreshCapabilities()
            }
            do {
                _ = try await command([.text("LOGIN "), .astring(user), .text(" "), .astring(password)], name: "LOGIN")
            } catch IMAPError.commandFailed(_, _, let text) {
                throw IMAPError.authenticationFailed(text)
            }
            try await refreshCapabilities()
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        io?.close()
        io = nil
        selected = nil
    }

    public func logout() async {
        _ = try? await command("LOGOUT")
        disconnect()
    }

    private func refreshCapabilities() async throws {
        let r = try await command("CAPABILITY")
        for line in r.untagged where line.first?.text?.uppercased() == "CAPABILITY" {
            capabilities = Set(line.dropFirst().compactMap { $0.text?.uppercased() })
        }
    }

    public func has(_ cap: String) -> Bool { capabilities.contains(cap.uppercased()) }

    // MARK: Low level

    public enum Part: Sendable {
        case text(String)
        /// atom/quoted/literal as needed
        case astring(String)
        case literal(Data)
    }

    public struct Result: Sendable {
        public var untagged: [[IMAPValue]]
        public var code: [IMAPValue]?
        public var text: String
    }

    @discardableResult
    public func command(_ text: String) async throws -> Result {
        try await command([.text(text)], name: String(text.split(separator: " ").first ?? ""))
    }

    @discardableResult
    public func command(_ parts: [Part], name: String) async throws -> Result {
        guard let io else { throw TransportError.closed }
        guard idleDone == nil else { throw IMAPError.protocolError("connection is in IDLE; use a separate client") }
        tagCounter += 1
        let tag = "S\(tagCounter)"
        var pending = Data("\(tag) ".utf8)
        let literalPlus = capabilities.contains("LITERAL+")
        for part in parts {
            switch part {
            case .text(let t):
                pending.append(Data(t.utf8))
            case .astring(let s):
                if IMAPClient.isSafeQuoted(s) {
                    pending.append(Data(IMAPClient.quote(s).utf8))
                } else {
                    try await sendLiteral(Data(s.utf8), before: &pending, io: io, nonSync: literalPlus)
                }
            case .literal(let d):
                try await sendLiteral(d, before: &pending, io: io, nonSync: literalPlus)
            }
        }
        pending.append(Data("\r\n".utf8))
        do {
            try await io.write(pending)
            var untagged: [[IMAPValue]] = []
            while true {
                let r = try await readResponse()
                switch r {
                case .untagged(let values):
                    untagged.append(values)
                    track(values)
                case .continuation:
                    continue
                case .tagged(let t, let status, let code, let text):
                    guard t == tag else { continue }
                    if status != "OK" {
                        throw IMAPError.commandFailed(command: name, status: status, text: text)
                    }
                    return Result(untagged: untagged, code: code, text: text)
                }
            }
        } catch let e as TransportError {
            disconnect()
            throw e
        }
    }

    private func sendLiteral(_ data: Data, before pending: inout Data, io: BufferedStream, nonSync: Bool) async throws {
        if nonSync {
            pending.append(Data("{\(data.count)+}\r\n".utf8))
            pending.append(data)
            return
        }
        pending.append(Data("{\(data.count)}\r\n".utf8))
        try await io.write(pending)
        pending = Data()
        // Wait for the continuation request before sending the literal.
        while true {
            let r = try await readResponse()
            if case .continuation = r { break }
            if case .tagged(_, let status, _, let text) = r {
                throw IMAPError.commandFailed(command: "literal", status: status, text: text)
            }
            if case .untagged(let v) = r { track(v) }
        }
        pending.append(data)
    }

    /// Reads a full response including any literals.
    func readResponse() async throws -> IMAPResponse {
        guard let io else { throw TransportError.closed }
        var raw = Data()
        while true {
            let line = try await io.readLine()
            raw.append(line)
            if let n = IMAPParser.trailingLiteralLength(line) {
                raw.append(Data("\r\n".utf8))
                raw.append(try await io.readExactly(n))
                continue
            }
            break
        }
        return IMAPParser.parse(raw)
    }

    private func track(_ values: [IMAPValue]) {
        guard values.count >= 2, var sel = selected else { return }
        if values[1].text?.uppercased() == "EXISTS", let n = values[0].int {
            sel.exists = n
            selected = sel
        } else if values[1].text?.uppercased() == "EXPUNGE" {
            sel.exists = max(0, sel.exists - 1)
            selected = sel
        }
    }

    static func isSafeQuoted(_ s: String) -> Bool {
        s.utf8.count < 1000 && s.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Folders

    public func listFolders() async throws -> [IMAPFolder] {
        let useListStatus = has("LIST-STATUS")
        let useSpecial = has("SPECIAL-USE") && has("LIST-EXTENDED")
        var cmd = "LIST \"\" \"*\""
        var returns: [String] = []
        if useSpecial { returns.append("SPECIAL-USE") }
        if useListStatus { returns.append("STATUS (MESSAGES UNSEEN)") }
        if !returns.isEmpty { cmd += " RETURN (\(returns.joined(separator: " ")))" }
        let r = try await command(cmd)
        var folders: [IMAPFolder] = []
        var status: [String: (Int, Int)] = [:]
        for line in r.untagged {
            guard let kind = line.first?.text?.uppercased() else { continue }
            if kind == "LIST", line.count >= 4 {
                let flags = line[1].list?.compactMap(\.text) ?? []
                let delimiter = line[2].text ?? ""
                let serverPath = line[3].text ?? ""
                let path = ModifiedUTF7.decode(serverPath)
                let name = delimiter.isEmpty ? path : (path.components(separatedBy: delimiter).last ?? path)
                var special = SpecialUse.from(flags: flags)
                if serverPath.uppercased() == "INBOX" { special = .inbox }
                folders.append(IMAPFolder(path: serverPath.uppercased() == "INBOX" ? "INBOX" : path, serverPath: serverPath, name: serverPath.uppercased() == "INBOX" ? "Inbox" : name, delimiter: delimiter, flags: flags, specialUse: special, unseen: 0, total: 0))
            } else if kind == "STATUS", line.count >= 3, let mailbox = line[1].text {
                status[mailbox] = IMAPClient.statusCounts(line[2])
            }
        }
        // Name-based special-use detection only where the server did not mark one.
        let marked = Set(folders.compactMap(\.specialUse))
        for idx in folders.indices where folders[idx].specialUse == nil {
            if let guess = SpecialUse.from(name: folders[idx].name), !marked.contains(guess), folders[idx].depth <= 1 {
                folders[idx].specialUse = guess
            }
        }
        for idx in folders.indices {
            if let s = status[folders[idx].serverPath] {
                folders[idx].total = s.0
                folders[idx].unseen = s.1
            } else if !useListStatus, folders[idx].isSelectable {
                if let s = try? await self.status(folders[idx].serverPath) {
                    folders[idx].total = s.0
                    folders[idx].unseen = s.1
                }
            }
        }
        return folders.sorted { a, b in
            let ao = a.specialUse?.order ?? 50, bo = b.specialUse?.order ?? 50
            if ao != bo { return ao < bo }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    /// (messages, unseen)
    public func status(_ serverPath: String) async throws -> (Int, Int) {
        let r = try await command([.text("STATUS "), .astring(serverPath), .text(" (MESSAGES UNSEEN)")], name: "STATUS")
        for line in r.untagged where line.first?.text?.uppercased() == "STATUS" && line.count >= 3 {
            return IMAPClient.statusCounts(line[2])
        }
        return (0, 0)
    }

    static func statusCounts(_ v: IMAPValue) -> (Int, Int) {
        let items = v.list ?? []
        var messages = 0, unseen = 0
        var k = 0
        while k + 1 < items.count {
            switch items[k].text?.uppercased() {
            case "MESSAGES": messages = items[k + 1].int ?? 0
            case "UNSEEN": unseen = items[k + 1].int ?? 0
            default: break
            }
            k += 2
        }
        return (messages, unseen)
    }

    public func createFolder(_ path: String) async throws {
        try await command([.text("CREATE "), .astring(ModifiedUTF7.encode(path))], name: "CREATE")
        _ = try? await command([.text("SUBSCRIBE "), .astring(ModifiedUTF7.encode(path))], name: "SUBSCRIBE")
    }

    public func renameFolder(_ serverPath: String, to newPath: String) async throws {
        if selected?.path == serverPath { _ = try? await command("CLOSE"); selected = nil }
        try await command([.text("RENAME "), .astring(serverPath), .text(" "), .astring(ModifiedUTF7.encode(newPath))], name: "RENAME")
    }

    public func deleteFolder(_ serverPath: String) async throws {
        if selected?.path == serverPath { _ = try? await command("CLOSE"); selected = nil }
        try await command([.text("DELETE "), .astring(serverPath)], name: "DELETE")
    }

    // MARK: Messages

    @discardableResult
    public func select(_ serverPath: String, force: Bool = false) async throws -> SelectedMailbox {
        if !force, let s = selected, s.path == serverPath { return s }
        let r = try await command([.text("SELECT "), .astring(serverPath)], name: "SELECT")
        var sel = SelectedMailbox(path: serverPath, exists: 0, uidValidity: 0, uidNext: 0)
        for line in r.untagged {
            if line.count >= 2, line[1].text?.uppercased() == "EXISTS" { sel.exists = line[0].int ?? 0 }
            if let code = line.first(where: { $0.list?.first == .atom("[") })?.list, code.count >= 3 {
                switch code[1].text?.uppercased() {
                case "UIDVALIDITY": sel.uidValidity = UInt32(code[2].text ?? "") ?? 0
                case "UIDNEXT": sel.uidNext = UInt32(code[2].text ?? "") ?? 0
                default: break
                }
            }
        }
        selected = sel
        return sel
    }

    static let summaryItems = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID CONTENT-TYPE)])"

    /// Newest-first page of summaries. Page 0 = most recent `pageSize` messages.
    public func summaries(folder serverPath: String, page: Int, pageSize: Int = 50) async throws -> (messages: [MessageSummary], total: Int) {
        let sel = try await select(serverPath, force: page == 0)
        guard sel.exists > 0 else { return ([], 0) }
        let high = sel.exists - page * pageSize
        guard high >= 1 else { return ([], sel.exists) }
        let low = max(1, high - pageSize + 1)
        let r = try await command("FETCH \(low):\(high) \(IMAPClient.summaryItems)")
        let list = r.untagged.compactMap { IMAPClient.summary(from: $0, folder: serverPath) }
        return (list.sorted { $0.date > $1.date }, sel.exists)
    }

    public func summaries(folder serverPath: String, uids: [UInt32]) async throws -> [MessageSummary] {
        guard !uids.isEmpty else { return [] }
        try await select(serverPath)
        let r = try await command("UID FETCH \(IMAPClient.uidSet(uids)) \(IMAPClient.summaryItems)")
        return r.untagged.compactMap { IMAPClient.summary(from: $0, folder: serverPath) }.sorted { $0.date > $1.date }
    }

    /// Server-side search in subject, from, to and body. Returns newest `limit` matches.
    public func search(folder serverPath: String, text: String, limit: Int = 100) async throws -> [MessageSummary] {
        try await select(serverPath)
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let ascii = q.unicodeScalars.allSatisfy(\.isASCII)
        var parts: [Part] = [.text(ascii ? "UID SEARCH OR OR OR SUBJECT " : "UID SEARCH CHARSET UTF-8 OR OR OR SUBJECT ")]
        for key in ["FROM", "TO", "BODY"] {
            parts.append(.astring(q))
            parts.append(.text(" \(key) "))
        }
        parts.append(.astring(q))
        let r = try await command(parts, name: "SEARCH")
        var uids: [UInt32] = []
        for line in r.untagged where line.first?.text?.uppercased() == "SEARCH" {
            uids += line.dropFirst().compactMap { $0.text.flatMap { UInt32($0) } }
        }
        return try await summaries(folder: serverPath, uids: Array(uids.sorted().suffix(limit)))
    }

    /// Full RFC 5322 source of one message (does not set \Seen).
    public func fetchMessage(folder serverPath: String, uid: UInt32) async throws -> Data {
        try await select(serverPath)
        let r = try await command("UID FETCH \(uid) (UID BODY.PEEK[])")
        for line in r.untagged {
            guard line.count >= 3, line[1].text?.uppercased() == "FETCH", let items = line[2].list else { continue }
            let map = IMAPClient.fetchMap(items)
            if map["UID"]?.int.map(UInt32.init) == uid, let body = map["BODY[]"]?.data { return body }
        }
        throw IMAPError.protocolError("message \(uid) not found")
    }

    public func setFlags(folder serverPath: String, uids: [UInt32], add: [String] = [], remove: [String] = []) async throws {
        guard !uids.isEmpty else { return }
        try await select(serverPath)
        if !add.isEmpty { try await command("UID STORE \(IMAPClient.uidSet(uids)) +FLAGS.SILENT (\(add.joined(separator: " ")))") }
        if !remove.isEmpty { try await command("UID STORE \(IMAPClient.uidSet(uids)) -FLAGS.SILENT (\(remove.joined(separator: " ")))") }
    }

    public func move(folder serverPath: String, uids: [UInt32], to target: String) async throws {
        guard !uids.isEmpty else { return }
        try await select(serverPath)
        let set = IMAPClient.uidSet(uids)
        if has("MOVE") {
            try await command([.text("UID MOVE \(set) "), .astring(target)], name: "MOVE")
        } else {
            try await command([.text("UID COPY \(set) "), .astring(target)], name: "COPY")
            try await expunge(uids: uids)
        }
    }

    /// Permanently removes messages.
    public func expunge(folder serverPath: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await select(serverPath)
        try await expunge(uids: uids)
    }

    private func expunge(uids: [UInt32]) async throws {
        let set = IMAPClient.uidSet(uids)
        try await command("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        if has("UIDPLUS") {
            try await command("UID EXPUNGE \(set)")
        } else {
            try await command("EXPUNGE")
        }
    }

    /// Appends a message; returns its UID when the server supports UIDPLUS.
    @discardableResult
    public func append(folder serverPath: String, message: Data, flags: [String] = []) async throws -> UInt32? {
        let f = flags.isEmpty ? "" : "(\(flags.joined(separator: " "))) "
        let r = try await command([.text("APPEND "), .astring(serverPath), .text(" \(f)"), .literal(message)], name: "APPEND")
        if let code = r.code, code.count >= 3, code[0].text?.uppercased() == "APPENDUID" {
            return code[2].text.flatMap { UInt32($0) }
        }
        if selected?.path == serverPath { selected = nil } // force re-select to see the new message
        return nil
    }

    // MARK: IDLE

    /// Waits for mailbox changes with IDLE (or polls with NOOP if unsupported). Returns after a change or `timeout`.
    public func idle(folder serverPath: String, timeout: TimeInterval = 25 * 60) async throws -> IdleResult {
        try await select(serverPath)
        guard let io else { throw TransportError.closed }
        guard has("IDLE") else {
            try await Task.sleep(nanoseconds: UInt64(min(timeout, 60) * 1_000_000_000))
            let before = selected?.exists
            let r = try await command("NOOP")
            let changed = r.untagged.contains { $0.count >= 2 && ["EXISTS", "EXPUNGE", "FETCH"].contains($0[1].text?.uppercased() ?? "") }
            return changed || before != selected?.exists ? .changed : .timeout
        }
        tagCounter += 1
        let tag = "S\(tagCounter)"
        try await io.write("\(tag) IDLE\r\n")
        let done = DoneSender(io: io)
        idleDone = done
        defer { idleDone = nil }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await done.send()
        }
        defer { timer.cancel() }
        var result = IdleResult.timeout
        do {
            while true {
                let r = try await readResponse()
                switch r {
                case .continuation:
                    continue
                case .untagged(let v):
                    track(v)
                    if v.count >= 2, ["EXISTS", "EXPUNGE", "FETCH", "RECENT"].contains(v[1].text?.uppercased() ?? "") {
                        result = .changed
                        await done.send()
                    }
                case .tagged(let t, let status, _, let text):
                    guard t == tag else { continue }
                    if status != "OK" { throw IMAPError.commandFailed(command: "IDLE", status: status, text: text) }
                    return result
                }
            }
        } catch let e as TransportError {
            disconnect()
            throw e
        }
    }

    /// Stops IDLE from outside the read loop (timer, change or cancellation).
    public func stopIdle() async {
        await idleDone?.send()
    }

    // MARK: Helpers

    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var start = sorted.first ?? 0
        var prev = start
        for u in sorted.dropFirst() {
            if u == prev + 1 { prev = u; continue }
            ranges.append(start == prev ? "\(start)" : "\(start):\(prev)")
            start = u
            prev = u
        }
        if !sorted.isEmpty { ranges.append(start == prev ? "\(start)" : "\(start):\(prev)") }
        return ranges.joined(separator: ",")
    }

    static func fetchMap(_ items: [IMAPValue]) -> [String: IMAPValue] {
        var map: [String: IMAPValue] = [:]
        var k = 0
        while k + 1 < items.count {
            var key = items[k].text?.uppercased() ?? ""
            // BODY[HEADER.FIELDS (FROM ...)] → normalise to BODY[HEADER.FIELDS]; strip partial "<0>"
            if key.hasPrefix("BODY[HEADER.FIELDS") { key = "BODY[HEADER.FIELDS]" }
            if let lt = key.firstIndex(of: "<"), key.hasSuffix(">") { key = String(key[..<lt]) }
            map[key] = items[k + 1]
            k += 2
        }
        return map
    }

    static let imapDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static func summary(from line: [IMAPValue], folder: String) -> MessageSummary? {
        guard line.count >= 3, line[1].text?.uppercased() == "FETCH", let items = line[2].list else { return nil }
        let map = fetchMap(items)
        guard let uid = map["UID"]?.int else { return nil }
        let headers = MessageHeaders(parsing: map["BODY[HEADER.FIELDS]"]?.data ?? Data())
        let internalDate = map["INTERNALDATE"]?.text.flatMap { imapDate.date(from: $0.trimmingCharacters(in: .whitespaces)) }
        let date = headers["Date"].flatMap(RFC822Date.parse) ?? internalDate ?? Date(timeIntervalSince1970: 0)
        let ct = HeaderValue(headers["Content-Type"] ?? "text/plain")
        return MessageSummary(
            uid: UInt32(uid),
            folder: folder,
            flags: Set(map["FLAGS"]?.list?.compactMap(\.text) ?? []),
            date: date,
            size: map["RFC822.SIZE"]?.int ?? 0,
            from: EmailAddress.parseList(headers["From"] ?? ""),
            to: EmailAddress.parseList(headers["To"] ?? ""),
            cc: EmailAddress.parseList(headers["Cc"] ?? ""),
            subject: EncodedWord.decode(headers["Subject"] ?? ""),
            messageID: headers["Message-ID"],
            hasAttachments: ct.value == "multipart/mixed",
            isInvite: ct.value == "text/calendar" || (ct.params["method"] != nil)
        )
    }
}

/// Ensures DONE is written exactly once per IDLE.
actor DoneSender {
    private let io: BufferedStream
    private var sent = false

    init(io: BufferedStream) {
        self.io = io
    }

    func send() async {
        guard !sent else { return }
        sent = true
        try? await io.write("DONE\r\n")
    }
}
