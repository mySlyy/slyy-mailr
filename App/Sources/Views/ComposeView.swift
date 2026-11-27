import SwiftUI
import SlyyMailKit
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
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
    @State private var lastSaved: String = ""
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
                    if let v = draft.videoURL { videoCard(v) }
                    TextEditor(text: $draft.body)
                        .font(Slyy.font(14))
                        .lineSpacing(4)
                        .foregroundStyle(draft.blueReply ? (Color(hex: draft.replyColor) ?? Slyy.accent) : Slyy.ink)
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
                    draftAction: "Insert",
                    onDraft: { draft.apply($0) },
                    placeholder: "Ask Haven to write, shorten, translate…"
                )
            }
            footer
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .background(Color.white)
        .tint(Slyy.accent)
        .preferredColorScheme(.light)
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 860, minHeight: 560, idealHeight: 680)
        #endif
        .interactiveDismissDisabled(!draft.isEmpty)
        .confirmationDialog("Save this message as a draft?", isPresented: $confirmClose) {
            Button("Save Draft") { Task { _ = await model.saveDraft(draft); close() } }
            Button("Discard", role: .destructive) { close() }
            Button("Keep Editing", role: .cancel) {}
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
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
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
            Button("Cancel") { if draft.isEmpty { close() } else { confirmClose = true } }
                .buttonStyle(.slyyOutline)
                .keyboardShortcut(.cancelAction)
            Text(draft.subject.isEmpty ? String(localized: "New message") : draft.subject)
                .font(Slyy.font(15, .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            attachButton
            if compact {
                Button { addVideo() } label: { Image(systemName: SlyyIcon.video).frame(width: 34, height: 34).hairlineBorder() }
                    .buttonStyle(.plain)
                    .disabled(draft.videoURL != nil)
                    .accessibilityLabel("Add video link")
            } else {
                Button { addVideo() } label: { Label("Add video link", systemImage: SlyyIcon.video) }
                    .buttonStyle(.slyyOutline)
                    .disabled(draft.videoURL != nil)
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
            .buttonStyle(SlyyAccentButtonStyle(height: 34))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(sending || (draft.to.trimmingCharacters(in: .whitespaces).isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty))
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
                Text(v.absoluteString).font(Slyy.mono(12)).foregroundStyle(Slyy.ink2).textSelection(.enabled)
            }
            Spacer()
            Button("Remove") { draft.videoURL = nil }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true, height: 32))
        }
        .padding(12)
        .background(Slyy.tint)
        .overlay(Rectangle().stroke(Slyy.accent, lineWidth: 1))
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

    var footer: some View {
        HStack {
            if draft.recovered {
                Text("Recovered after Mailr quit unexpectedly").foregroundStyle(Slyy.accent)
            } else if let saved = draft.lastSaved {
                Text("Draft saved to Drafts · \(saved.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            if let a = model.account {
                Text("Sent from \(currentIdentity?.email ?? a.email) via \(a.smtp.host) · \(a.smtp.security == .plain ? "no encryption" : "TLS")")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(Slyy.font(12))
        .foregroundStyle(Slyy.muted)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
    }

    func send() async {
        sending = true
        defer { sending = false }
        if await model.send(draft) { close() }
    }

    func addVideo() {
        draft.videoURL = JitsiRoom.newURL(server: model.account?.jitsiURL ?? JitsiRoom.defaultServer)
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
        "\(draft.to)|\(draft.cc)|\(draft.bcc)|\(draft.subject)|\(draft.body)|\(draft.quoted)|\(draft.attachments.count)|\(draft.videoURL?.absoluteString ?? "")|\(draft.from?.email ?? "")|\(draft.draftUID ?? 0)"
    }

    /// Normal close (sent, saved to Drafts, discarded): the crash copy is no longer needed.
    func close() {
        DraftJournal.standard.remove(draft.id)
        dismiss()
    }

    func autosave() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard model.autoSave else { continue }
            let fingerprint = "\(draft.to)|\(draft.cc)|\(draft.bcc)|\(draft.subject)|\(draft.body)|\(draft.attachments.count)|\(draft.videoURL?.absoluteString ?? "")"
            guard !draft.isEmpty, fingerprint != lastSaved, !sending else { continue }
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

    var tokens: [String] {
        text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Complete addresses before the last comma become chips.
    var chips: [EmailAddress] {
        EmailAddress.parseList(tokens.dropLast().joined(separator: ","))
    }

    var current: String { tokens.last ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(label).foregroundStyle(Slyy.muted).frame(width: 56, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { i, a in
                            HStack(spacing: 6) {
                                Text(a.name.isEmpty ? a.address : a.name)
                                if !a.name.isEmpty { Text(a.address).font(Slyy.font(12)).foregroundStyle(Slyy.muted) }
                                Button { remove(at: i) } label: { Image(systemName: "xmark").imageScale(.small) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(a.address)")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(a.isValid ? Slyy.panel : Slyy.orangeTint)
                        }
                    }
                }
                .frame(maxWidth: chips.isEmpty ? 0 : .infinity)
                TextField("", text: Binding(get: { current }, set: { setCurrent($0) }))
                    .textFieldStyle(.plain)
                    .focused(focus, equals: field)
                    .onSubmit { commitCurrent() }
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .frame(minWidth: 120)
                trailing()
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
        var t = tokens
        if t.isEmpty { t = [value] } else { t[t.count - 1] = value }
        text = t.joined(separator: ", ")
    }

    func commitCurrent() {
        if !current.isEmpty { text = tokens.filter { !$0.isEmpty }.joined(separator: ", ") + ", " }
    }

    func remove(at index: Int) {
        var list = chips
        list.remove(at: index)
        text = list.map(\.headerValue).joined(separator: ", ") + (list.isEmpty ? "" : ", ") + current
    }

    func pick(_ a: EmailAddress) {
        var t = tokens
        if !t.isEmpty { t.removeLast() }
        t.append(a.headerValue)
        text = t.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }
}

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
