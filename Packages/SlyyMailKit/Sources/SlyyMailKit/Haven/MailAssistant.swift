import Foundation

/// What the assistant proposes. Nothing is sent, saved or written by the assistant itself: every proposal is shown
/// to the user, who inserts the text, reviews the event, or confirms the action.
public enum AssistantProposal: Equatable, Sendable, Identifiable {
    case draft(DraftProposal)
    case event(EventProposal)
    /// A change in a connected system (task in Odoo, CRM note, …): runs only after the user confirms.
    case action(ActionProposal)

    public var id: String {
        switch self {
        case .draft(let d): return "draft-\(d.body.hashValue)"
        case .event(let e): return "event-\(e.title)-\(e.start.timeIntervalSince1970)"
        case .action(let a): return "action-\(a.tool)-\(a.title.hashValue)"
        }
    }
}

public struct DraftProposal: Equatable, Sendable {
    public var subject: String?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var body: String

    public init(subject: String? = nil, to: [EmailAddress] = [], cc: [EmailAddress] = [], body: String) {
        self.subject = subject
        self.to = to
        self.cc = cc
        self.body = body
    }
}

public struct EventProposal: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String
    public var attendees: [EmailAddress]
    public var video: Bool
    public var notes: String

    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String = "", attendees: [EmailAddress] = [], video: Bool = false, notes: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.attendees = attendees
        self.video = video
        self.notes = notes
    }

    public func calendarEvent(organizer: EmailAddress?) -> CalendarEvent {
        var e = CalendarEvent(summary: title, location: location, notes: notes, start: start, end: end, isAllDay: allDay)
        e.organizer = attendees.isEmpty ? nil : organizer
        e.attendees = attendees.map { Attendee(email: $0.address, name: $0.name) }
        return e
    }
}

/// A write in a data source, prepared by the model and run through Haven only after the user says OK.
public struct ActionProposal: Equatable, Sendable {
    /// Short label, e.g. "Task in Odoo".
    public var title: String
    /// What will happen, in words the user can check.
    public var detail: String
    /// The Haven tool that does it (`<source>__<tool>`), and its arguments.
    public var tool: String
    public var arguments: JSONValue

    public init(title: String, detail: String, tool: String, arguments: JSONValue) {
        self.title = title
        self.detail = detail
        self.tool = tool
        self.arguments = arguments
    }

    /// "odoo__create_task" → "odoo"
    public var source: String { tool.components(separatedBy: "__").first ?? tool }
}

/// Progress of one request, streamed to the UI.
public enum AssistantEvent: Equatable, Sendable {
    /// More answer text (append).
    case text(String)
    /// A tool is running, e.g. "odoo__search_partners".
    case usingTool(String)
    /// A finished step for the "what Haven did" list, e.g. "mail · searched “Schott Montage”, 9 hits".
    case step(String)
    /// A mail the answer may cite as [n].
    case source(Int, MessageSummary)
    case proposal(AssistantProposal)
    case done
}

/// Mailr's mailbox as the agent sees it: search across folders and read a message. Read-only.
public protocol MailboxAccess: Sendable {
    func searchAll(_ query: String, limit: Int) async throws -> [MessageSummary]
    func plainText(of message: MessageSummary) async throws -> String
}

extension MailService: MailboxAccess {
    /// Searches Inbox, Sent and Archive (Gmail: All Mail), newest first, without marking anything as read.
    public func searchAll(_ query: String, limit: Int) async throws -> [MessageSummary] {
        var paths = ["INBOX"]
        for use in [SpecialUse.sent, .archive, .all] {
            if let f = try await folder(use), !paths.contains(f.serverPath) { paths.append(f.serverPath) }
        }
        var hits: [MessageSummary] = []
        for p in paths { hits += (try? await search(in: p, text: query)) ?? [] }
        var seen = Set<String>()
        return hits.sorted { $0.date > $1.date }.filter { seen.insert($0.messageID ?? $0.id).inserted }.prefix(limit).map { $0 }
    }

    public func plainText(of m: MessageSummary) async throws -> String {
        let p = try await message(m, markSeen: false)
        return p.textBody ?? p.htmlBody.map(HTMLText.toPlain) ?? ""
    }
}

/// Where the prompt was typed, and what Mailr knows there.
public enum AssistantContext: Sendable {
    /// The mail being written.
    case composing(to: String, cc: String, subject: String, body: String, quoted: String, from: String)
    /// The mail being read (plain text), with its headers; `thread` holds the earlier messages of its conversation.
    case reading(from: String, to: String, cc: String, date: Date?, subject: String, text: String, me: String, thread: String = "")
    /// A question about the whole mailbox (asked from the search field).
    case mailbox(question: String, me: String)

