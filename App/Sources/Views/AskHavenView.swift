import SwiftUI
import SlyyMailKit

/// One-line prompt for Slyy Haven at the bottom of the mail writer and reader.
/// Quiet by default (a hairline, a dot, a muted placeholder); a result card opens above it only while there is
/// something to show. Proposals are never applied by themselves: the user inserts the text or reviews the event.
struct AskHavenBar: View {
    @Environment(AppModel.self) private var model
    /// What Mailr knows where the bar sits (read when the prompt is sent).
    let context: () -> AssistantContext
    /// Button title for a text proposal ("Insert" in the writer, "Reply with this" in the reader).
    let draftAction: LocalizedStringKey
    let onDraft: (DraftProposal) -> Void
    var placeholder: LocalizedStringKey = "Ask Haven…"
    /// Pre-filled result (screenshots and previews).
    var seed: (answer: String, proposals: [AssistantProposal])? = nil

    @State private var prompt = ""
    @State private var answer = ""
    @State private var toolNote: String?
    @State private var proposals: [AssistantProposal] = []
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var reviewing: CalendarEvent?
    @FocusState private var focused: Bool

    var running: Bool { task != nil }
    var hasResult: Bool { !answer.isEmpty || !proposals.isEmpty || error != nil || toolNote != nil }

    var body: some View {
        VStack(spacing: 0) {
            if hasResult { resultCard }
            bar
        }
        .sheet(item: $reviewing) { e in
            EventEditorView(event: e).environment(model)
        }
        .onAppear {
            if let seed, answer.isEmpty, proposals.isEmpty { answer = seed.answer; proposals = seed.proposals }
        }
        .onDisappear { task?.cancel() }
    }

    var bar: some View {
        HStack(spacing: 10) {
            Circle().fill(Slyy.accent).frame(width: 8, height: 8)
                .opacity(running ? 0.35 : 1)
                .animation(running ? .easeInOut(duration: 0.6).repeatForever() : .default, value: running)
            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Slyy.font(13))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
                .disabled(running)
                .accessibilityLabel("Ask Haven")
            if running {
                Button { stop() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Slyy.muted)
                    .accessibilityLabel("Stop")
            } else if !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)) }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(focused || running ? Slyy.accent.opacity(0.5) : Slyy.line).frame(height: 1) }
    }

    var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("HAVEN").font(Slyy.mono(10)).tracking(0.8).foregroundStyle(Slyy.accent)
                if let toolNote {
                    Text(toolNote).font(Slyy.mono(10)).foregroundStyle(Slyy.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { clear() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Slyy.muted)
                    .accessibilityLabel("Close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !answer.isEmpty {
                        Text(answer).font(Slyy.font(13)).foregroundStyle(Slyy.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(proposals) { p in proposalRow(p) }
                    if let error {
                        Text(error).font(Slyy.font(12)).foregroundStyle(Slyy.danger)
                    }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Slyy.panel)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
    }

    @ViewBuilder
    func proposalRow(_ p: AssistantProposal) -> some View {
        switch p {
        case .draft(let d):
            VStack(alignment: .leading, spacing: 8) {
                if let s = d.subject, !s.isEmpty { Text(s).font(Slyy.font(13, .semibold)) }
                Text(d.body).font(Slyy.font(13)).foregroundStyle(model.replyColor).lineLimit(6).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(draftAction) { onDraft(d); dismissProposal(p) }
                        .buttonStyle(SlyyAccentButtonStyle(height: 28))
                    Button("Discard") { dismissProposal(p) }
                        .buttonStyle(.slyyOutline)
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
                    Text(eventLine(e)).font(Slyy.font(12)).foregroundStyle(Slyy.muted).lineLimit(1)
                }
                Spacer()
                Button("Review event") { review(e); dismissProposal(p) }
                    .buttonStyle(SlyyAccentButtonStyle(height: 28))
                Button { dismissProposal(p) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Slyy.muted)
                    .accessibilityLabel("Discard")
            }
            .padding(10)
            .background(Color.white)
            .hairlineBorder()
        }
    }

    func eventLine(_ e: EventProposal) -> String {
        var s = e.allDay
            ? e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            : e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) + " – " + e.end.formatted(date: .omitted, time: .shortened)
        if !e.attendees.isEmpty { s += " · " + e.attendees.map(\.display).joined(separator: ", ") }
        return s
    }

    // MARK: Actions

    func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        clear()
        let ctx = context()
        task = Task {
            defer { task = nil }
            guard let assistant = await model.assistant() else {
                error = String(localized: "Slyy Haven is not available.")
                return
            }
            do {
                for try await e in assistant.run(text, context: ctx) {
                    switch e {
                    case .text(let t): answer += t
                    case .usingTool(let name): toolNote = Self.toolLabel(name)
                    case .proposal(let p): proposals.append(p)
                    case .done: toolNote = nil
                    }
                }
                prompt = ""
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
        toolNote = nil
    }

    func clear() {
        answer = ""
        proposals = []
        error = nil
        toolNote = nil
    }

    func dismissProposal(_ p: AssistantProposal) {
        proposals.removeAll { $0 == p }
    }

    func review(_ e: EventProposal) {
        var event = e.calendarEvent(organizer: model.account?.address)
        if e.video {
            event.videoURL = JitsiRoom.newURL(server: model.account?.jitsiURL ?? JitsiRoom.defaultServer)
        }
        event.calendarURL = model.calendars.first { !$0.isReadOnly }?.url
        reviewing = event
    }

    /// "odoo__create_task" → "odoo · create task…"
    static func toolLabel(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        let tool = (parts.last ?? name).replacingOccurrences(of: "_", with: " ")
        return parts.count > 1 ? "\(parts[0]) · \(tool)…" : "\(tool)…"
    }
}

extension AssistantContext {
    /// The mail being written, for the writer's bar.
    static func forDraft(_ d: ComposeDraft, from: String) -> AssistantContext {
        .composing(to: d.to, cc: d.cc, subject: d.subject, body: d.body, quoted: d.quoted, from: from)
    }

    /// The mail being read, for the reader's bar.
    static func forMessage(_ m: ParsedMessage, me: String) -> AssistantContext {
        .reading(from: m.from.map(\.headerValue).joined(separator: ", "),
                 to: m.to.map(\.headerValue).joined(separator: ", "),
                 cc: m.cc.map(\.headerValue).joined(separator: ", "),
                 date: m.date, subject: m.subject,
                 text: m.textBody ?? m.htmlBody.map(HTMLText.toPlain) ?? "",
                 me: me)
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
}
