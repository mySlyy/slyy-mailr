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
        NavigationStack {
            VStack(spacing: 0) {
                AddressField(label: "To", text: $draft.to, focus: $focus, field: .to)
                if draft.showCcBcc {
                    AddressField(label: "Cc", text: $draft.cc, focus: $focus, field: .cc)
                    AddressField(label: "Bcc", text: $draft.bcc, focus: $focus, field: .bcc)
                }
                HStack {
                    Text("Subject").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    TextField("", text: $draft.subject)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .subject)
                    if !draft.showCcBcc {
                        Button("Cc/Bcc") { draft.showCcBcc = true }.buttonStyle(.borderless).font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
                if !draft.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Array(draft.attachments.enumerated()), id: \.offset) { i, a in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc")
                                    Text(a.filename).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file)).foregroundStyle(.secondary)
                                    Button { draft.attachments.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.borderless)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                            }
                        }
                        .padding(8)
                    }
                    Divider()
                }
                TextEditor(text: $draft.body)
                    .font(.body)
                    .focused($focus, equals: .body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            .navigationTitle(draft.subject.isEmpty ? String(localized: "New Message") : draft.subject)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft.isEmpty { dismiss() } else { confirmClose = true } }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Attach", systemImage: "paperclip") }
                    Button { insertVideoLink() } label: { Label("Add video call link", systemImage: "video.badge.plus") }
                        .help("Insert a link to a new video call on \(model.account?.jitsiURL ?? JitsiRoom.defaultServer)")
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane.fill") }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sending || draft.to.trimmingCharacters(in: .whitespaces).isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty)
                }
            }
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
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 480)
        #endif
        .interactiveDismissDisabled(!draft.isEmpty)
    }

    func send() async {
        sending = true
        defer { sending = false }
        if await model.send(draft) { dismiss() }
    }

    func insertVideoLink() {
        let url = JitsiRoom.newURL(server: model.account?.jitsiURL ?? JitsiRoom.defaultServer)
        let block = JitsiRoom.descriptionBlock(url)
        draft.body = block + "\n" + draft.body
        if draft.subject.isEmpty { draft.subject = String(localized: "Video call") }
    }

    func addAttachment(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
    }

    /// Saves to the Drafts folder every 10 s while there are unsaved changes.
    func autosave() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let fingerprint = "\(draft.to)|\(draft.cc)|\(draft.bcc)|\(draft.subject)|\(draft.body)|\(draft.attachments.count)"
            guard !draft.isEmpty, fingerprint != lastSaved, !sending else { continue }
            let saved = await model.saveDraft(draft)
            draft.draftUID = saved.draftUID
            lastSaved = fingerprint
        }
    }
}

/// Recipient field with suggestions from known contacts for the address being typed.
struct AddressField: View {
    @Environment(AppModel.self) private var model
    let label: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field

    var currentToken: String {
        text.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused(focus, equals: field)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            let suggestions = focus.wrappedValue == field ? model.contacts.suggestions(for: currentToken) : []
            if !currentToken.isEmpty && !suggestions.isEmpty && !suggestions.contains(where: { $0.address.caseInsensitiveCompare(currentToken) == .orderedSame }) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { s in
                        Button { pick(s) } label: {
                            HStack {
                                Text(s.name.isEmpty ? s.address : s.name)
                                if !s.name.isEmpty { Text(s.address).foregroundStyle(.secondary) }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 80)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.bottom, 4)
            }
            Divider()
        }
    }

    func pick(_ a: EmailAddress) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(a.headerValue)
        text = parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }
}
