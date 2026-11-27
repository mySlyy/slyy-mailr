import SwiftUI
import SlyyMailKit

/// A one-click request in the Ask Haven bar ("Summarize thread", "Shorten", …).
struct QuickAction: Identifiable, Hashable {
    let title: LocalizedStringKey
    /// What is sent to the agent (English instructions; the agent answers in the mail's language).
    let prompt: String
    var id: String { prompt }

    static func == (a: QuickAction, b: QuickAction) -> Bool { a.prompt == b.prompt }
    func hash(into h: inout Hasher) { h.combine(prompt) }

    static let writer: [QuickAction] = [
        QuickAction(title: "Write the reply", prompt: "Write the reply to the mail I am answering, based on the thread and my draft so far."),
        QuickAction(title: "Shorten", prompt: "Shorten my draft. Keep every fact and the tone."),
        QuickAction(title: "More formal", prompt: "Rewrite my draft in a more formal tone."),
        QuickAction(title: "Translate to English", prompt: "Translate my draft to English."),
        QuickAction(title: "Add facts from my data", prompt: "Check names, numbers, prices and dates in my draft against my connected data and earlier mail, and fill in what is missing. Say what you changed."),
    ]

    static let reader: [QuickAction] = [
        QuickAction(title: "Summarize thread", prompt: "Summarize this conversation in a few bullets: what is asked of me, what is open, deadlines."),
        QuickAction(title: "Draft a reply", prompt: "Draft a reply to this mail."),
        QuickAction(title: "Research the sender", prompt: "Who is the sender and their company? Use my connected data and earlier mail, and cite sources."),
        QuickAction(title: "Find related mails", prompt: "Find related mails and list the relevant ones with one line each, citing them."),
        QuickAction(title: "Create a task", prompt: "Propose a task in my connected system for what this mail asks of me."),
        QuickAction(title: "Schedule a meeting", prompt: "Propose a meeting with the people in this mail at a suitable time."),
    ]
}

/// A mail the answer cites as [n].
struct HavenSource: Identifiable {
    let n: Int
    let mail: MessageSummary
    var id: Int { n }
}

/// What a request has produced so far (shared by the bar and the answer pane).
@MainActor
@Observable
final class HavenRun {
    var answer = ""
    var steps: [String] = []
    var sources: [HavenSource] = []
    var proposals: [AssistantProposal] = []
    var toolNote: String?
    var error: String?
    var running = false
    /// Actions the user confirmed: their results ("Task 4711 created") or errors.
    var actionResults: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var assistant: MailAssistant?

    var hasResult: Bool { !answer.isEmpty || !proposals.isEmpty || error != nil || !steps.isEmpty }

    func clear() {
        answer = ""; steps = []; sources = []; proposals = []; toolNote = nil; error = nil; actionResults = [:]
    }

