import SwiftUI
import SlyyMailKit
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var sending = false
    @State private var importing = false
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
                        .focused($focus, equals: .body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 300)
                }
                .padding(16)
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
            Button("Save Draft") { Task { _ = await model.saveDraft(draft); dismiss() } }
            Button("Discard", role: .destructive) { dismiss() }
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
        .task { await autosave() }
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
    }

    var topBar: some View {
        HStack(spacing: 8) {
            Button("Cancel") { if draft.isEmpty { dismiss() } else { confirmClose = true } }
                .buttonStyle(.slyyOutline)
                .keyboardShortcut(.cancelAction)
            Text(draft.subject.isEmpty ? String(localized: "New message") : draft.subject)
                .font(Slyy.font(15, .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Button { importing = true } label: { Image(systemName: SlyyIcon.attach).frame(width: 34, height: 34).hairlineBorder() }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach file")
            Button { addVideo() } label: { Label("Add video link", systemImage: SlyyIcon.video) }
                .buttonStyle(.slyyOutline)
                .disabled(draft.videoURL != nil)
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
            if let saved = draft.lastSaved {
                Text("Draft saved to Drafts · \(saved.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            if let a = model.account {
                Text("Sent from \(a.email) via \(a.smtp.host) · \(a.smtp.security == .plain ? "no encryption" : "TLS")")
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
        if await model.send(draft) { dismiss() }
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
    func autosave() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
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
