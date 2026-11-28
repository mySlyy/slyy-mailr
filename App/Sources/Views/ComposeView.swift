import SwiftUI
import SlyyMailKit
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#else
import AppKit
#endif

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var sending = false
    @State private var importing = false
    #if os(iOS)
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var confirmClose = false
    @State private var editingMeeting = false
    /// Why Send failed, shown on this sheet / window (not on the main window behind it).
    @State private var sendError: String?
    /// Closed by Cancel / Send / Save Draft (not by the window's close button).
    @State private var closed = false
    @State private var lastSaved: String = ""
    /// The content as the window opened (signature left out), to tell whether anything was written since.
    @State private var openedKey: String?
    @FocusState private var focus: Field?

    enum Field: Hashable { case to, cc, bcc, subject, body }

    init(draft: ComposeDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if model.identities.count > 1 { fromRow }
            AddressField(label: "To", text: $draft.to, focus: $focus, field: .to) {
                if !draft.showCcBcc {
                    Button("Cc / Bcc") { draft.showCcBcc = true }
                        .buttonStyle(.plain)
                        .font(Slyy.font(13))
                        .foregroundStyle(Slyy.ink2)
                }
            }
            if draft.showCcBcc {
                AddressField(label: "Cc", text: $draft.cc, focus: $focus, field: .cc) { EmptyView() }
                AddressField(label: "Bcc", text: $draft.bcc, focus: $focus, field: .bcc) { EmptyView() }
            }
            HStack(spacing: 10) {
                Text("Subject").foregroundStyle(Slyy.muted).frame(width: 56, alignment: .leading)
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .subject)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .bottomHairline()

            if !draft.attachments.isEmpty { attachmentStrip }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let m = draft.meeting { meetingCard(m) }
                    if let v = draft.videoURL { videoCard(v) }
                    TextEditor(text: $draft.body)
                        .font(Slyy.font(14))
                        .lineSpacing(4)
                        .foregroundStyle(draft.blueReply ? (Color(sixDigitHex: draft.replyColor) ?? Slyy.accent) : Slyy.ink)
                        .focused($focus, equals: .body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: draft.quoted.isEmpty ? 300 : 120)
                    if !draft.quoted.isEmpty {
                        TextEditor(text: $draft.quoted)
                            .font(Slyy.font(14))
                            .lineSpacing(4)
                            .foregroundStyle(Slyy.ink2)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 180)
                            .accessibilityLabel("Quoted message")
                    }
                }
                .padding(16)
            }

            if model.havenState == .connected {
                AskHavenBar(
                    context: { .forDraft(draft, from: currentIdentity?.email ?? model.account?.email ?? "") },
                    quickActions: QuickAction.writer,
                    draftButtons: [("Replace my text", { draft.apply($0) }), ("Insert below", { draft.insert($0) })],
                    placeholder: "Ask Haven to write, shorten, translate, look something up…"
                )
            }
            footer
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .background(Color.white)
        .tint(Slyy.accent)
        .preferredColorScheme(.light)
        .overlay { if confirmClose { closePrompt } }
        #if os(macOS)
        // Sheet: opens at the ideal size. Own window: resizable from the minimum up, no maximum.
        .frame(minWidth: 680, idealWidth: 860, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .navigationTitle(draft.subject.isEmpty ? String(localized: "New Message") : draft.subject)
        // Esc also while the cursor is in the text (the text view would keep Esc for word completion).
        .background(EscapeKeyCatcher { cancelTapped() })
        .onDisappear {
            // Window closed with its close button: the text is kept in Drafts instead of being lost.
            guard !closed, !untouched else { return }
            let d = draft
            Task {
                let saved = await model.saveDraft(d)
                if saved.draftUID != nil { DraftJournal.standard.remove(d.id) }
            }
        }
        #endif
        .interactiveDismissDisabled(!untouched)
        .onAppear { if openedKey == nil { openedKey = currentKey } }
        .alert("Not sent", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { addAttachment(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in addAttachment(url) } }
                }
            }
            return true
        }
        #if os(iOS)
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                if let data = PhotoAttachment.jpeg(image) { addPhoto(data) }
            }
            .ignoresSafeArea()
        }
        #endif
        .task { await autosave() }
        // Crash safety: written to disk a second after the last change.
        .task(id: journalKey) {
            guard model.autoSave else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            DraftJournal.standard.save(draft)
        }
        .onAppear {
            focus = draft.to.isEmpty ? .to : .body
            #if os(macOS)
            // Replies and forwards start on the first line (above the signature and quote), not at the end.
            if draft.inReplyTo != nil || !draft.quoted.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NSApp.sendAction(#selector(NSTextView.moveToBeginningOfDocument(_:)), to: nil, from: nil)
                }
            }
            #endif
        }
    }

    #if os(iOS)
    func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let jpeg = UIImage(data: data).flatMap(PhotoAttachment.jpeg) { addPhoto(jpeg) }
        }
    }

    func addPhoto(_ jpeg: Data) {
        let n = draft.attachments.filter { $0.filename.hasPrefix("Photo ") }.count + 1
        draft.attachments.append(OutgoingAttachment(filename: "Photo \(n).jpg", mimeType: "image/jpeg", data: jpeg))
    }

    var compact: Bool { sizeClass == .compact }
    #else
    var compact: Bool { false }
    #endif

    @ViewBuilder var attachButton: some View {
        #if os(iOS)
        Menu {
            Button { pickingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { takingPhoto = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            Button { importing = true } label: { Label("Files", systemImage: "folder") }
        } label: {
            Image(systemName: SlyyIcon.attach).frame(width: 34, height: 34).hairlineBorder()
        }
        .accessibilityLabel("Attach")
        #else
        Button { importing = true } label: { Image(systemName: SlyyIcon.attach).frame(width: 34, height: 34).hairlineBorder() }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach file")
        #endif
    }

    var topBar: some View {
        HStack(spacing: 8) {
            Button("Cancel") { cancelTapped() }
                .buttonStyle(.slyyOutline)
                .keyboardShortcut(.cancelAction)
            Text(draft.subject.isEmpty ? String(localized: "New message") : draft.subject)
                .font(Slyy.font(15, .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            attachButton
            Button { addVideo() } label: { Image(systemName: SlyyIcon.video).frame(width: 34, height: 34).hairlineBorder() }
                .buttonStyle(.plain)
                .disabled(draft.videoURL != nil || draft.meeting?.videoURL != nil)
                .help("Add video link")
                .accessibilityLabel("Add video link")
            if model.hasCalendar {
                Button { editingMeeting = true } label: { Image(systemName: "calendar.badge.plus").frame(width: 34, height: 34).hairlineBorder() }
                    .buttonStyle(.plain)
                    .help("Add meeting invitation")
                    .accessibilityLabel("Add meeting invitation")
                    .popover(isPresented: $editingMeeting, arrowEdge: .bottom) {
                        MeetingEditor(
                            meeting: draft.meeting ?? newMeeting(),
                            isNew: draft.meeting == nil,
                            newVideoURL: { model.newMeetingURL() },
                            onDone: { setMeeting($0) },
                            onCancel: { editingMeeting = false }
                        )
                    }
            }
            Button {
                Task { await send() }
            } label: {
                if sending {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Label("Send", systemImage: SlyyIcon.send)
                }
            }
            .buttonStyle(.slyyAccent(height: 34))
            .keyboardShortcut(.return, modifiers: .command)
            // With a meeting, Send stays on and asks for the people to invite.
            .disabled(sending || (draft.meeting == nil && draft.to.trimmingCharacters(in: .whitespaces).isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .bottomHairline()
    }

    var currentIdentity: SenderIdentity? {
        draft.from ?? model.account?.defaultIdentity ?? model.identities.first
    }

    /// "From" with the account address and its aliases.
    var fromRow: some View {
        HStack(spacing: 10) {
            Text("From").foregroundStyle(Slyy.muted).frame(width: 56, alignment: .leading)
            Menu {
                ForEach(model.identities) { id in
                    Button {
                        switchIdentity(to: id)
                    } label: {
                        Text(id.name.isEmpty ? id.email : "\(id.name) <\(id.email)>")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let c = currentIdentity {
                        Text(c.name.isEmpty ? c.email : c.name).font(Slyy.font(14, .semibold))
                        if !c.name.isEmpty { Text(c.email).font(Slyy.font(13)).foregroundStyle(Slyy.ink2) }
                    }
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Slyy.muted)
                }
                .foregroundStyle(Slyy.ink)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .bottomHairline()
    }

    /// Changes the sender and swaps the signature block if the old one is still in the text.
    func switchIdentity(to id: SenderIdentity) {
        let oldSig = currentIdentity.map { model.signature(for: $0) } ?? ""
        let newSig = model.signature(for: id)
        if !oldSig.isEmpty, draft.body.contains("-- \n" + oldSig) {
            draft.body = draft.body.replacingOccurrences(of: "-- \n" + oldSig, with: newSig.isEmpty ? "" : "-- \n" + newSig)
        } else if oldSig.isEmpty, !newSig.isEmpty, !draft.body.contains("-- \n") {
            draft.body += "\n\n-- \n" + newSig
        }
        draft.from = id
    }

    func videoCard(_ v: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: SlyyIcon.video).foregroundStyle(Slyy.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Join video call / Videokonferenz beitreten").font(Slyy.font(14, .semibold))
                VideoLinkField(url: v) { draft.videoURL = $0 }
            }
            Spacer()
            Button("Remove") { draft.videoURL = nil }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, height: 32))
        }
        .padding(12)
        .background(Slyy.tint)
        .overlay(Rectangle().stroke(Slyy.accent, lineWidth: 1))
    }

    func meetingCard(_ m: MeetingInvite) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar").foregroundStyle(Slyy.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(meetingTitle(m)).font(Slyy.font(14, .semibold))
                Text(m.start.formatted(date: .complete, time: .shortened) + " – " + m.end.formatted(date: .omitted, time: .shortened))
                    .font(Slyy.font(13))
                    .foregroundStyle(Slyy.ink2)
                if let v = m.videoURL {
                    VideoLinkField(url: v) { draft.meeting?.videoURL = $0 }
                }
                Text("Everyone in To and Cc is invited. Saved in your calendar when you send.")
                    .font(Slyy.font(12))
                    .foregroundStyle(Slyy.muted)
            }
            Spacer()
            if model.hasCalendar {
                Button("Edit") { editingMeeting = true }
                    .buttonStyle(SlyyOutlineButtonStyle(strong: true, height: 32))
            }
            Button("Remove") { draft.meeting = nil }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, height: 32))
        }
        .padding(12)
        .background(Slyy.tint)
        .overlay(Rectangle().stroke(Slyy.accent, lineWidth: 1))
    }

    func meetingTitle(_ m: MeetingInvite) -> String {
        let t = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return draft.subject.isEmpty ? String(localized: "Meeting") : draft.subject
    }

    /// A new meeting: the subject as title, the next half hour, 30 minutes, with a video link (the mail's own, if it has one).
    func newMeeting() -> MeetingInvite {
        MeetingInvite(title: draft.subject, start: AppModel.nextHalfHour(), minutes: 30,
                      videoURL: draft.videoURL ?? model.newMeetingURL())
    }

    func setMeeting(_ m: MeetingInvite) {
        draft.meeting = m
        // The meeting card shows the link; the mail's own video card would repeat it.
        if let v = m.videoURL, v == draft.videoURL { draft.videoURL = nil }
        if draft.subject.isEmpty { draft.subject = m.title.isEmpty ? String(localized: "Meeting") : m.title }
        editingMeeting = false
    }

    /// Cancel button and Esc: closes an untouched message, else asks; with the question open, Esc keeps editing.
    func cancelTapped() {
        if confirmClose {
            confirmClose = false
        } else if untouched {
            close()
        } else {
            focus = nil // so Return answers the question instead of typing a new line
            confirmClose = true
        }
    }

    /// "Save this message as a draft?" in Slyy's own style, over the dimmed editor.
    var closePrompt: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 16) {
                Text("Save this message as a draft?")
                    .font(Slyy.font(16, .semibold))
                    .foregroundStyle(Slyy.ink)
                Text("Saved drafts are in the Drafts folder.")
                    .font(Slyy.font(13))
                    .foregroundStyle(Slyy.ink2)
                HStack(spacing: 8) {
                    Button { close() } label: { Text("Discard").foregroundStyle(Slyy.danger) }
                        .buttonStyle(.slyyOutline)
                        .overlay(Rectangle().stroke(Slyy.danger, lineWidth: 1))
                    Spacer(minLength: 16)
                    Button("Keep Editing") { confirmClose = false }
                        .buttonStyle(.slyyOutline)
                    Button("Save Draft") { Task { _ = await model.saveDraft(draft); close() } }
                        .buttonStyle(.slyyPrimary(height: 34))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(Color.white)
            .hairlineBorder()
            .padding(24)
            .accessibilityAddTraits(.isModal)
        }
        .font(Slyy.body)
    }

    var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(draft.attachments.enumerated()), id: \.offset) { i, a in
                    HStack(spacing: 6) {
                        Image(systemName: SlyyIcon.doc).imageScale(.small)
                        Text("\(a.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))").lineLimit(1)
                        Button { draft.attachments.remove(at: i) } label: { Image(systemName: "xmark").imageScale(.small) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove attachment")
                    }
                    .font(Slyy.font(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Slyy.panel)
                }
                Text("Drop files anywhere to attach").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .bottomHairline()
    }

    /// Only what's useful: the draft status, and a warning if the mail would go out unencrypted. Nothing to say: no bar.
    @ViewBuilder var footer: some View {
        let unencrypted = model.account?.smtp.security == .plain
        if draft.recovered || draft.lastSaved != nil || unencrypted {
            HStack(spacing: 12) {
                if draft.recovered {
                    Text("Recovered after Mailr quit unexpectedly").foregroundStyle(Slyy.accent)
                } else if let saved = draft.lastSaved {
                    Text("Draft saved \(saved.formatted(date: .omitted, time: .shortened))")
                }
                Spacer()
                if unencrypted {
                    Label("Not encrypted: this mail is sent without TLS", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Slyy.danger)
                        .lineLimit(1)
                }
            }
            .font(Slyy.font(12))
            .foregroundStyle(Slyy.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
        }
    }

    func send() async {
        sending = true
        defer { sending = false }
        if await model.send(draft, onError: { sendError = $0 }) { close() }
    }

    func addVideo() {
        draft.videoURL = model.newMeetingURL()
        if draft.subject.isEmpty { draft.subject = String(localized: "Video call") }
    }

    func addAttachment(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            model.errorMessage = String(localized: "Could not read \(url.lastPathComponent).")
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
    }

    /// Saves to the Drafts folder every 10 s while there are unsaved changes.
    /// Changes whenever anything in the mail changes.
    var journalKey: String {
        "\(draft.to)|\(draft.cc)|\(draft.bcc)|\(draft.subject)|\(draft.body)|\(draft.quoted)|\(draft.attachments.count)|\(draft.videoURL?.absoluteString ?? "")|\(draft.meeting.map(ComposeDraft.meetingKey) ?? "")|\(draft.from?.email ?? "")|\(draft.draftUID ?? 0)"
    }

    /// Normal close (sent, saved to Drafts, discarded): the crash copy is no longer needed.
    var currentKey: String { draft.contentKey(signature: currentIdentity.map { model.signature(for: $0) } ?? "") }

    /// Empty, or exactly as opened (a new mail with only the signature, an unanswered reply): closes without asking.
    /// A draft recovered after a crash always asks, so its text isn't dropped by accident.
    var untouched: Bool { draft.isEmpty || (!draft.recovered && openedKey == currentKey) }

    func close() {
        closed = true
        confirmClose = false
        DraftJournal.standard.remove(draft.id)
        dismiss()
    }

    func autosave() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard model.autoSave else { continue }
            let fingerprint = "\(draft.to)|\(draft.cc)|\(draft.bcc)|\(draft.subject)|\(draft.body)|\(draft.attachments.count)|\(draft.videoURL?.absoluteString ?? "")|\(draft.meeting.map(ComposeDraft.meetingKey) ?? "")"
            guard !untouched, fingerprint != lastSaved, !sending else { continue }
            let saved = await model.saveDraft(draft)
            if saved.draftUID != nil || draft.draftUID == nil {
                draft.draftUID = saved.draftUID
                draft.lastSaved = Date()
            }
            lastSaved = fingerprint
        }
    }
}