    func start(_ prompt: String, context: AssistantContext, model: AppModel) {
        stop()
        clear()
        running = true
        task = Task {
            defer { running = false; toolNote = nil; task = nil }
            guard let a = await model.assistant() else {
                error = String(localized: "Slyy Haven is not available.")
                return
            }
            assistant = a
            do {
                for try await e in a.run(prompt, context: context) {
                    switch e {
                    case .text(let t): answer += t
                    case .usingTool(let name): toolNote = Self.toolLabel(name)
                    case .step(let s): steps.append(s)
                    case .source(let n, let m): sources.append(HavenSource(n: n, mail: m))
                    case .proposal(let p): proposals.append(p)
                    case .done: break
                    }
                }
            } catch is CancellationError {
            } catch HavenClient.Failure.closed {
                model.havenConnectionLost()
                error = HavenClient.Failure.closed.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        toolNote = nil
    }

    func dismiss(_ p: AssistantProposal) { proposals.removeAll { $0 == p } }

    /// Runs a confirmed action (writes in a connected system).
    func perform(_ a: ActionProposal, id: String) async {
        guard let assistant else { return }
        actionResults[id] = String(localized: "Running…")
        do {
            actionResults[id] = "✓ " + (try await assistant.perform(a))
        } catch {
            actionResults[id] = String(localized: "Not done: \(error.localizedDescription)")
        }
    }

    /// "odoo__create_task" → "odoo · create task…"
    static func toolLabel(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        let tool = (parts.last ?? name).replacingOccurrences(of: "_", with: " ")
        return parts.count > 1 ? "\(parts[0]) · \(tool)…" : "\(tool)…"
    }
}

/// Ask Haven at the bottom of the mail writer and reader: quick actions and a one-line prompt.
/// A result card opens above it with what Haven did, its sources and its proposals. Nothing is applied by itself:
/// the user inserts text, reviews events and confirms every write in a connected system.
struct AskHavenBar: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    /// What Mailr knows where the bar sits (read when the prompt is sent).
    let context: () -> AssistantContext
    var quickActions: [QuickAction] = []
    /// Buttons for a text proposal, e.g. "Replace my text" / "Insert below" in the writer, "Reply with this" in the reader.
    var draftButtons: [(title: LocalizedStringKey, action: (DraftProposal) -> Void)] = []
    var placeholder: LocalizedStringKey = "Ask Haven…"
    /// Pre-filled result (screenshots and previews).
    var seed: (answer: String, proposals: [AssistantProposal])? = nil

    @State private var run = HavenRun()
    @State private var prompt = ""
    @State private var reviewing: CalendarEvent?
    @State private var confirming: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if run.hasResult || run.running { resultCard }
            bar
        }
        .sheet(item: $reviewing) { e in
            EventEditorView(event: e).environment(model)
        }
        .onAppear {
            if let seed, !run.hasResult { run.answer = seed.answer; run.proposals = seed.proposals }
        }
        .onDisappear { run.stop() }
    }

    var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !quickActions.isEmpty && !run.running {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickActions) { qa in
                            Button { send(qa.prompt, shown: qa.title) } label: {
                                Text(qa.title).font(Slyy.font(12)).padding(.horizontal, 9).frame(height: 26).hairlineBorder()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Circle().fill(Slyy.accent).frame(width: 8, height: 8)
                    .opacity(run.running ? 0.35 : 1)
                    .animation(run.running ? .easeInOut(duration: 0.6).repeatForever() : .default, value: run.running)
                TextField(placeholder, text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Slyy.font(13))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onChange(of: focused) { _, f in model.typingInField = f }
                    .onSubmit { send(prompt) }
                    .disabled(run.running)
                    .accessibilityLabel("Ask Haven")
                if run.running {
                    Button { run.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Slyy.muted)
                        .accessibilityLabel("Stop")
                } else if !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { send(prompt) } label: { Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Slyy.accent)
                        .accessibilityLabel("Send to Haven")
                } else {
                    #if os(macOS)
                    Text("⌘J").font(Slyy.mono(10)).foregroundStyle(Slyy.lineStrong)
                    #endif
                }
                // ⌘J focuses the bar from anywhere in the window.
                Button("") { focused = true }
                    .keyboardShortcut("j", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(focused || run.running ? Slyy.accent.opacity(0.6) : Slyy.line).frame(height: 1) }
    }

    var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("HAVEN").font(Slyy.mono(10)).tracking(0.8).foregroundStyle(Slyy.accent)
                if let note = run.toolNote {
                    Text(note).font(Slyy.mono(10)).foregroundStyle(Slyy.muted).lineLimit(1).truncationMode(.middle)
                } else if run.running {
                    Text("Working…").font(Slyy.mono(10)).foregroundStyle(Slyy.muted)
                }
                Spacer()
                Button { run.stop(); run.clear() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Slyy.muted)
                    .accessibilityLabel("Close")
            }
            ScrollView {
                HavenResultBody(run: run, draftButtons: draftButtons, confirming: $confirming,
                                onReview: review, onOpen: open)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Slyy.panel)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
    }

    // MARK: Actions

    func send(_ text: String, shown: LocalizedStringKey? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !run.running else { return }
        prompt = ""
        run.start(t, context: context(), model: model)
    }

    func review(_ e: EventProposal) {
        var event = e.calendarEvent(organizer: model.account?.address)
        if e.video { event.videoURL = JitsiRoom.newURL(server: model.account?.jitsiURL ?? JitsiRoom.defaultServer) }
        event.calendarURL = model.calendars.first { !$0.isReadOnly }?.url
        reviewing = event
    }

    func open(_ m: MessageSummary) {
        #if os(macOS)
        openWindow(value: m)
        #else
        model.phonePath.append(m)
        #endif
    }
}

