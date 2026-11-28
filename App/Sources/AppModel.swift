import SwiftUI
import SlyyMailKit
import UserNotifications
#if os(macOS)
import AppKit
import Security
#else
import UIKit
#endif

enum SidebarItem: Hashable {
    case folder(String)
    case calendar
}

enum CalendarMode: String, CaseIterable, Identifiable {
    case agenda, day, week, month
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .agenda: return "List"
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
    /// Modes offered in the switcher: the list is for narrow screens.
    static func available(compact: Bool) -> [CalendarMode] { compact ? [.agenda, .day, .month] : [.day, .week, .month] }
    /// Days shown by the agenda list.
    static let agendaDays = 14
}

enum ComposeKind {
    case new
    case to(EmailAddress)
    case reply(ParsedMessage)
    case replyAll(ParsedMessage)
    case forward(ParsedMessage)
    case draft(MessageSummary)
    case mailto(URL)
}

/// Editable state of a message being written.
struct ComposeDraft: Identifiable, Codable {
    var id = UUID()
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: [String] = []
    var draftUID: UInt32?
    /// Message-ID of a draft reopened from the Drafts folder; nil = derived from `id`.
    /// Stays the same for every autosave, so a copy can be found without UIDPLUS.
    var messageID: String?
    var showCcBcc = false
    /// Meeting sent with this mail as an invitation (to the To and Cc recipients); nil = none.
    /// Optional so journals written before meetings existed still decode.
    var meeting: MeetingInvite?
    /// Video call link shown as a card while writing; added at the top of the text when sent.
    var videoURL: URL?
    var lastSaved: Date?
    /// Sender address (account address or an alias); nil = the account address.
    var from: SenderIdentity?
    /// Quoted original of a reply, kept below the new text (shown and sent in the normal colour).
    var quoted = ""
    /// Reopened after a crash (the editor says so).
    var recovered = false
    /// My reply text is written and sent in blue (Settings → Mail).
    var blueReply = false
    /// Colour of my reply text (#RRGGBB), taken from Settings when the reply is started.
    var replyColor = Slyy.replyDefaultHex

    var fullBody: String {
        guard let videoURL else { return body }
        return JitsiRoom.descriptionBlock(videoURL) + "\n" + body
    }

    var plainText: String { fullBody + quoted }

    /// HTML part: my text (blue for replies), then the quote in the default colour.
    var html: String {
        let mine = HTMLText.fromPlain(fullBody)
        let colour = Color.isHex(replyColor) ? replyColor : Slyy.replyDefaultHex // never raw text in the CSS
        let top = blueReply ? "<div style=\"color:\(colour)\">\(mine)</div>" : mine
        guard !quoted.isEmpty else { return top }
        return top + HTMLText.fromPlain(quoted)
    }

    var isEmpty: Bool { to.isEmpty && cc.isEmpty && subject.isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && videoURL == nil && meeting == nil }

    /// What the user can change, without the signature block: equal keys mean nothing was written.
    func contentKey(signature: String) -> String {
        var text = body
        if !signature.isEmpty { text = text.replacingOccurrences(of: "-- \n" + signature, with: "") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [to, cc, bcc, subject, text, attachments.map(\.filename).joined(separator: "/"), videoURL?.absoluteString ?? "", meeting.map(Self.meetingKey) ?? ""].joined(separator: "\u{1F}")
    }

    static func meetingKey(_ m: MeetingInvite) -> String {
        "\(m.uid)|\(m.title)|\(m.start.timeIntervalSince1970)|\(m.minutes)|\(m.videoURL?.absoluteString ?? "")"
    }

    func message(from fallback: EmailAddress) -> OutgoingMessage {
        let m = OutgoingMessage(
            from: from.map { EmailAddress(name: $0.name.isEmpty ? fallback.name : $0.name, address: $0.email) } ?? fallback,
            to: EmailAddress.parseList(to),
            cc: EmailAddress.parseList(cc),
            bcc: EmailAddress.parseList(bcc),
            subject: subject,
            text: plainText,
            html: html,
            attachments: attachments,
            inReplyTo: inReplyTo,
            references: references,
            messageID: messageID ?? "<\(id.uuidString.lowercased())@\(fallback.domain.isEmpty ? "slyy.mail" : fallback.domain)>"
        )
        return m
    }

    init() {}

    init(_ m: OutgoingMessage, signature: String) {
        to = m.to.map(\.headerValue).joined(separator: ", ")
        cc = m.cc.map(\.headerValue).joined(separator: ", ")
        subject = m.subject
        let sig = signature.isEmpty ? "" : "\n\n-- \n" + signature
        if m.inReplyTo != nil {
            // Reply: my text above (editable, blue if enabled), the quote separately below.
            body = sig.isEmpty ? "\n" : sig
            quoted = m.text
        } else {
            body = sig + m.text
        }
        attachments = m.attachments
        inReplyTo = m.inReplyTo
        references = m.references
        showCcBcc = !m.cc.isEmpty
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Account
    private(set) var account: AccountSettings?
    private(set) var mail: MailService?
    private(set) var calendarService: CalendarService?
    private var watcher: MailWatcher?
    let contacts = ContactsStore()
    let cache = MessageCache.standard()

    // Mail
    var sidebarSelection: SidebarItem? = .folder("INBOX")
    private(set) var folders: [IMAPFolder] = []
    private(set) var messages: [MessageSummary] = []
    var totalMessages = 0
    private var page = 0
    var selectedMessageIDs: Set<String> = []
    private(set) var openSummary: MessageSummary?
    private(set) var openMessage: ParsedMessage?
    private(set) var isLoadingMessage = false
    var searchText = ""
    private(set) var isSearching = false
    private(set) var isRefreshing = false
    /// The message being written in a sheet (iOS, and the Mac's fallback before a window can be opened).
    var composeDraft: ComposeDraft?
    #if os(macOS)
    /// Messages being written in their own resizable windows ("compose" WindowGroup), by window value.
    var composeWindows: [UUID: ComposeDraft] = [:]
    /// Opens a compose window for an entry of `composeWindows`; set by the views from `@Environment(\.openWindow)`.
    @ObservationIgnored var openComposeWindow: ((UUID) -> Void)?
    @ObservationIgnored private var lastComposeWindow: UUID?
    #endif

    // Conversations
    /// Group the list by conversation (saved per device).
    var threaded: Bool = UserDefaults.standard.object(forKey: "threaded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(threaded, forKey: "threaded") }
    }
    /// Text size of mail bodies (⌘+ / ⌘− / ⌘0), kept between launches.
    var bodyZoom: Double = UserDefaults.standard.object(forKey: "bodyZoom") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(bodyZoom, forKey: "bodyZoom") }
    }
    static let zoomSteps: [Double] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    func zoomIn() { bodyZoom = Self.zoomSteps.first { $0 > bodyZoom + 0.001 } ?? bodyZoom }
    func zoomOut() { bodyZoom = Self.zoomSteps.last { $0 < bodyZoom - 0.001 } ?? bodyZoom }
    func zoomReset() { bodyZoom = 1 }

