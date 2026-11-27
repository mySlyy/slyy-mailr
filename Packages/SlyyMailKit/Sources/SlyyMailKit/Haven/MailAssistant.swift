import Foundation

/// What the assistant proposes. Nothing is sent or saved by the assistant itself: every proposal is shown
/// to the user, who inserts the text, opens the event editor, or discards it.
public enum AssistantProposal: Equatable, Sendable, Identifiable {
    case draft(DraftProposal)
    case event(EventProposal)

    public var id: String {
        switch self {
        case .draft(let d): return "draft-\(d.body.hashValue)"
        case .event(let e): return "event-\(e.title)-\(e.start.timeIntervalSince1970)"
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

/// Progress of one request, streamed to the UI.
public enum AssistantEvent: Equatable, Sendable {
    /// More answer text (append).
    case text(String)
    /// A data-source tool is running, e.g. "odoo__search_partners".
    case usingTool(String)
    case proposal(AssistantProposal)
    case done
}

/// Where the prompt was typed, and what Mailr knows there.
public enum AssistantContext: Sendable {
    /// The mail being written.
    case composing(to: String, cc: String, subject: String, body: String, quoted: String, from: String)
    /// The mail being read (plain text), with its headers.
    case reading(from: String, to: String, cc: String, date: Date?, subject: String, text: String, me: String)

    var description: String {
        let limit = 24_000
        switch self {
        case let .composing(to, cc, subject, body, quoted, from):
            var s = "The user is writing a mail.\nFrom: \(from)\nTo: \(to)\n"
            if !cc.isEmpty { s += "Cc: \(cc)\n" }
            s += "Subject: \(subject)\n\nDraft so far:\n\(body.isEmpty ? "(empty)" : String(body.prefix(limit)))\n"
            if !quoted.isEmpty { s += "\nThe mail being answered (quoted below the draft):\n\(String(quoted.prefix(limit)))\n" }
            return s
        case let .reading(from, to, cc, date, subject, text, me):
            var s = "The user (\(me)) is reading this mail.\nFrom: \(from)\nTo: \(to)\n"
            if !cc.isEmpty { s += "Cc: \(cc)\n" }
            if let date { s += "Date: \(ISO8601DateFormatter().string(from: date))\n" }
            s += "Subject: \(subject)\n\n\(String(text.prefix(limit)))\n"
            return s
        }
    }
}

/// Mailr's agent loop on top of Slyy Haven: the model class "smart", Mailr's own proposal tools,
/// plus the tools of every data source Haven lets Mailr use (CRM, files, tasks, …).
public struct MailAssistant: Sendable {
    public static let draftTool = "mailr__propose_draft"
    public static let eventTool = "mailr__propose_event"
    public static let maxRounds = 8
    /// Tool output given back to the model is cut at this many characters.
    public static let toolResultLimit = 20_000

    public let client: HavenClient
    public var modelClass = "smart"
    public var now: @Sendable () -> Date = { Date() }
    public var timeZone = TimeZone.current

    public init(client: HavenClient) {
        self.client = client
    }

    public static var localTools: [HavenClient.Tool] {
        [
            HavenClient.Tool(
                name: draftTool,
                description: "Propose the text of the mail (the user reviews it before anything is sent). Use for writing, rewriting, translating or answering. body is plain text without signature or quoted original.",
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
    }

    func systemPrompt() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        return """
        You are the assistant inside Slyy Mailr, a mail and calendar app. Today is \(f.string(from: now())) (\(timeZone.identifier)).
        Help with the mail in context: write or answer mails, summarise, extract dates, schedule meetings, and create tasks or records in the user's connected systems.
        - To change the mail text, call \(Self.draftTool). Never claim a mail was sent: the user sends it.
        - To schedule something, call \(Self.eventTool). The user confirms it in the calendar.
        - To create tasks or look things up (CRM, files, tickets, other mail), use the data-source tools. Writing tools ask the user for confirmation.
        - Write mails in the language of the mail being answered, otherwise in the language of the user's request. Match the formality (Sie/Du) of the conversation.
        - Answers in text are short. No signature in drafts.
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

    func loop(_ prompt: String, context: AssistantContext, emit: @Sendable (AssistantEvent) -> Void) async throws {
        let sourceTools = (try? await client.tools()) ?? []
        let tools = Self.localTools + sourceTools.filter { !$0.name.hasPrefix("mailr__") }
        var messages: [HavenClient.Message] = [.system(systemPrompt()), .user(context.description + "\nRequest: " + prompt)]
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
                default:
                    emit(.usingTool(call.name))
                    do {
                        let out = try await client.callTool(call.name, arguments: call.arguments)
                        result = String(out.jsonText.prefix(Self.toolResultLimit))
                    } catch {
                        result = "Error: \(error.localizedDescription)"
                    }
                }
                messages.append(HavenClient.Message(role: "tool", content: result, toolCallId: call.id))
            }
        }
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
