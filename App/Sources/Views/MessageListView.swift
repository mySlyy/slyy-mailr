import SwiftUI
import SlyyMailKit
#if os(macOS)
import AppKit
#endif

/// Desktop message list (middle column).
struct MessageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.currentFolderInfo?.name ?? String(localized: "Mail"))
                        .font(Slyy.font(20, .semibold))
                    Spacer()
                    if model.isRefreshing || model.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(statusLine).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                    }
                }
                TextField("Search subject, sender, text", text: $model.searchText)
                    .textFieldStyle(SlyyFieldStyle(padding: 8))
                    .onSubmit { Task { await model.search() } }
                    .onChange(of: model.searchText) { _, q in
                        if q.isEmpty { Task { await model.loadMessages(reset: true) } }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, 10)
            .bottomHairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.threaded && model.searchText.isEmpty {
                        ForEach(model.threads) { t in
                            ThreadRow(thread: t, me: model.account?.email, showRecipients: isSentLike, selected: t.messages.contains { model.selectedMessageIDs.contains($0.id) })
                                .contentShape(Rectangle())
                                .onTapGesture { select(t.latest) }
                                .draggable(t.latest.id)
                                .contextMenu { MessageMenu(list: t.messages) }
                        }
                    } else {
                        ForEach(model.messages) { m in
                            MessageRow(message: m, showRecipients: isSentLike, selected: model.selectedMessageIDs.contains(m.id))
                                .contentShape(Rectangle())
                                .onTapGesture { select(m) }
                                .draggable(m.id)
                                .contextMenu { MessageMenu(list: targets(m)) }
                        }
                    }
                    if model.canLoadMore {
                        Button("Load more") { Task { await model.loadMore() } }
                            .buttonStyle(.slyyOutline)
                            .padding(12)
                            .onAppear { Task { await model.loadMore() } }
                    }
                }
            }
            .overlay {
                if model.messages.isEmpty && !model.isRefreshing {
                    Text(model.searchText.isEmpty ? String(localized: "No messages") : String(localized: "No results"))
                        .foregroundStyle(Slyy.muted)
                }
            }
            .refreshable { await model.refresh() }
        }
        .background(Color.white)
        #if os(macOS)
        .onDeleteCommand { Task { await model.delete(model.selectedMessages) } }
        #endif
    }

    var topInset: CGFloat {
        #if os(macOS)
        return 30
        #else
        return 14
        #endif
    }

    var statusLine: String {
        let unread = model.currentFolderInfo?.unseen ?? 0
        return unread > 0 ? String(localized: "\(unread) unread · push on") : String(localized: "push on")
    }

    var isSentLike: Bool {
        let u = model.currentFolderInfo?.specialUse
        return u == .sent || u == .drafts
    }

    func select(_ m: MessageSummary) {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) {
            if model.selectedMessageIDs.contains(m.id) { model.selectedMessageIDs.remove(m.id) } else { model.selectedMessageIDs.insert(m.id) }
            return
        }
        #endif
        model.selectedMessageIDs = [m.id]
        Task { await model.open(m) }
    }

    func targets(_ m: MessageSummary) -> [MessageSummary] {
        model.selectedMessageIDs.contains(m.id) ? model.selectedMessages : [m]
    }
}

/// Right-click / long-press actions on one or more messages.
struct MessageMenu: View {
    @Environment(AppModel.self) private var model
    let list: [MessageSummary]