    /// A question about the whole mailbox ("Ask Haven" from the search field): its answer replaces the reader.
    var havenQuestion: String?

    /// A message's content without marking it as read (sources, follow-ups).
    func parsedMessage(_ s: MessageSummary) async -> ParsedMessage? {
        try? await mail?.message(s, markSeen: false)
    }

    /// A text field has the keyboard: single-key shortcuts like ⌘A (Reply all) step aside for Select All.
    var typingInField = false

    /// My reply colour (#RRGGBB); default the Slyy dot blue.
    var replyColorHex: String = UserDefaults.standard.string(forKey: "replyColor").flatMap { Color.isHex($0) ? $0 : nil } ?? Slyy.replyDefaultHex {
        didSet { UserDefaults.standard.set(replyColorHex, forKey: "replyColor") }
    }
    var replyColor: Color { Color(sixDigitHex: replyColorHex) ?? Slyy.accent }

    /// Auto-save: open drafts are kept on disk (crash-safe) and in the server's Drafts folder. Default on.
    var autoSave: Bool = UserDefaults.standard.object(forKey: "autoSave") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoSave, forKey: "autoSave")
            if !autoSave { DraftJournal.standard.clear() }
        }
    }
    /// Drafts found on disk after a crash, opened one after the other.
    private(set) var recovered: [ComposeDraft] = []

    /// Write replies in blue, rgba(0, 0, 255, 1) (Settings → Mail).
    var blueReplies: Bool = UserDefaults.standard.object(forKey: "blueReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(blueReplies, forKey: "blueReplies") }
    }
    /// The open message's whole conversation (this folder + Sent), oldest first.
    private(set) var openConversation: [MessageSummary] = []
    /// Reader accordion: which messages of the open conversation are unfolded, and their loaded bodies.
    var expandedMessages: Set<String> = []
    private(set) var conversationBodies: [String: ParsedMessage] = [:]
    /// List accordion: conversations unfolded in the message list.
    var expandedThreads: Set<String> = []

    /// My recent replies (first page of Sent), so a conversation in the Inbox also shows what I answered.
    private(set) var companions: [MessageSummary] = []
    var threads: [MessageThread] { MessageThreads.group(messages, companions: companions) }

    /// The messages of a conversation that live in the current folder: list actions (archive, delete, move)
    /// never touch my copies in Sent.
    func actionable(_ list: [MessageSummary]) -> [MessageSummary] {
        let own = list.filter { $0.folder == currentFolder }
        return own.isEmpty ? list : own
    }

    /// Messages of the thread a list row stands for (only those in the current folder).
    func thread(containing m: MessageSummary) -> [MessageSummary] {
        guard threaded else { return [m] }
        return threads.first { t in t.messages.contains { $0.id == m.id } }?.messages ?? [m]
    }

    // Calendar
    private(set) var calendars: [CalDAVCalendar] = []
    var hiddenCalendars: Set<String> = []
    private(set) var events: [CalendarEvent] = []
    var calendarDate = Date()
    var calendarMode: CalendarMode = .week
    /// iPhone navigation stack (lets notifications open a message).
    var phonePath: [MessageSummary] = []

    // Assistant (Slyy Haven)
    enum HavenState: Equatable {
        case unknown, notInstalled, connected
        case failed(String)
    }
    /// The "Ask Haven" bars only show when this is `.connected`; without Haven, Mailr has no AI features.
    var havenState: HavenState = .unknown
    private var haven: HavenClient?
    var editingEvent: CalendarEvent?
    var selectedEvent: CalendarEvent?
    private var loadedRange: (Date, Date)?
    /// Meetings already stored by a Send whose mail then failed, by UID (a retry updates them).
    @ObservationIgnored private var savedMeetings: [String: CalendarEvent] = [:]

    // Video
    /// iOS: presented full screen. macOS: RootView opens a window and clears it.
    var videoCall: URL?

    var errorMessage: String?

    private init() {
        Task { await bootstrap() }
    }

    /// Model that never touches the Keychain or servers (tests, previews).
    private init(sample: Bool) {}

    var currentFolder: String? {
        if case .folder(let f) = sidebarSelection { return f }
        return nil
    }

    var currentFolderInfo: IMAPFolder? {
        folders.first { $0.serverPath == currentFolder }
    }

    var visibleEvents: [CalendarEvent] {
        events.filter { !hiddenCalendars.contains($0.calendarURL ?? "") }
    }

    func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Accounts

    private static let accountsKey = "accounts.v1"

    private func storedAccounts() -> [AccountSettings] {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsKey) else { return [] }
        return (try? JSONDecoder().decode([AccountSettings].self, from: data)) ?? []
    }

    private func persist(_ accounts: [AccountSettings]) {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.accountsKey) }
    }

    func bootstrap() async {
        guard let a = storedAccounts().first, let pw = Keychain.password(for: a.id) else { return }
        await activate(a, password: pw)
    }

    /// Verifies the servers, stores the account and starts syncing.
    func addAccount(_ settings: AccountSettings, password: String) async throws {
        try await MailService.verify(settings, password: password)
        try Keychain.setPassword(password, for: settings.id)
        persist([settings])
        await activate(settings, password: password)
    }

    func updateAccount(_ settings: AccountSettings, password: String?) async throws {
        let pw = password?.isEmpty == false ? password! : (Keychain.password(for: settings.id) ?? "")
        try await MailService.verify(settings, password: pw)
        try Keychain.setPassword(pw, for: settings.id)
        persist([settings])
        await activate(settings, password: pw)
    }

    /// Reopens mails that were being written when Mailr quit unexpectedly.
    func recoverUnsentDrafts() {
        guard autoSave, recovered.isEmpty else { return }
        recovered = DraftJournal.standard.leftovers()
        openNextRecovered()
    }

    /// Called when the editor closes: the next recovered draft, if any.
    func openNextRecovered() {
        guard composeDraft == nil, !recovered.isEmpty else { return }
        #if os(macOS)
        // One recovered mail at a time, as with the sheet: the next opens when this one closes.
        guard !composeWindows.values.contains(where: \.recovered) else { return }
        #endif
        var d = recovered.removeFirst()
        d.recovered = true
        present(d)
    }

    /// Shows a message to write: on the Mac in its own resizable window, else (iOS, or no window opener yet) in the sheet.
    private func present(_ d: ComposeDraft) {
        #if os(macOS)
        if let open = openComposeWindow {
            composeWindows[d.id] = d
            lastComposeWindow = d.id
            open(d.id)
            return
        }
        #endif
        composeDraft = d
    }

    /// Changes the message just opened by `compose(_:)` (e.g. Haven's text for a reply), in the sheet or its window.
    func amendComposed(_ change: (inout ComposeDraft) -> Void) {
        if composeDraft != nil {
            change(&composeDraft!)
            return
        }
        #if os(macOS)
        if let id = lastComposeWindow, composeWindows[id] != nil { change(&composeWindows[id]!) }
        #endif
    }

    /// Saves settings that need no reconnect (name, signature, sender addresses, video server).
    func saveSettings(_ settings: AccountSettings) {
        persist([settings])
        account = settings
        // Invitations are answered as the invited alias: the calendar service needs the new addresses.
        if let mail, let pw = Keychain.password(for: settings.id) {
            calendarService = CalendarService(account: settings, password: pw, mail: mail)
        }
    }

    func removeAccount() async {
        guard let a = account else { return }
        await watcher?.stop()
        await mail?.disconnect()
        Keychain.delete(for: a.id)
        cache.clear(account: a.id)
        persist([])
        account = nil
        mail = nil
        calendarService = nil
        folders = []
        messages = []
        events = []
        calendars = []
        openMessage = nil
        openSummary = nil
        ReminderScheduler.clear()
    }

    private func activate(_ a: AccountSettings, password: String) async {
        await watcher?.stop()
        await mail?.disconnect()
        account = a
        let m = MailService(account: a, password: password, cache: cache)
        mail = m
        calendarService = CalendarService(account: a, password: password, mail: m)
        // Show cached list immediately, then sync.
        messages = cache.summaries(folder: "INBOX", account: a.id)
        await refresh()
        let w = MailWatcher(account: a, password: password)
        watcher = w
        await w.start(folder: "INBOX") {
            await AppModel.shared.mailChanged()
        }
        await ReminderScheduler.requestAuthorization()
        await connectHaven()
        recoverUnsentDrafts()
        cache.prune()
    }

    // MARK: Mail

    func refresh() async {
        guard let mail else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            folders = try await mail.folders()
            updateBadge()
            if sidebarSelection == .calendar {
                await loadEvents(force: true)
            } else {
                await loadMessages(reset: true)
            }
        } catch {
            report(error)
        }
    }

    func mailChanged() async {
        guard let mail else { return }
        if let f = try? await mail.folders() { folders = f; updateBadge() }
        if currentFolder == "INBOX" && searchText.isEmpty {
            await loadMessages(reset: true)
        } else if let a = account, let r = try? await mail.messages(in: "INBOX", page: 0) {
            await MailNotifier.process(inbox: r.messages, account: a.id)
        }
    }

    /// Connects to Slyy Haven on this Mac (its socket in the shared Slyy app group). iOS has no Haven.
    func connectHaven() async {
        #if os(macOS)
        await haven?.close()
        haven = nil
        guard let path = HavenClient.defaultSocketPath(teamID: Self.teamID) else { havenState = .notInstalled; return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        do {
            haven = try await HavenClient.connect(path: path, app: "Slyy Mailr", version: version)
            havenState = .connected
        } catch HavenClient.Failure.notInstalled {
            havenState = .notInstalled
        } catch {
            havenState = .failed(error.localizedDescription)
        }
        #else
        havenState = .notInstalled
        #endif
    }

    /// A fresh assistant run on the current Haven connection (reconnects once if Haven restarted).
    func assistant() async -> MailAssistant? {
        if haven == nil, havenState != .notInstalled { await connectHaven() }
        // The agent may search and read this mailbox (read-only) through Mailr's own connection.
        return haven.map { MailAssistant(client: $0, mailbox: mail) }
    }

    func havenConnectionLost() {
        haven = nil
        havenState = .unknown
    }

    #if os(macOS)
    /// Our Apple Team ID from the app's own code signature (names the shared app group).
    static let teamID: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()
    #endif

    /// A whole conversation for its own window (double-click in the list); the main reader is not touched.
    func conversationForWindow(_ s: MessageSummary) async -> (messages: [MessageSummary], bodies: [String: ParsedMessage]) {
        guard let mail else { return ([s], [:]) }
        let list = (try? await mail.conversation(of: s)) ?? [s]
        var bodies: [String: ParsedMessage] = [:]
        for m in list {
            if let p = try? await mail.message(m, markSeen: true) { bodies[m.id] = p }
        }
        // Read now: the list shows them as read too (and the unread count goes down).
        let unread = Set(list.filter { !$0.isSeen }.map(\.id))
        if !unread.isEmpty { setLocalFlag("\\Seen", on: true, ids: unread) }
        return (list, bodies)
    }

    /// Background refresh (iOS): checks the Inbox, announces new mail and updates the badge.
    func backgroundCheck() async {
        let service: MailService
        let a: AccountSettings
        var temporary = false
        if let mail, let account {
            service = mail
            a = account
        } else {
            guard let stored = storedAccounts().first, let pw = Keychain.password(for: stored.id) else { return }
            service = MailService(account: stored, password: pw, cache: cache)
            a = stored
            temporary = true
        }
        if let r = try? await service.messages(in: "INBOX", page: 0) {
            await MailNotifier.process(inbox: r.messages, account: a.id, force: true)
        }
        if let f = try? await service.folders() {
            if !temporary { folders = f }
            setBadge(f.first { $0.specialUse == .inbox }?.unseen ?? 0)
        }
        if temporary { await service.disconnect() }
    }

    /// Opens the message a "new mail" notification points to.
    func openFromNotification(folder: String, uid: UInt32?) async {
        select(.folder(folder))
        await loadMessages(reset: true)
        guard let uid, let m = messages.first(where: { $0.uid == uid }) else { return }
        selectedMessageIDs = [m.id]
        #if os(iOS)
        phonePath = [m]
        #endif
        await open(m)
    }

    func select(_ item: SidebarItem?) {
        sidebarSelection = item
        openMessage = nil
        openSummary = nil
        selectedMessageIDs = []
        searchText = ""
        Task {
            if item == .calendar {
                await loadEvents(force: false)
            } else {
                if let f = currentFolder, let a = account { messages = cache.summaries(folder: f, account: a.id) }
                await loadMessages(reset: true)
            }
        }
    }

    func loadMessages(reset: Bool) async {
        guard let mail, let folder = currentFolder else { return }
        if reset { page = 0 }
        do {
            let r = try await mail.messages(in: folder, page: page)
            guard folder == currentFolder else { return }
            totalMessages = r.total
            if reset {
                messages = r.messages
            } else {
                let known = Set(messages.map(\.id))
                messages += r.messages.filter { !known.contains($0.id) }
            }
            contacts.add(r.messages.flatMap(\.from))
            if reset { await loadCompanions(for: folder) }
            if reset, folder == "INBOX", let a = account { await MailNotifier.process(inbox: r.messages, account: a.id) }
        } catch {
            report(error)
        }
    }

    private func loadCompanions(for folder: String) async {
        guard let mail, threaded else { companions = []; return }
        let use = folders.first { $0.serverPath == folder }?.specialUse
        guard use != .sent, use != .drafts, let sent = folders.first(where: { $0.specialUse == .sent }) else { companions = []; return }
        if let r = try? await mail.messages(in: sent.serverPath, page: 0), folder == currentFolder {
            companions = r.messages
        }
    }

    var canLoadMore: Bool { searchText.isEmpty && messages.count < totalMessages }

    func loadMore() async {
        guard canLoadMore else { return }
        page += 1
        await loadMessages(reset: false)
    }

    func search() async {
        guard let mail, let folder = currentFolder else { return }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { await loadMessages(reset: true); return }
        isSearching = true
        defer { isSearching = false }
        do {
            messages = try await mail.search(in: folder, text: q)
        } catch {
            report(error)
        }
    }

    func open(_ s: MessageSummary?) async {
        guard let s, let mail else {
            openSummary = nil
            openMessage = nil
            return
        }
        if s.isDraft {
            compose(.draft(s))
            return
        }
        let sameConversation = openConversation.contains { $0.id == s.id }
        openSummary = s
        openMessage = nil
        if !sameConversation {
            openConversation = []
            conversationBodies = [:]
            expandedMessages = [s.id]
        }
        isLoadingMessage = true
        defer { isLoadingMessage = false }
        do {
            let m = try await mail.message(s)
            guard openSummary?.id == s.id else { return }
            openMessage = m
            conversationBodies[s.id] = m
            expandedMessages.insert(s.id)
            if !s.isSeen { setLocalFlag("\\Seen", on: true, ids: [s.id]) }
            if threaded && !sameConversation {
                Task {
                    let convo = (try? await mail.conversation(of: s)) ?? [s]
                    guard openSummary?.id == s.id else { return }
                    openConversation = convo
                    // Unread messages start unfolded, like the one just opened.
                    for u in convo where !u.isSeen { await unfold(u, focusing: false) }
                }
            }
            contacts.add(m.from + m.to + m.cc)
            // Apply incoming replies/cancellations to my calendar automatically.
            for part in m.calendarParts {
                let method = ICalendarReader.read(part).method
                if method == "REPLY" || method == "CANCEL" {
                    // Only the organizer may cancel, only the attendee may answer for themself; say so plainly otherwise.
                    do {
                        try await calendarService?.apply(itip: part, from: m.from.first?.address ?? "")
                    } catch let refused as ITIPError {
                        report(refused)
                    } catch {}
                }
            }
        } catch {
            report(error)
        }
    }

    /// Folds/unfolds one message of the open conversation, loading its body the first time.
    func toggleFold(_ m: MessageSummary) async {
        if expandedMessages.contains(m.id) {
            expandedMessages.remove(m.id)
        } else {
            await unfold(m)
        }
    }

    func unfold(_ m: MessageSummary, focusing: Bool = true) async {
        expandedMessages.insert(m.id)
        if focusing { focus(m) }
        guard conversationBodies[m.id] == nil, let mail else { return }
        do {
            let parsed = try await mail.message(m)
            conversationBodies[m.id] = parsed
            if openSummary?.id == m.id { openMessage = parsed }
            if !m.isSeen { setLocalFlag("\\Seen", on: true, ids: [m.id]) }
        } catch { report(error) }
    }

    /// Makes a message of the open conversation the target of Reply/Archive/Delete.
    func focus(_ m: MessageSummary) {
        openSummary = m
        if let body = conversationBodies[m.id] { openMessage = body }
    }

    // MARK: Reply to a selection / one message

    /// Text selected in a shown message, by MessageSummary.id: Reply / Forward of that message quote only this.
    var quoteSelection: [String: String] = [:]

    /// Remembers (or, when empty, forgets) the selection in one message.
    func setQuoteSelection(_ text: String, for id: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if quoteSelection[id] != nil { quoteSelection[id] = nil }
        } else if quoteSelection[id] != text {
            quoteSelection[id] = text
        }
    }

    /// The message to answer or forward: just the selected text when some is selected in it.
    func quoted(_ p: ParsedMessage, id: String?) -> ParsedMessage {
        guard let id, let selection = quoteSelection[id] else { return p }
        return p.quoting(selection)
    }

    /// The body of one message, loaded (and kept) if it is not shown yet, e.g. a folded section.
    func body(of s: MessageSummary) async -> ParsedMessage? {
        if let p = conversationBodies[s.id] { return p }
        if openSummary?.id == s.id, let p = openMessage { return p }
        guard let mail else { return nil }
        do {
            let p = try await mail.message(s)
            conversationBodies[s.id] = p
            if !s.isSeen { setLocalFlag("\\Seen", on: true, ids: [s.id]) }
            return p
        } catch {
            report(error)
            return nil
        }
    }

    func toggleThread(_ id: String) {
        if expandedThreads.contains(id) { expandedThreads.remove(id) } else { expandedThreads.insert(id) }
    }

    var selectedMessages: [MessageSummary] {
        messages.filter { selectedMessageIDs.contains($0.id) }
    }

    private func setLocalFlag(_ flag: String, on: Bool, ids: Set<String>) {
        for i in messages.indices where ids.contains(messages[i].id) {
            if on { messages[i].flags.insert(flag) } else { messages[i].flags.remove(flag) }
        }
        if let s = openSummary, ids.contains(s.id) {
            if on { openSummary?.flags.insert(flag) } else { openSummary?.flags.remove(flag) }
        }
        if flag == "\\Seen", let f = folders.firstIndex(where: { $0.serverPath == currentFolder }) {
            folders[f].unseen = max(0, folders[f].unseen + (on ? -ids.count : ids.count))
            updateBadge()
        }
    }

    func toggleFlag(_ flag: String, for list: [MessageSummary]) async {
        guard let mail, !list.isEmpty else { return }
        let on = !list.allSatisfy { $0.flags.contains(flag) }
        setLocalFlag(flag, on: on, ids: Set(list.map(\.id)))
        do { try await mail.setFlag(flag, on: on, for: list) } catch { report(error) }
    }

    private func removeLocally(_ list: [MessageSummary]) {
        let ids = Set(list.map(\.id))
        messages.removeAll { ids.contains($0.id) }
        selectedMessageIDs.subtract(ids)
        if let s = openSummary, ids.contains(s.id) {
            openSummary = nil
            openMessage = nil
        }
        totalMessages = max(0, totalMessages - list.count)
    }

    func delete(_ list: [MessageSummary]) async {
        guard let mail, !list.isEmpty else { return }
        removeLocally(list)
        do { try await mail.delete(list) } catch { report(error); await loadMessages(reset: true) }
    }

    func archive(_ list: [MessageSummary]) async {
        guard let mail, !list.isEmpty else { return }
        removeLocally(list)
        do { try await mail.archive(list) } catch { report(error); await loadMessages(reset: true) }
    }

    func move(_ list: [MessageSummary], to folder: IMAPFolder) async {
        guard let mail, !list.isEmpty else { return }
        removeLocally(list)
        do { try await mail.move(list, to: folder.serverPath) } catch { report(error); await loadMessages(reset: true) }
    }

    func createFolder(_ name: String) async {
        guard let mail, !name.isEmpty else { return }
        do {
            try await mail.createFolder(name)
            folders = try await mail.folders()
        } catch { report(error) }
    }

    func deleteFolder(_ f: IMAPFolder) async {
        guard let mail else { return }
        do {
            try await mail.deleteFolder(f)
            folders = try await mail.folders()
            if currentFolder == f.serverPath { select(.folder("INBOX")) }
        } catch { report(error) }
    }

    func renameFolder(_ f: IMAPFolder, to name: String) async {
        guard let mail, !name.isEmpty else { return }
        do {
            try await mail.renameFolder(f, to: name)
            folders = try await mail.folders()
        } catch { report(error) }
    }

    private func updateBadge() {
        setBadge(folders.first { $0.specialUse == .inbox }?.unseen ?? 0)
    }

    private func setBadge(_ unread: Int) {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(unread) { _ in }
        #endif
    }

    // MARK: Compose

    func compose(_ kind: ComposeKind) {
        guard let a = account else { return }
        switch kind {
        case .new:
            present(newDraft(a))
        case .to(let addr):
            var d = newDraft(a)
            d.to = addr.headerValue
            present(d)
        case .reply(let m), .replyAll(let m), .forward(let m):
            // Answer from the address the mail was sent to (alias), and keep all my addresses out of Reply All.
            let id = a.identity(forReplyTo: m)
            let kindOf: ReplyKind
            if case .reply = kind { kindOf = .reply } else if case .replyAll = kind { kindOf = .replyAll } else { kindOf = .forward }
            var d = ComposeDraft(m.draft(kindOf, me: id.address, myAddresses: a.myAddresses), signature: signature(for: id))
            d.from = id
            d.blueReply = kindOf != .forward && blueReplies
            d.replyColor = replyColorHex
            present(d)
        case .mailto(let url):
            var d = newDraft(a)
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            d.to = comps?.path.removingPercentEncoding ?? ""
            for item in comps?.queryItems ?? [] {
                switch item.name.lowercased() {
                case "subject": d.subject = item.value ?? ""
                case "body": d.body = (item.value ?? "") + d.body
                case "cc": d.cc = item.value ?? ""; d.showCcBcc = true
                case "bcc": d.bcc = item.value ?? ""; d.showCcBcc = true
                default: break
                }
            }
            present(d)
        case .draft(let s):
            Task {
                guard let mail else { return }
                do {
                    let m = try await mail.message(s, markSeen: false)
                    var d = ComposeDraft()
                    d.to = m.to.map(\.headerValue).joined(separator: ", ")
                    d.cc = m.cc.map(\.headerValue).joined(separator: ", ")
                    d.subject = m.subject
                    d.body = m.textBody ?? m.htmlBody.map(HTMLText.toPlain) ?? ""
                    d.attachments = m.attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
                    d.inReplyTo = m.inReplyTo
                    d.references = m.references
                    d.draftUID = s.uid
                    d.messageID = m.messageID
                    d.showCcBcc = !m.cc.isEmpty
                    present(d)
                } catch { report(error) }
            }
        }
    }

    /// The signature for an identity (its own, else the account's).
    /// A new mail from the default sender, with that address's signature.
    private func newDraft(_ a: AccountSettings) -> ComposeDraft {
        var d = ComposeDraft()
        let id = a.defaultIdentity
        d.from = id
        let sig = signature(for: id)
        if !sig.isEmpty { d.body = "\n\n-- \n" + sig }
        return d
    }

    func signature(for id: SenderIdentity) -> String {
        id.signature.isEmpty ? (account?.signature ?? "") : id.signature
    }

    var identities: [SenderIdentity] { account?.identities ?? [] }

    func isMine(_ address: String) -> Bool { account?.isMine(address) ?? false }

    /// My answer to an event, whichever of my addresses was invited.
    func myStatus(in event: CalendarEvent) -> ParticipationStatus? {
        event.attendees.first { isMine($0.email) }?.status
    }

    /// Sends a message. Problems go to `onError` (the editor shows them on its own sheet or window), else to `errorMessage`.
    func send(_ draft: ComposeDraft, onError: ((String) -> Void)? = nil) async -> Bool {
        guard let mail, let a = account else { return false }
        func fail(_ text: String) -> Bool {
            if let onError { onError(text) } else { errorMessage = text }
            return false
        }
        func describe(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        var msg = draft.message(from: a.address)
        if draft.meeting != nil, (msg.to + msg.cc).isEmpty {
            return fail(String(localized: "Add the people you are inviting under To or Cc."))
        }
        guard !msg.envelopeRecipients.isEmpty else {
            return fail(String(localized: "Add at least one recipient."))
        }
        if let bad = (msg.to + msg.cc + msg.bcc).first(where: { !$0.isValid }) {
            return fail(String(localized: "Invalid address: \(bad.address)"))
        }
        if let meeting = draft.meeting {
            // The event goes into my calendar first (no separate invitation mails); this mail is the invitation.
            guard let cal = calendarService, hasCalendar else {
                return fail(String(localized: "This account has no calendar, so the meeting can't be saved."))
            }
            var event = meeting.event(organizer: msg.from, attendees: msg.to + msg.cc, fallbackTitle: draft.subject.isEmpty ? String(localized: "Meeting") : draft.subject)
            if let earlier = savedMeetings[meeting.uid] {
                // Saved by an earlier Send that then failed: update that event instead of creating it twice.
                event.objectURL = earlier.objectURL
                event.etag = earlier.etag
                event.calendarURL = earlier.calendarURL
                event.sequence = earlier.sequence
            }
            do {
                let saved = try await cal.save(event, notify: false)
                savedMeetings[meeting.uid] = saved
                msg = msg.invitation(for: saved)
                loadedRange = nil
            } catch {
                return fail(String(localized: "The meeting could not be saved in your calendar, so the mail was not sent.") + "\n\n" + describe(error))
            }
        }
        do {
            try await mail.send(msg, replacingDraft: draft.draftUID)
            if let meeting = draft.meeting { savedMeetings[meeting.uid] = nil }
            contacts.add(msg.to + msg.cc + msg.bcc)
            if let original = openSummary, draft.inReplyTo != nil, draft.inReplyTo == openMessage?.messageID {
                setLocalFlag("\\Answered", on: true, ids: [original.id])
                try? await mail.setFlag("\\Answered", on: true, for: [original])
            }
            return true
        } catch {
            return fail(describe(error))
        }
    }

    /// The account has a calendar server (CalDAV), so meetings can be added to mails.
    var hasCalendar: Bool { !(account?.caldavURL.isEmpty ?? true) }

    /// Saves to Drafts; returns the draft with its new UID.
    func saveDraft(_ draft: ComposeDraft) async -> ComposeDraft {
        guard let mail, let a = account, !draft.isEmpty else { return draft }
        var d = draft
        do {
            d.draftUID = try await mail.saveDraft(d.message(from: a.address), replacing: d.draftUID)
        } catch {
            // Autosave failures are not worth an alert; the user can still send.
        }
        return d
    }

    // MARK: Invites

    func respond(to invite: CalendarEvent, status: ParticipationStatus) async {
        guard let cal = calendarService else { return }
        do {
            try await cal.respond(to: invite, status: status)
            loadedRange = nil
        } catch { report(error) }
    }

    // MARK: Calendar

    func range(for date: Date, mode: CalendarMode) -> (Date, Date) {
        var cal = Calendar.current
        cal.firstWeekday = 2
        switch mode {
        case .day:
            let s = cal.startOfDay(for: date)
            return (s, cal.date(byAdding: .day, value: 1, to: s)!)
        case .week:
            let s = cal.dateInterval(of: .weekOfYear, for: date)!.start
            return (s, cal.date(byAdding: .day, value: 7, to: s)!)
        case .agenda:
            let s = cal.startOfDay(for: date)
            return (s, cal.date(byAdding: .day, value: CalendarMode.agendaDays, to: s)!)
        case .month:
            let m = cal.dateInterval(of: .month, for: date)!
            let s = cal.dateInterval(of: .weekOfYear, for: m.start)!.start
            return (s, cal.date(byAdding: .day, value: 42, to: s)!)
        }
    }

    func loadEvents(force: Bool) async {
        guard let cal = calendarService, await cal.isAvailable else { return }
        // Load a wider window than visible so paging feels instant.
        let (vs, ve) = range(for: calendarDate, mode: calendarMode)
        if !force, let r = loadedRange, r.0 <= vs, r.1 >= ve { return }
        let from = Calendar.current.date(byAdding: .day, value: -21, to: vs)!
        let to = Calendar.current.date(byAdding: .day, value: 42, to: ve)!
        do {
            if calendars.isEmpty || force { calendars = try await cal.calendars() }
            events = try await cal.events(from: from, to: to)
            loadedRange = (from, to)
            await ReminderScheduler.schedule(events.filter { !hiddenCalendars.contains($0.calendarURL ?? "") })
        } catch {
            report(error)
        }
    }

    func moveCalendar(by step: Int) {
        let comp: Calendar.Component = calendarMode == .day ? .day : calendarMode == .week ? .weekOfYear : calendarMode == .agenda ? .day : .month
        let amount = calendarMode == .agenda ? step * CalendarMode.agendaDays : step
        calendarDate = Calendar.current.date(byAdding: comp, value: amount, to: calendarDate) ?? calendarDate
        Task { await loadEvents(force: false) }
    }

    func newEvent(at date: Date?) {
        guard let a = account else { return }
        sidebarSelection = .calendar
        let start = date ?? Self.nextHalfHour()
        var e = CalendarEvent(summary: "", start: start, end: start.addingTimeInterval(3600), timeZoneID: TimeZone.current.identifier)
        e.organizer = a.address
        e.calendarURL = calendars.first { !$0.isReadOnly }?.url
        editingEvent = e
    }

    static func nextHalfHour() -> Date {
        let now = Date()
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        let add = minute < 30 ? 30 - minute : 60 - minute
        return cal.date(bySetting: .second, value: 0, of: cal.date(byAdding: .minute, value: add, to: now)!) ?? now
    }

    func save(event: CalendarEvent, notify: Bool) async -> Bool {
        guard let cal = calendarService else { return false }
        do {
            let saved = try await cal.save(event, notify: notify)
            contacts.add(saved.attendees.map { EmailAddress(name: $0.name, address: $0.email) })
            selectedEvent = nil
            await loadEvents(force: true)
            return true
        } catch {
            report(error)
            return false
        }
    }

    func delete(event: CalendarEvent) async {
        guard let cal = calendarService else { return }
        do {
            try await cal.delete(event)
            selectedEvent = nil
            events.removeAll { $0.uid == event.uid }
            await loadEvents(force: true)
        } catch { report(error) }
    }

    // MARK: Video

    func join(_ url: URL) {
        guard let a = account else {
            videoCall = url
            return
        }
        videoCall = JitsiRoom.joinURL(url, displayName: a.displayName, email: a.email)
    }

    /// The link for a new meeting: the user's own room if Settings → Video Calls names one, else a new private room.
    func newMeetingURL() -> URL { JitsiRoom.meetingURL(setting: account?.jitsiURL ?? JitsiRoom.defaultServer) }

    /// Ad-hoc meeting: the meeting link copied to the clipboard, call opened.
    func meetNow() {
        let url = newMeetingURL()
        copyToClipboard(url.absoluteString)
        join(url)
    }

    /// New room + mail with the link to the given people (e.g. "Call" on a message).
    func call(_ people: [EmailAddress]) {
        let url = newMeetingURL()
        var d = ComposeDraft()
        d.to = people.map(\.headerValue).joined(separator: ", ")
        d.subject = String(localized: "Video call now")
        d.videoURL = url
        present(d)
        join(url)
    }

    func copyToClipboard(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }

    func handle(url: URL) {
        if url.scheme?.lowercased() == "mailto" { compose(.mailto(url)) }
    }
}

// MARK: - Test seam (sample data lives in App/Tests)

extension AppModel {
    /// A model that never touches the Keychain or servers, filled with the given content (tests, screenshots).
    static func offline(account: AccountSettings?, folders: [IMAPFolder] = [], messages: [MessageSummary] = [],
                        calendars: [CalDAVCalendar] = [], events: [CalendarEvent] = []) -> AppModel {
        let m = AppModel(sample: true)
        m.account = account
        m.folders = folders
        m.messages = messages
        m.calendars = calendars
        m.events = events
        return m
    }

    /// Tests: change the sample account (the live account changes only through updateAccount).
    func setSampleAccount(_ a: AccountSettings) { account = a }

    /// Tests: shows a message and its conversation as if it had been opened.
    func showForTesting(_ summary: MessageSummary, message: ParsedMessage?, conversation: [MessageSummary], bodies: [String: ParsedMessage] = [:]) {
        openSummary = summary
        openMessage = message
        openConversation = conversation
        conversationBodies = bodies
    }
}
