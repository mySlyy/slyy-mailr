import SwiftUI
import SlyyMailKit
import UniformTypeIdentifiers

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var allowImages = false
    @State private var exporting: Attachment?

    var phone: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if let m = model.openMessage, let s = model.openSummary {
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
                        MailHTMLView(html: bodyHTML(m), allowRemoteContent: allowImages) { url in
                            model.compose(.mailto(url))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, phone ? 2 : 12)
                    }
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

    func actionBar(_ m: ParsedMessage, _ s: MessageSummary) -> some View {
        HStack(spacing: 4) {
            Button("Reply") { model.compose(.reply(m)) }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Reply all") { model.compose(.replyAll(m)) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { model.compose(.forward(m)) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Spacer()
            Button(s.isFlagged ? "Unflag" : "Flag") { Task { await model.toggleFlag("\\Flagged", for: [s]) } }
            Button("Archive") { Task { await model.archive([s]) } }
            Button("Delete") { Task { await model.delete([s]) } }
        }
        .buttonStyle(.slyyOutline)
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        .padding(.bottom, 10)
        .bottomHairline()
    }

    var topInset: CGFloat {
        #if os(macOS)
        return 30
        #else
        return 10
        #endif
    }

    func phoneReplyBar(_ m: ParsedMessage) -> some View {
        HStack(spacing: 8) {
            Button("Reply") { model.compose(.reply(m)) }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, height: 44))
            Button("Reply all") { model.compose(.replyAll(m)) }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, height: 44))
            Button("Forward") { model.compose(.forward(m)) }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, height: 44))
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleAttachments(m)) { a in
                    Menu {
                        Button("Save…") { exporting = a }
                        ShareLink(item: AttachmentFile(attachment: a), preview: SharePreview(a.filename))
                        #if os(macOS)
                        Button("Open") { openAttachment(a) }
                        #endif
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: SlyyIcon.doc).imageScale(.small)
                            Text("\(a.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))")
                                .lineLimit(1)
                        }
                        .font(Slyy.font(13))
                        .foregroundStyle(Slyy.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Slyy.panel)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
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

    // MARK: Body

    func bodyHTML(_ m: ParsedMessage) -> String {
        if let html = m.htmlBody {
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
                        .buttonStyle(SlyyAccentButtonStyle(fullWidth: true, height: 44))
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
                            .buttonStyle(.slyyAccent)
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
        answered ?? model.account.flatMap { invite.status(of: $0.email) }
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