/// The card's content: answer, what Haven did, numbered sources, proposals (draft, event, action with confirm).
struct HavenResultBody: View {
    @Environment(AppModel.self) private var model
    let run: HavenRun
    var draftButtons: [(title: LocalizedStringKey, action: (DraftProposal) -> Void)] = []
    @Binding var confirming: String?
    var onReview: (EventProposal) -> Void
    var onOpen: (MessageSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !run.answer.isEmpty {
                MarkdownAnswer(text: run.answer)
            }
            if !run.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(run.steps.enumerated()), id: \.offset) { _, s in
                        Text("✓ " + s).font(Slyy.mono(11)).foregroundStyle(Slyy.ink2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("What Haven did")
            }
            if !run.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(run.sources) { src in
                        Button { onOpen(src.mail) } label: {
                            HStack(spacing: 8) {
                                Text("[\(src.n)]").font(Slyy.mono(11)).foregroundStyle(Slyy.accent)
                                Text(src.mail.from.first?.display ?? "").font(Slyy.font(12, .semibold)).lineLimit(1)
                                Text(src.mail.subject).font(Slyy.font(12)).foregroundStyle(Slyy.ink2).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(src.mail.date.formatted(date: .abbreviated, time: .omitted)).font(Slyy.font(11)).foregroundStyle(Slyy.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this mail")
                    }
                }
            }
            ForEach(run.proposals) { p in proposalRow(p) }
            if let e = run.error {
                Text(e).font(Slyy.font(12)).foregroundStyle(Slyy.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func proposalRow(_ p: AssistantProposal) -> some View {
        switch p {
        case .draft(let d):
            VStack(alignment: .leading, spacing: 8) {
                if let s = d.subject, !s.isEmpty { Text(s).font(Slyy.font(13, .semibold)) }
                Text(d.body).font(Slyy.font(13)).foregroundStyle(model.replyColor).lineLimit(8).textSelection(.enabled)
                HStack(spacing: 8) {
                    ForEach(Array(draftButtons.enumerated()), id: \.offset) { i, b in
                        if i == 0 {
                            Button(b.title) { b.action(d); run.dismiss(p) }.buttonStyle(SlyyAccentButtonStyle(height: 28))
                        } else {
                            Button(b.title) { b.action(d); run.dismiss(p) }.buttonStyle(.slyyOutline)
                        }
                    }
                    Button("Discard") { run.dismiss(p) }.buttonStyle(.slyyOutline)
                }
            }
            .padding(10)
            .background(Color.white)
            .hairlineBorder()
        case .event(let e):
            HStack(spacing: 10) {
                Rectangle().fill(Slyy.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if e.video { Image(systemName: SlyyIcon.video).font(.system(size: 10)) }
                        Text(e.title).font(Slyy.font(13, .semibold)).lineLimit(1)
                    }
                    Text(Self.eventLine(e)).font(Slyy.font(12)).foregroundStyle(Slyy.muted).lineLimit(1)
                }
                Spacer()
                Button("Review event") { onReview(e); run.dismiss(p) }
                    .buttonStyle(SlyyAccentButtonStyle(height: 28))
                Button { run.dismiss(p) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Slyy.muted)
                    .accessibilityLabel("Discard")
            }
            .padding(10)
            .background(Color.white)
            .hairlineBorder()
        case .action(let a):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(a.title).font(Slyy.font(13, .semibold))
                    MonoTag(text: a.source.uppercased(), background: Slyy.ink2)
                }
                Text(a.detail).font(Slyy.font(13)).foregroundStyle(Slyy.ink2)
                if let r = run.actionResults[p.id] {
                    Text(r).font(Slyy.font(12)).foregroundStyle(Slyy.ink2)
                } else if confirming == p.id {
                    Text("Haven will write this to \(a.source). OK?").font(Slyy.font(12))
                    HStack(spacing: 8) {
                        Button("Do it") { confirming = nil; Task { await run.perform(a, id: p.id) } }
                            .buttonStyle(SlyyPrimaryButtonStyle(height: 28))
                        Button("Cancel") { confirming = nil }.buttonStyle(.slyyOutline)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Review and create…") { confirming = p.id }.buttonStyle(.slyyOutline)
                        Button("Discard") { run.dismiss(p) }.buttonStyle(.plain).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                    }
                }
            }
            .padding(10)
            .background(Color.white)
            .hairlineBorder()
        }
    }

    static func eventLine(_ e: EventProposal) -> String {
        var s = e.allDay
            ? e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            : e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) + " – " + e.end.formatted(date: .omitted, time: .shortened)
        if !e.attendees.isEmpty { s += " · " + e.attendees.map(\.display).joined(separator: ", ") }
        return s
    }
}