    var description: String {
        let limit = 24_000
        switch self {
        case let .composing(to, cc, subject, body, quoted, from):
            var s = "The user is writing a mail.\nFrom: \(from)\nTo: \(to)\n"
            if !cc.isEmpty { s += "Cc: \(cc)\n" }
            s += "Subject: \(subject)\n\nDraft so far:\n\(body.isEmpty ? "(empty)" : String(body.prefix(limit)))\n"
            if !quoted.isEmpty { s += "\nThe mail being answered (quoted below the draft):\n\(String(quoted.prefix(limit)))\n" }
            return s
        case let .reading(from, to, cc, date, subject, text, me, thread):
            var s = "The user (\(me)) is reading this mail.\nFrom: \(from)\nTo: \(to)\n"
            if !cc.isEmpty { s += "Cc: \(cc)\n" }
            if let date { s += "Date: \(ISO8601DateFormatter().string(from: date))\n" }
            s += "Subject: \(subject)\n\n\(String(text.prefix(limit)))\n"
            if !thread.isEmpty { s += "\nEarlier messages of this conversation, oldest first:\n\(String(thread.prefix(limit)))\n" }
            return s
        case let .mailbox(question, me):
            return "The user (\(me)) asks a question about their mail. Search the mailbox with \(MailAssistant.searchTool), read what matters with \(MailAssistant.readTool), and answer with citations.\nQuestion: \(question)\n"
        }
    }
}

/// Mailr's agent loop on top of Slyy Haven: the model class "smart", Mailr's own tools (search and read mail,
/// propose drafts, events and actions), plus the read-only tools of every data source Haven lets Mailr use.
/// Writing tools of data sources are never called directly: the model proposes them, the user confirms.
public struct MailAssistant: Sendable {
    public static let draftTool = "mailr__propose_draft"
    public static let eventTool = "mailr__propose_event"
    public static let actionTool = "mailr__propose_action"
    public static let searchTool = "mailr__search_mail"
    public static let readTool = "mailr__read_mail"
    public static let maxRounds = 10
    /// Tool output given back to the model is cut at this many characters.
    public static let toolResultLimit = 20_000
    static let searchLimit = 15

    public let client: HavenClient
    public var mailbox: MailboxAccess?
    public var modelClass = "smart"
    public var now: @Sendable () -> Date = { Date() }
    public var timeZone = TimeZone.current

    public init(client: HavenClient, mailbox: MailboxAccess? = nil) {
        self.client = client
        self.mailbox = mailbox
    }