/// Recipient row: label, chips for complete addresses, a text field for the one being typed, suggestions below.
struct AddressField<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    let label: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field
    @ViewBuilder var trailing: () -> Trailing

    var editing: Bool { focus.wrappedValue == field }

    /// Finished addresses; while the field isn't being edited every entry is one (e.g. a reply's prefilled To).
    var chipTexts: [String] { editing ? AddressEntry.chips(text) : AddressEntry.entries(text) }

    var chips: [EmailAddress] {
        chipTexts.map { EmailAddress.parseList($0).first ?? EmailAddress(name: "", address: $0) }
    }

    var current: String { editing ? (AddressEntry.tokens(text).last ?? "") : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).foregroundStyle(Slyy.muted).frame(width: 56, alignment: .leading)
                // Chips and the typing field flow on one line and wrap, the cursor right after the last chip.
                AddressFlow(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { i, a in
                        HStack(spacing: 6) {
                            Text(a.name.isEmpty ? a.address : a.name).lineLimit(1)
                            if !a.name.isEmpty { Text(a.address).font(Slyy.font(12)).foregroundStyle(Slyy.muted).lineLimit(1) }
                            Button { remove(at: i) } label: { Image(systemName: "xmark").imageScale(.small) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(a.address)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(a.isValid ? Slyy.panel : Slyy.orangeTint)
                        .help(a.isValid ? a.headerValue : String(localized: "Not a complete address"))
                    }
                    TextField("", text: Binding(get: { current }, set: { setCurrent($0) }))
                        .textFieldStyle(.plain)
                        .focused(focus, equals: field)
                        .onSubmit { text = AddressEntry.commit(text) }
                        .onKeyPress(.delete) {
                            // Backspace in an empty field deletes the last chip.
                            guard current.isEmpty, !chipTexts.isEmpty else { return .ignored }
                            text = AddressEntry.join(Array(chipTexts.dropLast()), current: "")
                            return .handled
                        }
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .frame(minWidth: 140)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { focus.wrappedValue = field }
                trailing()
            }
            .onChange(of: editing) { _, now in
                if !now { text = AddressEntry.entries(text).joined(separator: ", ") } // tidy when leaving the field
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            let suggestions = focus.wrappedValue == field ? model.contacts.suggestions(for: current) : []
            if !current.isEmpty && !suggestions.isEmpty && !suggestions.contains(where: { $0.address.caseInsensitiveCompare(current) == .orderedSame }) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, s in
                        Button { pick(s) } label: {
                            HStack(spacing: 6) {
                                Text(s.name.isEmpty ? s.address : s.name).font(Slyy.font(14, .semibold))
                                if !s.name.isEmpty { Text(s.address).font(Slyy.font(13)).foregroundStyle(Slyy.ink2) }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(i == 0 ? Slyy.tint : Color.white)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
                .overlay(Rectangle().stroke(Slyy.lineStrong, lineWidth: 1))
                .padding(.leading, 82)
                .padding(.bottom, 6)
            }
        }
        .bottomHairline()
    }

    func setCurrent(_ value: String) {
        text = AddressEntry.typing(value, chips: chipTexts)
    }

    func remove(at index: Int) {
        var list = chipTexts
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        text = editing ? AddressEntry.join(list, current: current) : list.joined(separator: ", ")
    }

    func pick(_ a: EmailAddress) {
        text = AddressEntry.join(chipTexts + [a.headerValue], current: "")
    }
}

/// Left-to-right flow that wraps; the last item (the typing field) takes the rest of its line.
struct AddressFlow: Layout {
    var spacing: CGFloat = 6

    /// The line breaking itself is ChipFlow.lines (unit-tested in the library); here only sizes and heights.
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, height: CGFloat)] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return ChipFlow.lines(widths: sizes.map { Double($0.width) }, available: Double(width), spacing: Double(spacing))
            .map { r in (r, r.map { sizes[$0].height }.max() ?? 0) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let r = rows(width, subviews)
        return CGSize(width: width, height: r.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, r.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.range {
                let s = subviews[i].sizeThatFits(.unspecified)
                let isLast = i == subviews.count - 1
                let w = isLast ? max(140, bounds.maxX - x) : min(s.width, bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: ProposedViewSize(width: w, height: s.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
    }
}

/// The video link on a card in the writer, editable. Only a full http(s) link is taken; while the text isn't one,
/// a hint shows and the last valid link stays the one sent.
struct VideoLinkField: View {
    let url: URL
    var onChange: (URL) -> Void
    @State private var text: String
    @State private var invalid = false

    init(url: URL, onChange: @escaping (URL) -> Void) {
        self.url = url
        self.onChange = onChange
        _text = State(initialValue: url.absoluteString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("https://…", text: $text)
                .textFieldStyle(.plain)
                .font(Slyy.mono(12))
                .foregroundStyle(Slyy.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.white)
                .hairlineBorder(invalid ? Slyy.danger : Slyy.line)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onChange(of: text) { _, t in take(t) }
                .onSubmit { take(text) }
                .onChange(of: url) { _, new in
                    // Changed elsewhere (the meeting editor): show the new link.
                    if JitsiRoom.parseLink(text) != new { text = new.absoluteString; invalid = false }
                }
                .accessibilityLabel("Video link")
            if invalid {
                Text("Enter a full link, e.g. https://…")
                    .font(Slyy.font(12))
                    .foregroundStyle(Slyy.danger)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    func take(_ t: String) {
        guard let u = JitsiRoom.parseLink(t) else {
            invalid = true
            return
        }
        invalid = false
        if u != url { onChange(u) }
    }
}

/// "Add meeting invitation": title, day, start, length and an optional video link for the meeting this mail invites to.
struct MeetingEditor: View {
    @State var meeting: MeetingInvite
    @State private var withVideo: Bool
    let isNew: Bool
    let newVideoURL: () -> URL
    var onDone: (MeetingInvite) -> Void
    var onCancel: () -> Void

    init(meeting: MeetingInvite, isNew: Bool, newVideoURL: @escaping () -> URL, onDone: @escaping (MeetingInvite) -> Void, onCancel: @escaping () -> Void) {
        _meeting = State(initialValue: meeting)
        _withVideo = State(initialValue: meeting.videoURL != nil || isNew)
        self.isNew = isNew
        self.newVideoURL = newVideoURL
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var durations: [Int] {
        var list = [15, 30, 45, 60, 90, 120]
        if !list.contains(meeting.minutes) { list.append(meeting.minutes); list.sort() }
        return list
    }

    static func durationText(_ minutes: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .short
        return f.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add meeting invitation" : "Meeting invitation")
                .font(Slyy.font(16, .semibold))
            row("Title") {
                TextField("Title", text: $meeting.title)
                    .textFieldStyle(SlyyFieldStyle(padding: 8))
            }
            HStack(spacing: 10) {
                row("Date") { boxed { DatePicker("Date", selection: $meeting.start, displayedComponents: [.date]) } }
                row("Starts") { boxed { DatePicker("Starts", selection: $meeting.start, displayedComponents: [.hourAndMinute]) } }
            }
            row("Duration") {
                boxed {
                    Picker("Duration", selection: $meeting.minutes) {
                        ForEach(durations, id: \.self) { m in Text(Self.durationText(m)).tag(m) }
                    }
                }
            }
            Toggle(isOn: $withVideo) { Text("Video link").font(Slyy.font(14)) }
                .toggleStyle(SlyySwitchStyle())
            Text("Everyone in To and Cc is invited. Saved in your calendar when you send.")
                .font(Slyy.font(12))
                .foregroundStyle(Slyy.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.slyyOutline)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") {
                    var m = meeting
                    m.videoURL = withVideo ? (m.videoURL ?? newVideoURL()) : nil
                    onDone(m)
                }
                .buttonStyle(.slyyPrimary(height: 34))
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .tint(Slyy.accent)
        .padding(18)
        #if os(macOS)
        .frame(width: 360)
        #else
        .frame(minWidth: 320)
        .presentationDetents([.medium, .large])
        #endif
        .background(Color.white)
    }

    func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            content()
        }
    }

    func boxed<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .hairlineBorder(Slyy.lineStrong)
    }
}

#if os(macOS)
/// Esc anywhere in the editor's window calls `onEscape`, also while the cursor is in the text
/// (an NSTextView keeps Esc for word completion, so the Cancel button's shortcut wouldn't fire).
/// Popovers and sheets are other windows and keep their own Esc; so does text being composed in an input method.
struct EscapeKeyCatcher: NSViewRepresentable {
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEscape: onEscape) }

    final class Coordinator {
        weak var view: NSView?
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) { self.onEscape = onEscape }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
                      let window = self.view?.window, event.window === window, window.attachedSheet == nil
                else { return event }
                if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return event }
                self.onEscape()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}
#endif

#if os(iOS)
/// Photos are sent as JPEG, at most 2560 px on the long side (a 12 MP original would make mails of 5 MB and more).
enum PhotoAttachment {
    static let maxSide: CGFloat = 2560

    static func jpeg(_ image: UIImage) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.82)
    }
}

/// System camera for "Take Photo".
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
