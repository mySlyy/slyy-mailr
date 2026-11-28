import Foundation

/// High-level mail operations for one account. Keeps one command connection and reconnects on demand.
public actor MailService {
    public let account: AccountSettings
    private let password: String
    /// OAuth accounts: a fresh access token for every new connection (tokens live about an hour).
    private let tokenSource: (@Sendable () async throws -> String)?
    private var client: IMAPClient?
    private var folderCache: [IMAPFolder] = []
    public let cache: MessageCache?

    public init(account: AccountSettings, password: String, cache: MessageCache? = nil, tokenSource: (@Sendable () async throws -> String)? = nil) {
        self.account = account
        self.password = password
        self.cache = cache
        self.tokenSource = tokenSource
    }

    /// The password, or for OAuth accounts a current access token.
    func secret() async throws -> String {
        if let tokenSource { return try await tokenSource() }
        return password
    }

    /// Verifies IMAP and SMTP credentials (used by account setup). For OAuth accounts `password` is the access token.
    public static func verify(_ account: AccountSettings, password: String) async throws {
        let imap = IMAPClient(endpoint: account.imap)
        try await imap.connect(user: account.username, password: password, oauth: account.usesOAuth)
        await imap.logout()
        let smtp = SMTPClient(endpoint: account.smtp)
        try await smtp.connect(user: account.username, password: password, oauth: account.usesOAuth)
        await smtp.quit()
    }

    func imap() async throws -> IMAPClient {
        if let client, await client.isConnected { return client }
        let c = IMAPClient(endpoint: account.imap)
        try await c.connect(user: account.username, password: try await secret(), oauth: account.usesOAuth)
        client = c
        return c
    }

    /// One IMAP operation at a time: an operation is several commands (SELECT + FETCH) that must not interleave.
    private let lock = AsyncLock()

    /// Runs an IMAP operation exclusively, reconnecting once if the connection dropped.
    /// `retry: false` for operations that are not safe to repeat (APPEND, MOVE/COPY, EXPUNGE, folder CREATE/RENAME/DELETE):
    /// the server may have carried them out before the connection dropped, so a replay could e.g. file a second Sent copy.
    /// Those surface the error instead; the dropped connection is still discarded so the next call reconnects.
    func withIMAP<T>(retry: Bool = true, _ op: (IMAPClient) async throws -> T) async throws -> T {
        try await lock.run {
            do {
                return try await op(try await imap())
            } catch let e as TransportError {
                client = nil
                guard retry else { throw e }
                return try await op(try await imap())
            }
        }
    }

    public func disconnect() async {
        await client?.logout()
        client = nil
    }

    // MARK: Folders & messages

    public func folders() async throws -> [IMAPFolder] {
        let list = try await withIMAP { try await $0.listFolders() }
        folderCache = list
        return list
    }

    public func folder(_ use: SpecialUse) async throws -> IMAPFolder? {
        if folderCache.isEmpty { _ = try await folders() }
        return folderCache.first { $0.specialUse == use }
    }

    /// Server path of a special folder, creating it if missing.
    public func folderPath(_ use: SpecialUse) async throws -> String {
        if let f = try await folder(use) { return f.serverPath }
        let name: String
        switch use {
        case .sent: name = "Sent"
        case .drafts: name = "Drafts"
        case .trash: name = "Trash"
        case .junk: name = "Junk"
        case .archive: name = "Archive"
        case .inbox: return "INBOX"
        case .all, .flagged: name = use.rawValue.capitalized
        }
        try await withIMAP(retry: false) { try await $0.createFolder(name) }
        _ = try await folders()
        return ModifiedUTF7.encode(name)
    }

    public func messages(in folder: String, page: Int) async throws -> (messages: [MessageSummary], total: Int) {
        let r = try await withIMAP { try await $0.summaries(folder: folder, page: page) }
        if page == 0 { cache?.storeSummaries(r.messages, folder: folder, account: account.id) }
        return r
    }

    /// Unread messages of a folder (the "n unread" filter), newest first, each once.
    public func unread(in folder: String) async throws -> [MessageSummary] {
        try await withIMAP { try await $0.unread(folder: folder) }
    }

    public func search(in folder: String, text: String) async throws -> [MessageSummary] {
        try await withIMAP { try await $0.search(folder: folder, text: text) }
    }

    /// Full message; served from cache when present. Marks it as read on the server.
    public func message(_ s: MessageSummary, markSeen: Bool = true) async throws -> ParsedMessage {
        let data: Data
        if let cached = cache?.body(uid: s.uid, folder: s.folder, account: account.id) {
            data = cached
        } else {
            data = try await withIMAP { try await $0.fetchMessage(folder: s.folder, uid: s.uid) }
            cache?.storeBody(data, uid: s.uid, folder: s.folder, account: account.id)
        }
        if markSeen && !s.isSeen {
            try? await withIMAP { try await $0.setFlags(folder: s.folder, uids: [s.uid], add: ["\\Seen"]) }
        }
        return ParsedMessage(data: data)
    }

    /// The whole conversation of a message: from its folder and from Sent (your replies), oldest first.
    public func conversation(of s: MessageSummary) async throws -> [MessageSummary] {
        var ids = [s.messageID].compactMap { $0 } + (s.references ?? []) + [s.inReplyTo].compactMap { $0 }
        if let root = s.references?.first { ids.insert(root, at: 0) }
        guard !ids.isEmpty else { return [s] }
        var folders = [s.folder]
        if let sent = try? await folderPath(.sent), sent != s.folder { folders.append(sent) }
        var all: [MessageSummary] = []
        for f in folders {
            all += (try? await withIMAP { try await $0.conversation(folder: f, messageIDs: ids) }) ?? []
        }
        // Second round: replies to replies that only reference intermediate messages.
        let known = Set(all.compactMap(\.messageID))
        let more = known.subtracting(ids)
        if !more.isEmpty {
            for f in folders {
                all += (try? await withIMAP { try await $0.conversation(folder: f, messageIDs: Array(more)) }) ?? []
            }
        }
        var seen = Set<String>()
        let unique = all.filter { m in seen.insert(m.messageID ?? m.id).inserted }
        let thread = MessageThreads.group(unique).first { t in t.messages.contains { $0.id == s.id || ($0.messageID != nil && $0.messageID == s.messageID) } }
        return thread?.messages ?? [s]
    }

    public func setFlag(_ flag: String, on: Bool, for messages: [MessageSummary]) async throws {
        for (folder, group) in Dictionary(grouping: messages, by: \.folder) {
            let uids = group.map(\.uid)
            try await withIMAP { try await $0.setFlags(folder: folder, uids: uids, add: on ? [flag] : [], remove: on ? [] : [flag]) }
        }
    }

    public func move(_ messages: [MessageSummary], to target: String) async throws {
        for (folder, group) in Dictionary(grouping: messages, by: \.folder) where folder != target {
            let uids = group.map(\.uid)
            try await withIMAP(retry: false) { try await $0.move(folder: folder, uids: uids, to: target) }
            for u in uids { cache?.removeBody(uid: u, folder: folder, account: account.id) }
        }
    }

    /// Moves to Trash, or deletes permanently when already in Trash.
    public func delete(_ messages: [MessageSummary]) async throws {
        let trash = try await folderPath(.trash)
        let inTrash = messages.filter { $0.folder == trash }
        let others = messages.filter { $0.folder != trash }
        if !others.isEmpty { try await move(others, to: trash) }
        if !inTrash.isEmpty {
            let uids = inTrash.map(\.uid)
            try await withIMAP(retry: false) { try await $0.expunge(folder: trash, uids: uids) }
        }
    }

    /// Undo of `delete`: moves messages that were moved to the Trash back to the folder they came from
    /// (`folder` of each summary), found in the Trash by Message-ID (the newest copy). Returns how many came back;
    /// a message without Message-ID, or no longer in the Trash, is skipped.
    @discardableResult
    public func restoreFromTrash(_ messages: [MessageSummary]) async throws -> Int {
        let trash = try await folderPath(.trash)
        var byFolder: [String: [UInt32]] = [:]
        for m in messages where m.folder != trash {
            guard let id = m.messageID else { continue }
            let found = try await withIMAP { try await self.searchMessageID(id, in: trash, client: $0) }
            if let uid = found.max() { byFolder[m.folder, default: []].append(uid) }
        }
        for (folder, uids) in byFolder {
            try await withIMAP(retry: false) { try await $0.move(folder: trash, uids: uids, to: folder) }
        }
        return byFolder.values.reduce(0) { $0 + $1.count }
    }

    /// Archive folder; on Gmail (no \\Archive, but \\All) archiving means moving to All Mail, which removes the Inbox label.
    public func archive(_ messages: [MessageSummary]) async throws {
        if try await folder(.archive) == nil, let all = try await folder(.all) {
            try await move(messages, to: all.serverPath)
            return
        }
        try await move(messages, to: try await folderPath(.archive))
    }

    public func createFolder(_ name: String) async throws {
        try await withIMAP(retry: false) { try await $0.createFolder(name) }
    }

    public func renameFolder(_ f: IMAPFolder, to name: String) async throws {
        let newPath = f.delimiter.isEmpty || f.depth == 0 ? name : (f.path.components(separatedBy: f.delimiter).dropLast() + [name]).joined(separator: f.delimiter)
        try await withIMAP(retry: false) { try await $0.renameFolder(f.serverPath, to: newPath) }
    }

    public func deleteFolder(_ f: IMAPFolder) async throws {
        try await withIMAP(retry: false) { try await $0.deleteFolder(f.serverPath) }
    }

    // MARK: Sending

    /// Sends via SMTP, then files a copy in Sent and removes the draft it came from.
    public func send(_ message: OutgoingMessage, replacingDraft draftUID: UInt32? = nil) async throws {
        let data = message.render()
        let smtp = SMTPClient(endpoint: account.smtp, heloName: account.domain.isEmpty ? "slyy-mail.local" : account.domain)
        try await smtp.connect(user: account.username, password: try await secret(), oauth: account.usesOAuth)
        do {
            try await smtp.send(from: message.from.address, recipients: message.envelopeRecipients, data: data)
        } catch {
            await smtp.quit()
            throw error
        }
        await smtp.quit()
        if !account.serverSavesSent, let sent = try? await folderPath(.sent) {
            _ = try? await withIMAP(retry: false) { try await $0.append(folder: sent, message: data, flags: ["\\Seen"]) }
        }
        // The draft this came from: by UID if known, else by its Message-ID (drafts keep one across autosaves).
        if let drafts = try? await folderPath(.drafts) {
            try? await withIMAP(retry: false) { c in
                let uids = try await draftUIDs(c, drafts: drafts, messageID: message.messageID, known: draftUID)
                try await c.expunge(folder: drafts, uids: uids)
            }
        }
    }

    /// Saves a draft (replacing the previous version); returns the new UID.
    /// Without UIDPLUS the APPEND reports no UID, so the copy is found by its Message-ID:
    /// pass the same `messageID` for every save of one draft.
    public func saveDraft(_ message: OutgoingMessage, replacing oldUID: UInt32?) async throws -> UInt32? {
        let drafts = try await folderPath(.drafts)
        var uid = try await withIMAP(retry: false) { try await $0.append(folder: drafts, message: message.render(), flags: ["\\Draft", "\\Seen"]) }
        var stale = oldUID.map { [$0] } ?? []
        if uid == nil {
            // Every copy of this draft; the newest (highest UID) is the one just appended.
            let found = (try? await withIMAP { try await self.searchMessageID(message.messageID, in: drafts, client: $0) }) ?? []
            uid = found.max()
            stale += found
        }
        stale = Array(Set(stale.filter { $0 != uid })).sorted()
        if !stale.isEmpty { try? await withIMAP(retry: false) { try await $0.expunge(folder: drafts, uids: stale) } }
        return uid
    }

    /// UIDs of the draft copies to remove: `known` if given, else every copy with this Message-ID.
    private func draftUIDs(_ c: IMAPClient, drafts: String, messageID: String, known: UInt32?) async throws -> [UInt32] {
        if let known { return [known] }
        return try await searchMessageID(messageID, in: drafts, client: c)
    }

    /// `UID SEARCH HEADER Message-ID <id>` in one folder.
    private func searchMessageID(_ messageID: String, in folder: String, client c: IMAPClient) async throws -> [UInt32] {
        let id = messageID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return [] }
        _ = try await c.select(folder)
        let r = try await c.command([.text("UID SEARCH HEADER Message-ID "), .astring(id)], name: "SEARCH")
        var uids: [UInt32] = []
        for line in r.untagged where line.first?.text?.uppercased() == "SEARCH" {
            uids += line.dropFirst().compactMap { $0.text.flatMap { UInt32($0) } }
        }
        return uids
    }

    /// Sends an iTIP message (REQUEST/CANCEL/REPLY) as an email.
    public func sendCalendarMail(to recipients: [EmailAddress], subject: String, text: String, method: String, ics: String, from: EmailAddress? = nil) async throws {
        guard !recipients.isEmpty else { return }
        var msg = OutgoingMessage(from: from ?? account.address, to: recipients, subject: subject, text: text)
        msg.calendar = CalendarAttachment(method: method, ics: ics)
        let data = msg.render()
        let smtp = SMTPClient(endpoint: account.smtp, heloName: account.domain.isEmpty ? "slyy-mail.local" : account.domain)
        try await smtp.connect(user: account.username, password: try await secret(), oauth: account.usesOAuth)
        defer { Task { await smtp.quit() } }
        try await smtp.send(from: msg.from.address, recipients: msg.envelopeRecipients, data: data)
    }
}

