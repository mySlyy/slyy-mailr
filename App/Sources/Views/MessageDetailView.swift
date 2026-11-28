import SwiftUI
import SlyyMailKit
import UniformTypeIdentifiers
import QuickLook

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var allowImages = false
    @State private var exporting: Attachment?
    /// iPhone: Ask Haven as a bottom sheet.
    @State private var askSheet = false

    var phone: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if model.openConversation.count > 1, let m = model.openMessage, let s = model.openSummary {
                VStack(spacing: 0) {
                    if !phone { actionBar(m, s) }
                    ConversationAccordion(phone: phone)
                    askBar(m)
                    if phone { phoneReplyBar(m) }
                }
            } else if let m = model.openMessage, let s = model.openSummary {
                VStack(alignment: .leading, spacing: 0) {
                    if !phone { actionBar(m, s) }
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 16) {
                            header(m, s)
                            if let invite = invite(in: m) {
                                InviteCard(invite: invite.event, method: invite.method, phone: phone)
                            }
                            if !visibleAttachments(m).isEmpty { attachments(m) }
                            if hasRemoteContent(m) && !allowImages {
                                HStack(spacing: 8) {
                                    Image(systemName: "photo")
                                    Text("Remote images are blocked to protect your privacy.")
                                    Spacer()
                                    Button("Load images") { allowImages = true }
                                        .buttonStyle(SlyyOutlineButtonStyle(height: 28))
                                }
                                .font(Slyy.font(13))
                                .padding(10)
                                .background(Slyy.panel)
                            }
                        }
                        .padding(.horizontal, phone ? 18 : 28)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                        .frame(maxWidth: 760, alignment: .leading)
                        MailHTMLView(html: MessageBody.html(m), allowRemoteContent: allowImages, zoom: model.bodyZoom, onMailto: { url in
                            model.compose(.mailto(url))
                        })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, phone ? 2 : 12)
                    }
                    askBar(m)
                    if phone { phoneReplyBar(m) }
                }
                .id(s.id)
                .onChange(of: s.id) { _, _ in allowImages = false }
                #if os(iOS)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { Task { await model.archive([s]) } } label: { Image(systemName: "archivebox") }
                            .accessibilityLabel("Archive")
                        Button { Task { await model.delete([s]) } } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete")
                    }
                }
                #endif
            } else if model.isLoadingMessage {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "envelope").font(.system(size: 28)).foregroundStyle(Slyy.lineStrong)
                    Text("No message selected").foregroundStyle(Slyy.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting.map { AttachmentDocument(data: $0.data) },
                      contentType: .data,
                      defaultFilename: exporting?.filename) { _ in exporting = nil }
    }

    /// "Ask Haven about this mail…" with quick actions (only with Slyy Haven connected).
    @ViewBuilder
    func askBar(_ m: ParsedMessage) -> some View {
        if model.havenState == .connected {
            AskHavenBar(
                context: { .forMessage(m, me: model.account?.email ?? "", thread: model.openConversation.compactMap { model.conversationBodies[$0.id] }) },
                quickActions: QuickAction.reader,
                draftButtons: [("Reply with this", { p in
                    model.compose(.reply(m))
                    model.composeDraft?.apply(p)
                })],
                placeholder: "Ask Haven about this mail…"
            )
            .id(m.messageID ?? m.subject) // a new conversation starts a fresh bar
        }
    }

    func actionBar(_ m: ParsedMessage, _ s: MessageSummary) -> some View {
        HStack(spacing: 4) {
            Button("Reply") { model.compose(.reply(m)) }
                .keyboardShortcut("r", modifiers: [.command])
            // ⌘A while no text field has the keyboard (there it stays Select All).
            Button("Reply all") { model.compose(.replyAll(m)) }
                .keyboardShortcut(model.typingInField ? nil : KeyboardShortcut("a", modifiers: .command))
            Button("Forward") { model.compose(.forward(m)) }
                .keyboardShortcut("f", modifiers: .command)
            Spacer()
            Button(s.isFlagged ? "Unflag" : "Flag") { Task { await model.toggleFlag("\\Flagged", for: [s]) } }
            Button("Archive") { Task { await model.archive([s]) } }
            Button("Delete") { Task { await model.delete([s]) } }
        }
        .buttonStyle(.slyyOutline)
        .headerBar(iOSTop: 10, bottom: 10)
    }

    func phoneReplyBar(_ m: ParsedMessage) -> some View {
        HStack(spacing: 8) {
            Button("Reply") { model.compose(.reply(m)) }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, height: 44))
            Button("Reply all") { model.compose(.replyAll(m)) }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, height: 44))
            Button("Forward") { model.compose(.forward(m)) }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, height: 44))
            if model.havenState == .connected {
                Button { askSheet = true } label: {
                    HStack(spacing: 6) { Circle().fill(Slyy.accent).frame(width: 8, height: 8); Text("Ask") }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Slyy.tint)
                        .overlay(Rectangle().stroke(Slyy.accent, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $askSheet) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        askBar(m)
                    }
                    .environment(model)
                    .presentationDetents([.medium, .large])
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
        .background(Color.white)
    }

    func header(_ m: ParsedMessage, _ s: MessageSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.subject.isEmpty ? String(localized: "(no subject)") : m.subject)
                .font(Slyy.font(phone ? 21 : 22, .semibold))
                .tracking(-0.2)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline) {
                if let from = m.from.first {
                    Menu {
                        Button("Write to \(from.address)") { model.compose(.to(from)) }
                        Button("Video call") { model.call([from]) }
                        Button("Copy address") { model.copyToClipboard(from.address) }
                    } label: {
                        (Text(from.name.isEmpty ? from.address : from.name).font(Slyy.font(14, .semibold)).foregroundStyle(Slyy.ink)
                         + Text(from.name.isEmpty ? "" : "  <\(from.address)>").font(Slyy.font(14)).foregroundStyle(Slyy.muted))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                Spacer()
                Text((m.date ?? s.date).formatted(date: .abbreviated, time: .shortened))
                    .font(Slyy.font(13))
                    .foregroundStyle(Slyy.muted)
            }
            if !m.to.isEmpty || !m.cc.isEmpty {
                Text(recipientLine(m))
                    .font(Slyy.font(13))
                    .foregroundStyle(Slyy.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    func recipientLine(_ m: ParsedMessage) -> String {
        var s = String(localized: "To") + " " + m.to.map(\.display).joined(separator: ", ")
        if !m.cc.isEmpty { s += " · " + String(localized: "Cc") + " " + m.cc.map(\.display).joined(separator: ", ") }
        return s
    }

    func visibleAttachments(_ m: ParsedMessage) -> [Attachment] {
        m.attachments.filter { !$0.isInline || $0.contentID == nil }
    }

    func attachments(_ m: ParsedMessage) -> some View {
        AttachmentChips(attachments: visibleAttachments(m))
    }

    // MARK: Body

    func hasRemoteContent(_ m: ParsedMessage) -> Bool { MessageBody.hasRemoteContent(m) }
    func invite(in m: ParsedMessage) -> (event: CalendarEvent, method: String)? { MessageBody.invite(in: m) }
}

/// Invitation card from the wireframe: date badge, title, when, organizer, Join; RSVP strip below.
struct InviteCard: View {
    @Environment(AppModel.self) private var model
    let invite: CalendarEvent
    let method: String
    var phone = false
    @State private var answered: ParticipationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if phone {
                VStack(alignment: .leading, spacing: 4) {
                    Text(EventFormat.short(invite).uppercased())
                        .font(Slyy.font(11, .semibold))
                        .tracking(0.66)
                        .foregroundStyle(Slyy.accent)
                    Text(invite.summary).font(Slyy.font(17, .semibold))
                    Text(subtitle).font(Slyy.font(13)).foregroundStyle(Slyy.ink2)
                }
                .padding(14)
                if let v = invite.videoURL {
                    Button { model.join(v) } label: { Label("Join video call", systemImage: SlyyIcon.video) }
                        .buttonStyle(.slyyAccent(fullWidth: true, height: 44))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            } else {
                HStack(spacing: 16) {
                    dateBadge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.summary).font(Slyy.font(16, .semibold))
                        Text(EventFormat.medium(invite) + (invite.recurrence.map { " · " + RepeatOption($0.frequency).label.lowercased() } ?? ""))
                            .foregroundStyle(Slyy.ink2)
                        Text(subtitle).font(Slyy.font(13)).foregroundStyle(Slyy.muted)
                    }
                    Spacer(minLength: 8)
                    if let v = invite.videoURL, method != "CANCEL" {
                        Button { model.join(v) } label: { Label("Join", systemImage: SlyyIcon.video) }
                            .buttonStyle(.slyyAccent())
                    }
                }
                .padding(16)
            }
            footer
        }
        .overlay(Rectangle().stroke(method == "CANCEL" ? Slyy.danger : Slyy.ink, lineWidth: 1))
    }

    var subtitle: String {
        var parts: [String] = []
        if let org = invite.organizer { parts.append(String(localized: "Organizer \(org.display)")) }
        if !invite.attendees.isEmpty { parts.append(String(localized: "\(invite.attendees.count) people")) }
        return parts.joined(separator: " · ")
    }

    var dateBadge: some View {
        VStack(spacing: 0) {
            Text(invite.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(Slyy.font(11, .medium))
                .tracking(0.66)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Slyy.accent)
            Text(invite.start.formatted(.dateTime.day()))
                .font(Slyy.font(22, .bold))
                .padding(.vertical, 4)
        }
        .frame(width: 56)
        .hairlineBorder()
    }

    @ViewBuilder
    var footer: some View {
        switch method {
        case "REQUEST":
            if phone {
                HStack(spacing: 0) {
                    rsvp("Accept", .accepted)
                    rsvp("Maybe", .tentative)
                    rsvp("Decline", .declined)
                }
                .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
            } else {
                HStack(spacing: 8) {
                    rsvp("Accept", .accepted)
                    rsvp("Maybe", .tentative)
                    rsvp("Decline", .declined)
                    Spacer()
                    Text(statusText).font(Slyy.font(13)).foregroundStyle(Slyy.ink2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Slyy.sidebar)
                .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
            }
        case "CANCEL":
            Text("This event was cancelled and removed from your calendar.")
                .font(Slyy.font(13))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Slyy.sidebar)
        case "REPLY":
            if let a = invite.attendees.first {
                Text("\(a.name.isEmpty ? a.email : a.name): \(EventFormat.status(a.status)) · applied to your calendar")
                    .font(Slyy.font(13))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Slyy.sidebar)
            }
        default:
            EmptyView()
        }
    }

    var current: ParticipationStatus? {
        answered ?? model.myStatus(in: invite)
    }

    var statusText: String {
        switch current {
        case .accepted?: return String(localized: "Accepted · reply sent, added to your calendar")
        case .tentative?: return String(localized: "Maybe · reply sent")
        case .declined?: return String(localized: "Declined · reply sent")
        default: return String(localized: "No answer yet")
        }
    }

    func rsvp(_ title: LocalizedStringKey, _ status: ParticipationStatus) -> some View {
        Button(title) {
            answered = status
            Task { await model.respond(to: invite, status: status) }
        }
        .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: phone, height: phone ? 48 : 36, selected: current == status))
    }
}