/// The agent's answer: paragraphs and bullets with inline Markdown (bold, links), selectable.
struct MarkdownAnswer: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownNotesShared.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h): Text(MarkdownNotesShared.inline(h)).font(Slyy.font(13, .semibold))
                case .paragraph(let p): Text(MarkdownNotesShared.inline(p)).font(Slyy.font(13))
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Slyy.accent)
                        Text(MarkdownNotesShared.inline(t)).font(Slyy.font(13))
                    }
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Markdown blocks for answers (same rules as the release notes, without promoting the first line to a title).
enum MarkdownNotesShared {
    enum Block: Hashable { case heading(String), paragraph(String), bullet(String) }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") { flush(); out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { flush(); out.append(.bullet(String(line.dropFirst(2)))) }
            else { para.append(line) }
        }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// "Ask Haven this question across your mail" (from the search field): the answer pane in place of the reader.
struct HavenAnswerView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let question: String
    @State private var run = HavenRun()
    @State private var followUp = ""
    @State private var confirming: String?
    @State private var asked: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("HAVEN").font(Slyy.mono(10)).tracking(0.8).foregroundStyle(Slyy.accent)
                        Text(run.running ? (run.toolNote ?? String(localized: "Working…")) : String(localized: "Answer from your mail")).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                        Spacer()
                        Button { model.havenQuestion = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Slyy.muted)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel("Close answer")
                    }
                    Text(asked.last ?? question).font(Slyy.font(20, .semibold)).textSelection(.enabled)
                    HavenResultBody(run: run, draftButtons: [], confirming: $confirming, onReview: { _ in }, onOpen: open)
                    if !run.running && !run.sources.isEmpty {
                        HStack(spacing: 8) {
                            Button("Draft a follow-up") { Task { await followUpMail() } }
                                .buttonStyle(SlyyAccentButtonStyle(height: 34))
                            Button("Open all \(run.sources.count) mails") { for s in run.sources.prefix(6) { open(s.mail) } }
                                .buttonStyle(.slyyOutline)
                            Button("Copy answer") { model.copyToClipboard(run.answer) }
                                .buttonStyle(.slyyOutline)
                        }
                        Text("Haven read these mails through Mailr on this device; nothing was changed.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Circle().fill(Slyy.accent).frame(width: 8, height: 8)
                TextField("Ask a follow-up…", text: $followUp)
                    .textFieldStyle(.plain)
                    .font(Slyy.font(13))
                    .onSubmit(askFollowUp)
                    .disabled(run.running)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Slyy.accent.opacity(0.6)).frame(height: 1) }
        }
        .background(Color.white)
        .task(id: question) {
            asked = [question]
            run.start(question, context: .mailbox(question: question, me: model.account?.email ?? ""), model: model)
        }
    }

    func askFollowUp() {
        let q = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        followUp = ""
        // The earlier question and answer travel along, so "and Brandt?" makes sense.
        let history = zip(asked, [run.answer]).map { "Earlier question: \($0)\nEarlier answer: \($1)" }.joined(separator: "\n")
        asked.append(q)
        run.start(q, context: .mailbox(question: history + "\nNew question: " + q, me: model.account?.email ?? ""), model: model)
    }

    func open(_ m: MessageSummary) {
        #if os(macOS)
        openWindow(value: m)
        #else
        model.phonePath.append(m)
        #endif
    }

    /// A reply to the newest cited mail, with Haven's answer as a starting point below the greeting.
    func followUpMail() async {
        guard let first = run.sources.map(\.mail).max(by: { $0.date < $1.date }), let p = await model.parsedMessage(first) else { return }
        model.compose(.reply(p))
    }
}