/// Watches one folder with IDLE on its own connection and calls `onChange` for new/removed mail.
public actor MailWatcher {
    private let account: AccountSettings
    private let password: String
    private let tokenSource: (@Sendable () async throws -> String)?
    private var task: Task<Void, Never>?
    private var client: IMAPClient?
    /// Length of one backoff step (the delay doubles from 2 steps up to 300). Tests shorten it.
    var backoffUnit: UInt64 = 1_000_000_000

    public init(account: AccountSettings, password: String, tokenSource: (@Sendable () async throws -> String)? = nil) {
        self.account = account
        self.password = password
        self.tokenSource = tokenSource
    }

    public func start(folder: String = "INBOX", onChange: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task { [account, password, tokenSource, backoffUnit] in
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                let c = IMAPClient(endpoint: account.imap)
                do {
                    let secret = try await tokenSource?() ?? password
                    try await c.connect(user: account.username, password: secret, oauth: account.usesOAuth)
                    self.setClient(c)
                    backoff = 2
                    while !Task.isCancelled {
                        let r = try await c.idle(folder: folder, timeout: 25 * 60)
                        if r == .changed { await onChange() }
                    }
                    await c.logout()
                } catch {
                    // Every failed iteration (transport error, NO/BAD on SELECT or IDLE, cancellation) must
                    // release its connection before retrying, or each retry leaks a logged-in connection.
                    await c.logout()
                    try? await Task.sleep(nanoseconds: backoff * backoffUnit)
                    backoff = min(backoff * 2, 300)
                }
            }
        }
    }

    private func setClient(_ c: IMAPClient) {
        client = c
    }

    func setBackoffUnit(_ nanoseconds: UInt64) {
        backoffUnit = nanoseconds
    }

    public func stop() async {
        task?.cancel()
        task = nil
        if let client {
            await client.stopIdle()
            await client.disconnect()
        }
        client = nil
    }
}