struct AttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Shares an attachment as a file with its real name.
struct AttachmentFile: Transferable {
    let attachment: Attachment

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(item.attachment.filename.replacingOccurrences(of: "/", with: "_"))
            try item.attachment.data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}

enum EventFormat {
    /// "Friday 27 Nov · 10:00 – 10:30"
    static func medium(_ e: CalendarEvent) -> String {
        let day = e.start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        if e.isAllDay { return day }
        return "\(day) · \(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"
    }

    /// "Fri 27 Nov · 10:00 – 10:30"
    static func short(_ e: CalendarEvent) -> String {
        let day = e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if e.isAllDay { return day }
        return "\(day) · \(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"
    }

    static func when(_ e: CalendarEvent) -> String {
        if e.isAllDay {
            let last = e.end.addingTimeInterval(-1)
            if Calendar.current.isDate(e.start, inSameDayAs: last) { return e.start.formatted(date: .complete, time: .omitted) }
            return "\(e.start.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
        }
        if Calendar.current.isDate(e.start, inSameDayAs: e.end) {
            return "\(e.start.formatted(date: .complete, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(e.start.formatted(date: .abbreviated, time: .shortened)) – \(e.end.formatted(date: .abbreviated, time: .shortened))"
    }

    static func status(_ s: ParticipationStatus) -> String {
        switch s {
        case .accepted: return String(localized: "Accepted")
        case .declined: return String(localized: "Declined")
        case .tentative: return String(localized: "Maybe")
        case .delegated: return String(localized: "Delegated")
        case .needsAction: return String(localized: "No answer yet")
        }
    }
}

enum MessageBody {
    static func html(_ m: ParsedMessage) -> String {
        if let html = m.htmlBody {
            return InlineImages.resolve(html, attachments: m.attachments)
        }
        return HTMLText.fromPlain(m.textBody ?? "")
    }