    var body: some View {
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
    var selected = false
    var phone = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isSeen ? Color.clear : Slyy.accent)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(people)
                        .font(Slyy.font(phone ? 15 : 14, message.isSeen ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.shortDate(message.date))
                        .font(Slyy.font(12))
                        .foregroundStyle(selected ? Slyy.ink2 : Slyy.muted)
                }
                HStack(spacing: 6) {
                    if message.isInvite { MonoTag(text: "INVITE") }
                    Text(message.subject.isEmpty ? String(localized: "(no subject)") : message.subject)
                        .font(Slyy.font(phone ? 15 : 14, message.isSeen ? .regular : .semibold))
                        .foregroundStyle(message.isSeen ? Slyy.ink2 : Slyy.ink)
                        .lineLimit(1)
                }
                if let detail = detailLine {
                    HStack(spacing: 6) {
                        if message.hasAttachments { Image(systemName: "paperclip").imageScale(.small) }
                        Text(detail)
                    }
                    .font(Slyy.font(13))
                    .foregroundStyle(selected ? Slyy.ink2 : Slyy.muted)
                    .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, phone ? 18 : 16)
        .padding(.vertical, 12)
        .background(selected ? Slyy.tint : Color.white)
        .bottomHairline()
        .accessibilityElement(children: .combine)
    }

    var detailLine: String? {
        var parts: [String] = []
        if message.hasAttachments { parts.append(String(localized: "Attachment")) }
        if message.isAnswered { parts.append(String(localized: "Replied")) }
        if message.isFlagged { parts.append(String(localized: "Flagged")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        return d.formatted(.dateTime.day().month(.twoDigits))
    }
}

/// iPhone inbox (M1): header, search, next-event banner, list; tapping opens the message.
struct PhoneInboxView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [MessageSummary] = []

    var nextEvent: CalendarEvent? {
        let now = Date()
        return model.visibleEvents.first { !$0.isAllDay && $0.end > now && $0.start < now.addingTimeInterval(3 * 3600) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(model.folders.filter(\.isSelectable)) { f in
                        Button(f.name) { model.select(.folder(f.serverPath)) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Slyy.accent).frame(width: 14, height: 14)
                        Text(model.currentFolderInfo?.name ?? String(localized: "Inbox")).font(Slyy.font(20, .bold))
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Slyy.muted)
                    }
                    .foregroundStyle(Slyy.ink)
                }
                Spacer()
                Button { model.meetNow() } label: {
                    Image(systemName: SlyyIcon.video).frame(width: 44, height: 44).hairlineBorder()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Meet now")
                Button { model.compose(.new) } label: {
                    Image(systemName: SlyyIcon.compose).foregroundStyle(.white).frame(width: 44, height: 44).background(Slyy.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New message")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 8)

            TextField("Search", text: $model.searchText)
                .textFieldStyle(SlyyFieldStyle())
                .font(Slyy.bodyPhone)
                .onSubmit { Task { await model.search() } }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            if let e = nextEvent {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.start > Date() ? String(localized: "Next · in \(Int(e.start.timeIntervalSinceNow / 60) + 1) min") : String(localized: "Now"))
                            .font(Slyy.font(11, .medium))
                            .tracking(0.66)
                            .textCase(.uppercase)
                            .foregroundStyle(Slyy.ink2)
                        Text("\(e.summary), \(e.start.formatted(date: .omitted, time: .shortened))").font(Slyy.font(15, .semibold)).lineLimit(1)
                    }
                    Spacer()
                    if let v = e.videoURL {
                        Button("Join") { model.join(v) }
                            .buttonStyle(SlyyAccentButtonStyle(height: 32))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Slyy.tint)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.threaded && model.searchText.isEmpty {
                        ForEach(model.threads) { t in
                            NavigationLink(value: t.latest) {
                                ThreadRow(thread: t, me: model.account?.email, phone: true)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { MessageMenu(list: t.messages) }
                        }
                    } else {
                        ForEach(model.messages) { m in
                            NavigationLink(value: m) {
                                MessageRow(message: m, showRecipients: false, phone: true)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { MessageMenu(list: [m]) }
                        }
                    }
                    if model.canLoadMore {
                        Button("Load more") { Task { await model.loadMore() } }
                            .buttonStyle(.slyyOutline)
                            .padding(12)
                    }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
            .refreshable { await model.refresh() }
        }
        .background(Color.white)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(for: MessageSummary.self) { m in
            MessageDetailView()
                .task { model.selectedMessageIDs = [m.id]; await model.open(m) }
        }
    }
}

/// One conversation in the list: participants, base subject, message count, unread dot.
struct ThreadRow: View {
    let thread: MessageThread
    let me: String?
    var showRecipients = false
    var selected = false
    var phone = false

    var body: some View {
        if thread.count == 1 {
            MessageRow(message: thread.latest, showRecipients: showRecipients, selected: selected, phone: phone)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(thread.unreadCount > 0 ? Slyy.accent : Color.clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(thread.participants(me: me).map { $0 == "Me" ? String(localized: "Me") : $0 }.joined(separator: ", "))
                            .font(Slyy.font(phone ? 15 : 14, thread.unreadCount > 0 ? .semibold : .regular))
                            .lineLimit(1)
                        Text("\(thread.count)")
                            .font(Slyy.mono(10))
                            .foregroundStyle(Slyy.ink2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .hairlineBorder(Slyy.lineStrong)
                        Spacer(minLength: 6)
                        Text(MessageRow.shortDate(thread.date))
                            .font(Slyy.font(12))
                            .foregroundStyle(selected ? Slyy.ink2 : Slyy.muted)
                    }
                    HStack(spacing: 6) {
                        if thread.isInvite { MonoTag(text: "INVITE") }
                        Text(thread.subject.isEmpty ? String(localized: "(no subject)") : thread.subject)
                            .font(Slyy.font(phone ? 15 : 14, thread.unreadCount > 0 ? .semibold : .regular))
                            .foregroundStyle(thread.unreadCount > 0 ? Slyy.ink : Slyy.ink2)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if thread.hasAttachments { Image(systemName: "paperclip").imageScale(.small) }
                        if thread.isFlagged { Image(systemName: "flag.fill").imageScale(.small).foregroundStyle(Slyy.orange) }
                        Text(thread.unreadCount > 0 ? String(localized: "\(thread.unreadCount) unread · \(thread.count) messages") : String(localized: "\(thread.count) messages"))
                    }
                    .font(Slyy.font(13))
                    .foregroundStyle(selected ? Slyy.ink2 : Slyy.muted)
                }
            }
            .padding(.horizontal, phone ? 18 : 16)
            .padding(.vertical, 12)
            .background(selected ? Slyy.tint : Color.white)
            .bottomHairline()
            .accessibilityElement(children: .combine)
        }
    }
}
