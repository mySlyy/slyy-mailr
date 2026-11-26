import SwiftUI
import SlyyMailKit
import UniformTypeIdentifiers

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var allowImages = false
    @State private var exporting: Attachment?

    var body: some View {
        Group {
            if let m = model.openMessage, let s = model.openSummary {
                VStack(alignment: .leading, spacing: 0) {
                    header(m, s)
                    if let invite = invite(in: m) {
                        InviteCard(invite: invite.event, method: invite.method)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }
                    if !visibleAttachments(m).isEmpty {
                        attachments(m)
                    }
                    if hasRemoteContent(m) && !allowImages {
                        HStack {
                            Image(systemName: "photo.badge.exclamationmark")
                            Text("Remote images are blocked to protect your privacy.")
                            Spacer()
                            Button("Load images") { allowImages = true }
                        }
                        .font(.callout)
                        .padding(8)
                        .background(.yellow.opacity(0.15))
                    }
                    Divider()
                    MailHTMLView(html: bodyHTML(m), allowRemoteContent: allowImages) { url in
                        model.compose(.mailto(url))
                    }
                }
                .id(s.id)
                .onChange(of: s.id) { _, _ in allowImages = false }
                .toolbar { toolbar(m, s) }
            } else if model.isLoadingMessage {
                ProgressView()
            } else {
                ContentUnavailableView("No message selected", systemImage: "envelope")
            }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting.map { AttachmentDocument(data: $0.data) },
                      contentType: .data,
                      defaultFilename: exporting?.filename) { _ in exporting = nil }
    }

    func header(_ m: ParsedMessage, _ s: MessageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(m.subject.isEmpty ? String(localized: "(no subject)") : m.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let from = m.from.first {
                        Menu {
                            Button("Write to \(from.address)") { model.compose(.to(from)) }
                            Button("Video call") { model.call([from]) }
                            Button("Copy address") { model.copyToClipboard(from.address) }
                        } label: {
                            Text(from.name.isEmpty ? from.address : "\(from.name) <\(from.address)>").fontWeight(.medium)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .fixedSize()
                    }
                    if !m.to.isEmpty { recipients("To", m.to) }
                    if !m.cc.isEmpty { recipients("Cc", m.cc) }
                }
                Spacer()
                Text((m.date ?? s.date).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    func recipients(_ label: LocalizedStringKey, _ list: [EmailAddress]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(list.map(\.display).joined(separator: ", ")).lineLimit(2).textSelection(.enabled)
        }
        .font(.caption)
    }

    func visibleAttachments(_ m: ParsedMessage) -> [Attachment] {
        m.attachments.filter { !$0.isInline || $0.contentID == nil }
    }

    func attachments(_ m: ParsedMessage) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(visibleAttachments(m)) { a in
                    Menu {
                        Button("Save…") { exporting = a }
                        ShareLink(item: AttachmentFile(attachment: a), preview: SharePreview(a.filename))
                        #if os(macOS)
                        Button("Open") { openAttachment(a) }
                        #endif
                    } label: {
                        Label("\(a.filename) (\(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file)))", systemImage: "doc")
                            .lineLimit(1)
                    }
                    .menuStyle(.button)
                        .buttonStyle(.borderless)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    #if os(macOS)
    func openAttachment(_ a: Attachment) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(a.filename.replacingOccurrences(of: "/", with: "_"))
        guard (try? a.data.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
    #endif

    @ToolbarContentBuilder
    func toolbar(_ m: ParsedMessage, _ s: MessageSummary) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.compose(.reply(m)) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .keyboardShortcut("r", modifiers: [.command])
            Button { model.compose(.replyAll(m)) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button { model.compose(.forward(m)) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button { Task { await model.toggleFlag("\\Flagged", for: [s]) } } label: {
                Label(s.isFlagged ? "Unflag" : "Flag", systemImage: s.isFlagged ? "flag.slash" : "flag")
            }
            Button { Task { await model.archive([s]) } } label: { Label("Archive", systemImage: "archivebox") }
            Button(role: .destructive) { Task { await model.delete([s]) } } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: Body

    func bodyHTML(_ m: ParsedMessage) -> String {
        if let html = m.htmlBody {
            // Inline images referenced as cid: are embedded as data: URLs.
            var out = html
            for a in m.attachments where a.contentID != nil {
                out = out.replacingOccurrences(of: "cid:\(a.contentID!)", with: "data:\(a.mimeType);base64,\(a.data.base64EncodedString())")
            }
            return out
        }
        return HTMLText.fromPlain(m.textBody ?? "")
    }

    func hasRemoteContent(_ m: ParsedMessage) -> Bool {
        guard let html = m.htmlBody?.lowercased() else { return false }
        return html.contains("src=\"http") || html.contains("src='http") || html.contains("url(http") || html.contains("background=\"http")
    }

    func invite(in m: ParsedMessage) -> (event: CalendarEvent, method: String)? {
        for part in m.calendarParts {
            let r = ICalendarReader.read(part)
            if let e = r.events.first(where: { $0.recurrenceID == nil }) ?? r.events.first {
                return (e, r.method ?? "PUBLISH")
            }
        }
        return nil
    }
}

/// Invitation summary with RSVP buttons (REQUEST), or info for REPLY/CANCEL.
struct InviteCard: View {
    @Environment(AppModel.self) private var model
    let invite: CalendarEvent
    let method: String
    @State private var answered: ParticipationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: method == "CANCEL" ? "calendar.badge.minus" : "calendar.badge.clock")
                    .font(.title2)
                    .foregroundStyle(method == "CANCEL" ? Color.red : Color.accentColor)
                VStack(alignment: .leading) {
                    Text(invite.summary).font(.headline)
                    Text(EventFormat.when(invite)).font(.callout).foregroundStyle(.secondary)
                    if let org = invite.organizer { Text("Organizer: \(org.display)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let v = invite.videoURL {
                    Button { model.join(v) } label: { Label("Join", systemImage: "video.fill") }
                        .buttonStyle(.borderedProminent)
                }
            }
            switch method {
            case "REQUEST":
                HStack {
                    rsvp("Accept", .accepted, "checkmark.circle")
                    rsvp("Maybe", .tentative, "questionmark.circle")
                    rsvp("Decline", .declined, "xmark.circle")
                    Spacer()
                    if let a = answered ?? myStatus, a != .needsAction {
                        Text(EventFormat.status(a)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case "CANCEL":
                Text("This event was cancelled and removed from your calendar.").font(.callout)
            case "REPLY":
                if let a = invite.attendees.first {
                    Text("\(a.name.isEmpty ? a.email : a.name): \(EventFormat.status(a.status))").font(.callout)
                }
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    var myStatus: ParticipationStatus? {
        model.account.flatMap { invite.status(of: $0.email) }
    }

    func rsvp(_ title: LocalizedStringKey, _ status: ParticipationStatus, _ icon: String) -> some View {
        Button {
            answered = status
            Task { await model.respond(to: invite, status: status) }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.bordered)
        .tint(answered == status ? .accentColor : nil)
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