    static func hasRemoteContent(_ m: ParsedMessage) -> Bool {
        guard let html = m.htmlBody?.lowercased() else { return false }
        return html.contains("src=\"http") || html.contains("src='http") || html.contains("url(http") || html.contains("background=\"http")
    }

    static func invite(in m: ParsedMessage) -> (event: CalendarEvent, method: String)? {
        for part in m.calendarParts {
            let r = ICalendarReader.read(part)
            if let e = r.events.first(where: { $0.recurrenceID == nil }) ?? r.events.first {
                return (e, r.method ?? "PUBLISH")
            }
        }
        return nil
    }

    /// First words of the text, for folded messages ("Hallo Frau Weber, morgen 10 Uhr passt …").
    static func preview(_ m: ParsedMessage) -> String {
        let text = m.textBody ?? m.htmlBody.map(HTMLText.toPlain) ?? ""
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") && !$0.hasPrefix("On ") && $0 != "--" }
        return String(lines.joined(separator: " ").prefix(160))
    }
}

/// A conversation as folded sections (oldest first): one line per message, unfolding in place.
struct ConversationAccordion: View {
    @Environment(AppModel.self) private var model
    var phone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(MessageThreads.baseSubject(model.openConversation.last?.subject ?? ""))
                        .font(Slyy.font(phone ? 21 : 22, .semibold))
                        .tracking(-0.2)
                        .textSelection(.enabled)
                    Spacer()
                    Button(allOpen ? "Fold all" : "Unfold all") {
                        if allOpen {
                            model.expandedMessages = model.openSummary.map { [$0.id] } ?? []
                        } else {
                            Task { for m in model.openConversation { await model.unfold(m, focusing: false) } }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Slyy.font(13))
                    .foregroundStyle(Slyy.accent)
                }
                Text("\(model.openConversation.count) messages").font(Slyy.font(13)).foregroundStyle(Slyy.muted)
                ForEach(model.openConversation) { m in
                    AccordionSection(summary: m, phone: phone)
                }
            }
            .padding(.horizontal, phone ? 14 : 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .background(Color.white)
    }