extension AssistantContext {
    /// The mail being written, for the writer's bar.
    static func forDraft(_ d: ComposeDraft, from: String) -> AssistantContext {
        .composing(to: d.to, cc: d.cc, subject: d.subject, body: d.body, quoted: d.quoted, from: from)
    }

    /// The mail being read, for the reader's bar, with the rest of its conversation when it is open.
    static func forMessage(_ m: ParsedMessage, me: String, thread: [ParsedMessage] = []) -> AssistantContext {
        let earlier = thread.filter { $0.messageID != m.messageID }.map { t in
            "From: \(t.from.map(\.headerValue).joined(separator: ", ")) · \(t.date.map { ISO8601DateFormatter().string(from: $0) } ?? "")\n"
                + String((t.textBody ?? t.htmlBody.map(HTMLText.toPlain) ?? "").prefix(4000))
        }.joined(separator: "\n---\n")
        return .reading(from: m.from.map(\.headerValue).joined(separator: ", "),
                        to: m.to.map(\.headerValue).joined(separator: ", "),
                        cc: m.cc.map(\.headerValue).joined(separator: ", "),
                        date: m.date, subject: m.subject,
                        text: m.textBody ?? m.htmlBody.map(HTMLText.toPlain) ?? "",
                        me: me, thread: earlier)
    }
}

extension ComposeDraft {
    /// Puts proposed text in place of what I wrote, keeping the signature block and the quote.
    mutating func apply(_ p: DraftProposal) {
        if let r = body.range(of: "\n-- \n") {
            body = p.body + "\n" + String(body[r.lowerBound...])
        } else {
            body = p.body
        }
        if let s = p.subject, !s.isEmpty, subject.isEmpty { subject = s }
        if !p.to.isEmpty { to = p.to.map(\.headerValue).joined(separator: ", ") + ", " }
        if !p.cc.isEmpty { cc = p.cc.map(\.headerValue).joined(separator: ", ") + ", "; showCcBcc = true }
    }

    /// Adds proposed text below what I wrote (above the signature).
    mutating func insert(_ p: DraftProposal) {
        if let r = body.range(of: "\n-- \n") {
            let mine = body[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            body = (mine.isEmpty ? "" : mine + "\n\n") + p.body + "\n" + String(body[r.lowerBound...])
        } else {
            let mine = body.trimmingCharacters(in: .whitespacesAndNewlines)
            body = (mine.isEmpty ? "" : mine + "\n\n") + p.body
        }
    }
}