    static func localTools(mailbox: Bool, writable: [HavenClient.Tool]) -> [HavenClient.Tool] {
        var tools = [
            HavenClient.Tool(
                name: draftTool,
                description: "Propose the text of a mail (the user reviews it before anything is sent). Use for writing, rewriting, shortening, translating or answering. body is plain text without signature or quoted original.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "body": ["type": "string", "description": "The mail text."],
                        "subject": ["type": "string"],
                        "to": ["type": "array", "items": ["type": "string"], "description": "Addresses, e.g. \"Name <a@b.de>\". Only when the user asks to change recipients."],
                        "cc": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["body"],
                ]),
            HavenClient.Tool(
                name: eventTool,
                description: "Propose a calendar event or meeting (the user reviews it in the event editor before invitations go out).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start": ["type": "string", "description": "ISO 8601 date-time with offset, e.g. 2026-12-01T10:00:00+01:00, or a date for all-day events."],
                        "end": ["type": "string", "description": "ISO 8601; default one hour after start."],
                        "allDay": ["type": "boolean"],
                        "location": ["type": "string"],
                        "attendees": ["type": "array", "items": ["type": "string"]],
                        "video": ["type": "boolean", "description": "Add a video call link."],
                        "notes": ["type": "string"],
                    ],
                    "required": ["title", "start"],
                ]),
        ]
        if mailbox {
            tools.append(HavenClient.Tool(
                name: searchTool,
                description: "Search the user's mail (Inbox, Sent, Archive) by words in sender, subject or text. Returns numbered results; cite them as [n].",
                inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "A few words, e.g. a name and a topic."]], "required": ["query"]]))
            tools.append(HavenClient.Tool(
                name: readTool,
                description: "Read one mail from the search results by its number.",
                inputSchema: ["type": "object", "properties": ["ref": ["type": "integer"]], "required": ["ref"]]))
        }
        if !writable.isEmpty {
            let list = writable.map { "\($0.name): \($0.description)" }.joined(separator: "\n")
            tools.append(HavenClient.Tool(
                name: actionTool,
                description: "Propose a change in a connected system (create a task, note, ticket, …). It runs only after the user confirms. Never claim it is done. Available actions:\n" + list,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short label, e.g. \"Task in Odoo\"."],
                        "detail": ["type": "string", "description": "What will be created or changed, in plain words."],
                        "tool": ["type": "string", "enum": .array(writable.map { .string($0.name) })],
                        "arguments": ["type": "object", "description": "Arguments for that tool, following its schema."],
                    ],
                    "required": ["title", "detail", "tool", "arguments"],
                ]))
        }
        return tools
    }

    func systemPrompt() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        return """
        You are the assistant inside Slyy Mailr, a mail and calendar app. Today is \(f.string(from: now())) (\(timeZone.identifier)).
        Help with the mail in context: write or answer mails, summarise, research, find related mail, schedule meetings, and prepare tasks in the user's connected systems.
        - To change the mail text, call \(Self.draftTool). Never claim a mail was sent: the user sends it.
        - To schedule something, call \(Self.eventTool). The user confirms it in the calendar.
        - To create or change anything in a connected system, call \(Self.actionTool). It runs only after the user confirms; never say it is done.
        - Use \(Self.searchTool) and \(Self.readTool) for anything in the user's other mail, and the read-only data-source tools for facts (customers, quotations, files).
        - Cite mails as [n] with the numbers from \(Self.searchTool). Do not invent facts, numbers or dates; say what you could not find.
        - Write mails in the language of the mail being answered, otherwise in the language of the user's request. Match the formality (Sie/Du) of the conversation.
        - Answers in text are short: a few sentences or bullets. No signature in drafts.
        """
    }

    /// Runs one request. The stream ends with `.done` (or an error).
    public func run(_ prompt: String, context: AssistantContext) -> AsyncThrowingStream<AssistantEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await loop(prompt, context: context) { cont.yield($0) }
                    cont.yield(.done)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs a confirmed action through Haven (which may ask the user once more, per its own write rules).
    public func perform(_ action: ActionProposal) async throws -> String {
        let out = try await client.callTool(action.tool, arguments: action.arguments)
        if let text = out["content"]?.array?.compactMap({ $0["text"]?.string }).joined(separator: " "), !text.isEmpty { return text }
        return out.jsonText
    }

    func loop(_ prompt: String, context: AssistantContext, emit: @Sendable (AssistantEvent) -> Void) async throws {
        let sourceTools = ((try? await client.tools()) ?? []).filter { !$0.name.hasPrefix("mailr__") }
        // Writing tools are never offered directly: only as proposals the user confirms.
        let readable = sourceTools.filter { $0.mutating != true }
        let writable = sourceTools.filter { $0.mutating == true }
        let tools = Self.localTools(mailbox: mailbox != nil, writable: writable) + readable
        let writableNames = Set(writable.map(\.name))
        var messages: [HavenClient.Message] = [.system(systemPrompt()), .user(context.description + "\nRequest: " + prompt)]
        var refs: [MessageSummary] = []

        for _ in 0..<Self.maxRounds {
            try Task.checkCancellation()
            let (_, events) = try await client.chat(class: modelClass, messages: messages, tools: tools)
            var text = ""
            var calls: [HavenClient.ToolCall] = []
            for try await e in events {
                switch e {
                case .text(let t):
                    text += t
                    emit(.text(t))
                case .toolCalls(let c):
                    calls += c
                case .finished:
                    break
                }
            }
            messages.append(HavenClient.Message(role: "assistant", content: text, toolCalls: calls.isEmpty ? nil : calls))
            if calls.isEmpty { return }
            for call in calls {
                let result: String
                switch call.name {
                case Self.draftTool:
                    if let d = Self.draft(from: call.arguments) {
                        emit(.proposal(.draft(d)))
                        result = "Shown to the user for review."
                    } else {
                        result = "Error: body is required."
                    }
                case Self.eventTool:
                    if let ev = Self.event(from: call.arguments, now: now(), timeZone: timeZone) {
                        emit(.proposal(.event(ev)))
                        result = "Shown to the user in the event editor for review."
                    } else {
                        result = "Error: title and a valid ISO 8601 start are required."
                    }
                case Self.actionTool:
                    if let a = Self.action(from: call.arguments), writableNames.contains(a.tool) {
                        emit(.proposal(.action(a)))
                        result = "Shown to the user, who decides whether it runs. Do not say it is done."
                    } else {
                        result = "Error: tool must be one of the available actions, with title, detail and arguments."
                    }
                case Self.searchTool:
                    guard let mailbox, let q = call.arguments["query"]?.string, !q.isEmpty else { result = "Error: query is required."; break }
                    emit(.usingTool(call.name))
                    let hits = (try? await mailbox.searchAll(q, limit: Self.searchLimit)) ?? []
                    var lines: [String] = []
                    for h in hits {
                        let n: Int
                        if let i = refs.firstIndex(where: { $0.id == h.id }) { n = i + 1 } else {
                            refs.append(h)
                            n = refs.count
                            emit(.source(n, h))
                        }
                        lines.append("[\(n)] \(ISO8601DateFormatter().string(from: h.date)) · from \(h.from.first?.headerValue ?? "?") · to \(h.to.map(\.address).joined(separator: ", ")) · \(h.subject)")
                    }
                    emit(.step("mail · searched “\(q)”, \(hits.count) \(hits.count == 1 ? "hit" : "hits")"))
                    result = lines.isEmpty ? "No mail found." : lines.joined(separator: "\n")
                case Self.readTool:
                    guard let mailbox, let n = call.arguments["ref"]?.number.map(Int.init), n >= 1, n <= refs.count else {
                        result = "Error: ref must be a number from the search results."
                        break
                    }
                    emit(.usingTool(call.name))
                    let m = refs[n - 1]
                    let body = (try? await mailbox.plainText(of: m)) ?? ""
                    emit(.step("mail · read [\(n)] \(m.subject)"))
                    result = String("[\(n)] From: \(m.from.first?.headerValue ?? "")\nTo: \(m.to.map(\.headerValue).joined(separator: ", "))\nDate: \(ISO8601DateFormatter().string(from: m.date))\nSubject: \(m.subject)\n\n\(body)".prefix(Self.toolResultLimit))
                default:
                    if writableNames.contains(call.name) {
                        // Not offered, but refuse explicitly if a model tries anyway.
                        result = "Error: this tool changes data. Propose it with \(Self.actionTool) instead."
                        break
                    }
                    emit(.usingTool(call.name))
                    do {
                        let out = try await client.callTool(call.name, arguments: call.arguments)
                        result = String(out.jsonText.prefix(Self.toolResultLimit))
                        emit(.step("\(Self.sourceName(call.name)) · \(Self.verb(call.name))"))
                    } catch {
                        result = "Error: \(error.localizedDescription)"
                        emit(.step("\(Self.sourceName(call.name)) · \(Self.verb(call.name)) failed"))
                    }
                }
                messages.append(HavenClient.Message(role: "tool", content: result, toolCallId: call.id))
            }
        }
    }

    static func sourceName(_ tool: String) -> String { tool.components(separatedBy: "__").first ?? tool }
    static func verb(_ tool: String) -> String {
        (tool.components(separatedBy: "__").last ?? tool).replacingOccurrences(of: "_", with: " ")
    }

    static func action(from a: JSONValue) -> ActionProposal? {
        guard let title = a["title"]?.string, let tool = a["tool"]?.string, !tool.isEmpty else { return nil }
        return ActionProposal(title: title, detail: a["detail"]?.string ?? "", tool: tool, arguments: a["arguments"] ?? .object([:]))
    }

    // MARK: Parsing tool arguments

    static func addresses(_ v: JSONValue?) -> [EmailAddress] {
        let items: [String]
        if let a = v?.array { items = a.compactMap(\.string) } else if let s = v?.string { items = [s] } else { items = [] }
        return items.flatMap { EmailAddress.parseList($0) }.filter(\.isValid)
    }

    static func draft(from a: JSONValue) -> DraftProposal? {
        guard let body = a["body"]?.string, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DraftProposal(subject: a["subject"]?.string, to: addresses(a["to"]), cc: addresses(a["cc"]), body: body)
    }

    static func date(_ s: String?, timeZone: TimeZone) -> (Date, Bool)? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        for opts in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = opts
            if let d = f.date(from: s) { return (d, false) }
        }
        // Local time without offset: "2026-12-01T10:00" / "2026-12-01T10:00:00".
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = fmt
            if let d = local.date(from: s) { return (d, false) }
        }
        local.dateFormat = "yyyy-MM-dd"
        if let d = local.date(from: s) { return (d, true) }
        return nil
    }

    static func event(from a: JSONValue, now: Date, timeZone: TimeZone) -> EventProposal? {
        guard let title = a["title"]?.string, !title.isEmpty, let (start, dateOnly) = date(a["start"]?.string, timeZone: timeZone) else { return nil }
        let allDay = a["allDay"]?.bool ?? dateOnly
        var end = date(a["end"]?.string, timeZone: timeZone)?.0 ?? start.addingTimeInterval(allDay ? 86400 : 3600)
        if end <= start { end = start.addingTimeInterval(allDay ? 86400 : 3600) }
        return EventProposal(title: title, start: start, end: end, allDay: allDay, location: a["location"]?.string ?? "",
                             attendees: addresses(a["attendees"]), video: a["video"]?.bool ?? false, notes: a["notes"]?.string ?? "")
    }
}