    var allOpen: Bool { model.openConversation.allSatisfy { model.expandedMessages.contains($0.id) } }
}

struct AccordionSection: View {
    @Environment(AppModel.self) private var model
    let summary: MessageSummary
    var phone = false
    @State private var bodyHeight: CGFloat = 120
    @State private var allowImages = false

    var open: Bool { model.expandedMessages.contains(summary.id) }
    var focused: Bool { model.openSummary?.id == summary.id }
    var mine: Bool { model.isMine(summary.from.first?.address ?? "") }
    var parsed: ParsedMessage? { model.conversationBodies[summary.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await model.toggleFold(summary) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Slyy.muted)
                        .frame(width: 10)
                    Circle().fill(summary.isSeen ? Color.clear : Slyy.accent).frame(width: 7, height: 7)
                    Text(mine ? String(localized: "Me") : (summary.from.first?.display ?? "?"))
                        .font(Slyy.font(14, .semibold))
                        .lineLimit(1)
                    if mine { MonoTag(text: "SENT", background: Slyy.ink2) }
                    if open {
                        Text(recipients).font(Slyy.font(13)).foregroundStyle(Slyy.muted).lineLimit(1)
                    } else {
                        Text(parsed.map(MessageBody.preview) ?? summary.subject)
                            .font(Slyy.font(13)).foregroundStyle(Slyy.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if summary.hasAttachments { Image(systemName: "paperclip").imageScale(.small).foregroundStyle(Slyy.muted) }
                    Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(open ? Slyy.sidebar : Color.white)

            if open {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = parsed {
                        if let inv = MessageBody.invite(in: p) {
                            InviteCard(invite: inv.event, method: inv.method, phone: phone)
                        }
                        if !p.attachments.filter({ !$0.isInline || $0.contentID == nil }).isEmpty {
                            AttachmentChips(attachments: p.attachments.filter { !$0.isInline || $0.contentID == nil })
                        }
                        if MessageBody.hasRemoteContent(p) && !allowImages {
                            Button("Load images") { allowImages = true }
                                .buttonStyle(SlyyOutlineButtonStyle(height: 28))
                        }
                        MailHTMLView(html: MessageBody.html(p), allowRemoteContent: allowImages, zoom: model.bodyZoom, onHeight: { h in
                            bodyHeight = min(max(h, 60), 20000)
                        }, onMailto: { url in model.compose(.mailto(url)) })
                        .frame(height: bodyHeight)
                        HStack(spacing: 6) {
                            Button("Reply") { model.focus(summary); model.compose(.reply(p)) }
                            Button("Reply all") { model.focus(summary); model.compose(.replyAll(p)) }
                            Button("Forward") { model.focus(summary); model.compose(.forward(p)) }
                        }
                        .buttonStyle(SlyyOutlineButtonStyle(height: 30))
                    } else {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
                .padding(12)
                .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
                .onTapGesture { model.focus(summary) }
            }
        }
        .overlay(Rectangle().stroke(focused && open ? Slyy.ink : Slyy.line, lineWidth: 1))
    }

    var recipients: String {
        let to = (parsed?.to ?? summary.to).map(\.display).joined(separator: ", ")
        return to.isEmpty ? "" : String(localized: "to \(to)")
    }
}

/// Attachment chips with save/share/open.
struct AttachmentChips: View {
    let attachments: [Attachment]
    @State private var exporting: Attachment?
    /// File shown in Quick Look (tap a chip).
    @State private var previewURL: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    Menu {
                        Button("Quick Look") { preview(a) }
                        Button("Save…") { exporting = a }
                        ShareLink(item: AttachmentFile(attachment: a), preview: SharePreview(a.filename))
                        #if os(macOS)
                        Button("Open") { if let url = Self.temporaryFile(a) { NSWorkspace.shared.open(url) } }
                        #endif
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: SlyyIcon.doc).imageScale(.small)
                            Text("\(a.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))").lineLimit(1)
                        }
                        .font(Slyy.font(13))
                        .foregroundStyle(Slyy.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Slyy.panel)
                    } primaryAction: {
                        preview(a)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityHint("Opens a preview. Touch and hold for more.")
                }
            }
        }
        .quickLookPreview($previewURL)
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting.map { AttachmentDocument(data: $0.data) },
                      contentType: .data,
                      defaultFilename: exporting?.filename) { _ in exporting = nil }
    }

    func preview(_ a: Attachment) {
        previewURL = Self.temporaryFile(a)
    }

    /// Writes the attachment to a private temporary folder under its own name (Quick Look and Open need a file).
    static func temporaryFile(_ a: Attachment) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = a.filename.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "attachment" }
        let url = dir.appendingPathComponent(name)
        return (try? a.data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}
