import SwiftUI
import SlyyMailKit

/// A conversation in its own window (double-click a message in the list): every message open, oldest first,
/// each with Reply / Reply all / Forward. ⌘R, ⌘A, ⌘F answer the newest message; ⌘+ / ⌘− change the text size.
struct ThreadWindow: View {
    @Environment(AppModel.self) private var model
    let summary: MessageSummary
    @State private var messages: [MessageSummary] = []
    @State private var bodies: [String: ParsedMessage] = [:]
    @State private var loading = true
    /// The reply is written in a sheet on this window, not on the main window behind it.
    @State private var draft: ComposeDraft?

    func compose(_ kind: ComposeKind) {
        model.compose(kind)
        draft = model.composeDraft
        model.composeDraft = nil
    }

    var latest: ParsedMessage? { messages.last.flatMap { bodies[$0.id] } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Reply") { if let m = latest { compose(.reply(m)) } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reply all") { if let m = latest { compose(.replyAll(m)) } }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Forward") { if let m = latest { compose(.forward(m)) } }
                    .keyboardShortcut("f", modifiers: .command)
                Spacer()
                Text("\(messages.count) messages").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
            .buttonStyle(.slyyOutline)
            .disabled(latest == nil)
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 10)
            .bottomHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(MessageThreads.baseSubject(summary.subject).isEmpty ? String(localized: "(no subject)") : MessageThreads.baseSubject(summary.subject))
                        .font(Slyy.font(22, .semibold))
                        .textSelection(.enabled)
                    if loading {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(messages) { m in
                        ThreadMessage(summary: m, parsed: bodies[m.id], onCompose: compose)
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.white)
        .foregroundStyle(Slyy.ink)
        .font(Slyy.body)
        .navigationTitle(summary.subject)
        .sheet(item: $draft, onDismiss: { model.openNextRecovered() }) { d in
            ComposeView(draft: d).environment(model)
        }
        .task(id: summary.id) {
            loading = true
            let r = await model.conversationForWindow(summary)
            messages = r.messages
            bodies = r.bodies
            loading = false
        }
    }
}

/// One message in the thread window: header, invite, attachments, the mail at its own height.
struct ThreadMessage: View {
    @Environment(AppModel.self) private var model
    let summary: MessageSummary
    let parsed: ParsedMessage?
    var onCompose: (ComposeKind) -> Void = { _ in }
    @State private var height: CGFloat = 80
    @State private var allowImages = false

    var mine: Bool { model.isMine(summary.from.first?.address ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mine ? String(localized: "Me") : (summary.from.first?.display ?? "")).font(Slyy.font(15, .semibold))
                if summary.folder != model.currentFolder, mine {
                    MonoTag(text: "SENT", background: Slyy.ink2)
                }
                Text(summary.to.map(\.display).joined(separator: ", ")).font(Slyy.font(13)).foregroundStyle(Slyy.muted).lineLimit(1)
                Spacer()
                Text(summary.date.formatted(date: .abbreviated, time: .shortened)).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
            if let p = parsed {
                if let inv = MessageBody.invite(in: p) {
                    InviteCard(invite: inv.event, method: inv.method, phone: false)
                }
                let files = p.attachments.filter { !$0.isInline || $0.contentID == nil }
                if !files.isEmpty { AttachmentChips(attachments: files) }
                if MessageBody.hasRemoteContent(p) && !allowImages {
                    Button("Load images") { allowImages = true }
                        .buttonStyle(SlyyOutlineButtonStyle(height: 28))
                }
                MailHTMLView(html: MessageBody.html(p), allowRemoteContent: allowImages, zoom: model.bodyZoom, onHeight: { h in
                    height = min(max(h, 40), 20000)
                }, onMailto: { url in onCompose(.mailto(url)) })
                .frame(height: height)
                HStack(spacing: 6) {
                    Button("Reply") { onCompose(.reply(p)) }
                    Button("Reply all") { onCompose(.replyAll(p)) }
                    Button("Forward") { onCompose(.forward(p)) }
                }
                .buttonStyle(SlyyOutlineButtonStyle(height: 30))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .hairlineBorder()
    }
}
