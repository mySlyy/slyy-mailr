import SwiftUI
import SlyyMailKit

struct MessageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        list
        .overlay {
            if model.messages.isEmpty && !model.isRefreshing {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No messages", systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        .navigationTitle(model.currentFolderInfo?.name ?? "Mail")
        .searchable(text: $model.searchText, prompt: "Search subject, sender, text")
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.searchText) { _, q in
            if q.isEmpty { Task { await model.loadMessages(reset: true) } }
        }
        .refreshable { await model.refresh() }
        .onChange(of: model.selectedMessageIDs) { _, ids in
            if ids.count == 1, let id = ids.first, let m = model.messages.first(where: { $0.id == id }) {
                Task { await model.open(m) }
            }
        }
        #if os(macOS)
        .onDeleteCommand { Task { await model.delete(model.selectedMessages) } }
        #endif
        .toolbar {
            ToolbarItemGroup {
                if !model.selectedMessages.isEmpty {
                    Button { Task { await model.archive(model.selectedMessages) } } label: { Label("Archive", systemImage: "archivebox") }
                    Button { Task { await model.delete(model.selectedMessages) } } label: { Label("Delete", systemImage: "trash") }
                }
                if model.isRefreshing || model.isSearching { ProgressView().controlSize(.small) }
            }
        }
    }


    @ViewBuilder
    var list: some View {
        #if os(macOS)
        List(selection: selection) { rows }
        #else
        List(selection: singleSelection) { rows }
        #endif
    }

    var singleSelection: Binding<String?> {
        Binding(get: { model.selectedMessageIDs.first }, set: { model.selectedMessageIDs = $0.map { [$0] } ?? [] })
    }

    @ViewBuilder
    var rows: some View {
        ForEach(model.messages) { m in
                MessageRow(message: m, showRecipients: isSentLike)
                    .tag(m.id)
                    .draggable(m.id)
                    .swipeActions(edge: .leading) {
                        Button { Task { await model.toggleFlag("\\Seen", for: [m]) } } label: {
                            Label(m.isSeen ? "Unread" : "Read", systemImage: m.isSeen ? "envelope.badge" : "envelope.open")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await model.delete([m]) } } label: { Label("Delete", systemImage: "trash") }
                        Button { Task { await model.archive([m]) } } label: { Label("Archive", systemImage: "archivebox") }
                            .tint(.indigo)
                    }
                    .contextMenu { menu(for: targets(m)) }
            }
            if model.canLoadMore {
                Button("Load more") { Task { await model.loadMore() } }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderless)
                    .onAppear { Task { await model.loadMore() } }
            }
    }

    /// macOS: multi-selection. iOS: single selection drives navigation.
    var selection: Binding<Set<String>> {
        Binding(get: { model.selectedMessageIDs }, set: { model.selectedMessageIDs = $0 })
    }

    var isSentLike: Bool {
        let u = model.currentFolderInfo?.specialUse
        return u == .sent || u == .drafts
    }

    func targets(_ m: MessageSummary) -> [MessageSummary] {
        model.selectedMessageIDs.contains(m.id) ? model.selectedMessages : [m]
    }

    @ViewBuilder
    func menu(for list: [MessageSummary]) -> some View {
        Button(list.allSatisfy(\.isSeen) ? "Mark as Unread" : "Mark as Read") { Task { await model.toggleFlag("\\Seen", for: list) } }
        Button(list.allSatisfy(\.isFlagged) ? "Unflag" : "Flag") { Task { await model.toggleFlag("\\Flagged", for: list) } }
        Divider()
        Button("Archive") { Task { await model.archive(list) } }
        Menu("Move to") {
            ForEach(model.folders.filter { $0.isSelectable && $0.serverPath != model.currentFolder }) { f in
                Button(f.path) { Task { await model.move(list, to: f) } }
            }
        }
        if list.count == 1, let first = list.first?.from.first {
            Button("Video call with \(first.display)") { model.call([first]) }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.delete(list) } }
    }
}

struct MessageRow: View {
    let message: MessageSummary
    var showRecipients = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isSeen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(people)
                        .fontWeight(message.isSeen ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer()
                    if message.isFlagged { Image(systemName: "flag.fill").foregroundStyle(.orange).imageScale(.small) }
                    if message.hasAttachments { Image(systemName: "paperclip").foregroundStyle(.secondary).imageScale(.small) }
                    Text(Self.shortDate(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if message.isAnswered { Image(systemName: "arrowshape.turn.up.left.fill").imageScale(.small).foregroundStyle(.secondary) }
                    Text(message.subject.isEmpty ? String(localized: "(no subject)") : message.subject)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(message.isSeen ? .secondary : .primary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    var people: String {
        let list = showRecipients ? message.to : message.from
        let s = list.map(\.display).joined(separator: ", ")
        return s.isEmpty ? String(localized: "(unknown)") : s
    }

    static func shortDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
        return d.formatted(date: .numeric, time: .omitted)
    }
}
