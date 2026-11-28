import SwiftUI
import SlyyMailKit
#if os(macOS)
import AppKit
#endif

/// Desktop message list (middle column).
struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.currentFolderInfo?.name ?? String(localized: "Mail"))
                        .font(Slyy.font(20, .semibold))
                    Spacer()
                    Button { Task { await model.refresh() } } label: {
                        HStack(spacing: 5) {
                            if model.isRefreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.down.circle").imageScale(.small) }
                            Text("Fetch mail")
                        }
                        .font(Slyy.font(12))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .hairlineBorder(Slyy.lineStrong)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRefreshing)
                    .help("Fetch mail now (⇧⌘N)")
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(statusLine).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                    }
                }
                TextField("Search subject, sender, text", text: $model.searchText)
                    .textFieldStyle(SlyyFieldStyle(padding: 8))
                    .focused($searchFocused)
                    .onChange(of: searchFocused) { _, f in model.typingInField = f }
                    .onSubmit { Task { await model.search() } }
                    .onChange(of: model.searchText) { _, _ in model.searchTextChanged() }
                if model.havenState == .connected && !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Enter searches as before; ⌘↩ asks Haven across the mailbox.
                    Button { model.havenQuestion = model.searchText.trimmingCharacters(in: .whitespaces) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Slyy.accent).frame(width: 8, height: 8)
                            Text("Ask Haven this question across your mail").font(Slyy.font(13)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("⌘↩").font(Slyy.mono(10)).foregroundStyle(Slyy.ink2)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Slyy.tint)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .headerBar(iOSTop: 14, bottom: 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.showsThreads {
                        ForEach(model.threads) { t in
                            ThreadRow(thread: t, me: model.account?.email, mine: model.account?.myAddresses ?? [], showRecipients: isSentLike,
                                      selected: t.messages.contains { model.selectedMessageIDs.contains($0.id) },
                                      expanded: model.expandedThreads.contains(t.id), onToggle: { model.toggleThread(t.id) })
                                .contentShape(Rectangle())
                                .onTapGesture { select(t.latest) }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { openThread(t.latest) })
                                .draggable(model.actionable(t.messages).last?.id ?? t.latest.id)
                                .contextMenu { MessageMenu(list: targets(t)) }
                            if t.count > 1 && model.expandedThreads.contains(t.id) {
                                ForEach(t.messages.reversed()) { m in
                                    ThreadChildRow(message: m, mine: model.isMine(m.from.first?.address ?? ""), selected: model.selectedMessageIDs.contains(m.id))
                                        .contentShape(Rectangle())
                                        .onTapGesture { select(m) }
                                        .simultaneousGesture(TapGesture(count: 2).onEnded { openThread(m) })
                                        .draggable(m.id)
                                        .contextMenu { MessageMenu(list: [m]) }
                                }
                            }
                        }
                    } else {
                        ForEach(model.messages) { m in
                            if m.id == model.firstMentionID { MentionsDivider() }
                            MessageRow(message: m, showRecipients: isSentLike, selected: model.selectedMessageIDs.contains(m.id))
                                .contentShape(Rectangle())
                                .onTapGesture { select(m) }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { openThread(m) })
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
                    Text(model.isSearchActive ? String(localized: "No results") : String(localized: "No messages"))
                        .foregroundStyle(Slyy.muted)
                }
            }
            .refreshable { await model.refresh() }
        }
        .background(Color.white)
        #if os(macOS)
        .onDeleteCommand { Task { await model.delete(model.selectedMessages, undo: undoManager) } }
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

    /// Double-click: the conversation in its own window (Mac).
    func openThread(_ m: MessageSummary) {
        #if os(macOS)
        openWindow(value: m)
        #endif
    }

    func select(_ m: MessageSummary) {
        model.havenQuestion = nil // picking a mail closes Haven's answer pane
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) {
            if model.selectedMessageIDs.contains(m.id) { model.selectedMessageIDs.remove(m.id) } else { model.selectedMessageIDs.insert(m.id) }
            return
        }
        // Shift-click: everything between the last selected message and this one.
        if NSEvent.modifierFlags.contains(.shift), let anchor = model.messages.firstIndex(where: { model.selectedMessageIDs.contains($0.id) }),
           let target = model.messages.firstIndex(where: { $0.id == m.id }) {
            let lastAnchor = model.messages.lastIndex(where: { model.selectedMessageIDs.contains($0.id) }) ?? anchor
            let range = target < anchor ? target...lastAnchor : anchor...target
            model.selectedMessageIDs = Set(model.messages[range].map(\.id))
            return
        }
        #endif
        model.selectedMessageIDs = [m.id]
        Task { await model.open(m) }
    }

    /// A thread's menu acts on every selected conversation when this one is part of the selection.
    func targets(_ t: MessageThread) -> [MessageSummary] {
        let sel = model.selectedMessageIDs
        guard t.messages.contains(where: { sel.contains($0.id) }) else { return model.actionable(t.messages) }
        return model.actionable(model.threads.filter { $0.messages.contains { sel.contains($0.id) } }.flatMap(\.messages))
    }

    func targets(_ m: MessageSummary) -> [MessageSummary] {
        model.selectedMessageIDs.contains(m.id) ? model.selectedMessages : [m]
    }
}

/// In search results: the messages below only mention the words in their text.
struct MentionsDivider: View {
    var body: some View {
        Text("Mentioned in the text")
            .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            .bottomHairline()
    }
}

/// Right-click / long-press actions on one or more messages.
struct MessageMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let list: [MessageSummary]

    var body: some View {
        Button(list.allSatisfy(\.isSeen) ? "Mark as Unread" : "Mark as Read") { Task { await model.toggleFlag("\\Seen", for: list) } }
        Button(list.allSatisfy(\.isFlagged) ? "Unflag" : "Flag") { Task { await model.toggleFlag("\\Flagged", for: list) } }
        Divider()
        Button("Archive") { Task { await model.archive(list) } }
        Button("Snooze…") { model.requestSnooze(list) }
        Menu("Move to") {
            ForEach(model.folders.filter { $0.isSelectable && $0.serverPath != model.currentFolder }) { f in
                Button(f.path) { Task { await model.move(list, to: f) } }
            }
        }
        if list.count == 1, let first = list.first?.from.first {
            Button("Video call with \(first.display)") { model.call([first]) }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.delete(list, undo: undoManager) } }
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
    @Environment(\.undoManager) private var undoManager
    /// Select mode: ids of threads (threaded view) or messages.
    @State private var selection: Set<String> = []
    @State private var selecting = false

    var selectedList: [MessageSummary] {
        if model.showsThreads {
            return model.actionable(model.threads.filter { selection.contains($0.id) }.flatMap(\.messages))
        }
        return model.messages.filter { selection.contains($0.id) }
    }

    /// Select mode actions at the bottom (iOS Mail style).
    var bulkBar: some View {
        let list = selectedList
        return HStack(spacing: 0) {
            bulkButton(list.allSatisfy(\.isSeen) && !list.isEmpty ? "Unread" : "Read", icon: "envelope.badge") { await model.toggleFlag("\\Seen", for: list) }
            bulkButton(list.allSatisfy(\.isFlagged) && !list.isEmpty ? "Unflag" : "Flag", icon: "flag") { await model.toggleFlag("\\Flagged", for: list) }
            Menu {
                ForEach(model.folders.filter { $0.isSelectable && $0.serverPath != model.currentFolder }) { f in
                    Button(f.path) { Task { await model.move(list, to: f); endSelecting() } }
                }
            } label: {
                VStack(spacing: 3) { Image(systemName: "folder"); Text("Move").font(Slyy.font(11)) }.frame(maxWidth: .infinity, minHeight: 50)
            }
            .disabled(list.isEmpty)
            bulkButton("Archive", icon: "archivebox") { await model.archive(list); endSelecting() }
            bulkButton("Delete", icon: "trash", role: .destructive) { await model.delete(list, undo: undoManager); endSelecting() }
        }
        .foregroundStyle(Slyy.ink)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
    }

    func bulkButton(_ title: LocalizedStringKey, icon: String, role: ButtonRole? = nil, action: @escaping () async -> Void) -> some View {
        Button(role: role) { Task { await action() } } label: {
            VStack(spacing: 3) { Image(systemName: icon); Text(title).font(Slyy.font(11)) }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(role == .destructive ? Slyy.danger : Slyy.ink)
        }
        .buttonStyle(.plain)
        .disabled(selection.isEmpty)
    }

    func endSelecting() {
        selection = []
        selecting = false
    }

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
                if selecting {
                    Text("\(selection.count) selected").font(Slyy.font(14)).foregroundStyle(Slyy.muted)
                    Button("Done") { endSelecting() }
                        .buttonStyle(SlyyOutlineButtonStyle(strong: true))
                } else {
                    Button("Select") { selecting = true }
                        .buttonStyle(.plain)
                        .font(Slyy.font(15))
                        .frame(minHeight: 44)
                        .disabled(model.messages.isEmpty)
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
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 8)

            TextField("Search", text: $model.searchText)
                .textFieldStyle(SlyyFieldStyle())
                .font(Slyy.bodyPhone)
                .onSubmit { Task { await model.search() } }
                .onChange(of: model.searchText) { _, _ in model.searchTextChanged() }
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
                            .buttonStyle(.slyyAccent(height: 32))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Slyy.tint)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }

            List(selection: $selection) {
                if model.showsThreads {
                    ForEach(model.threads) { t in
                        NavigationLink(value: t.latest) {
                            ThreadRow(thread: t, me: model.account?.email, mine: model.account?.myAddresses ?? [], phone: true)
                        }
                        .modifier(PhoneRow(list: model.actionable(t.messages)))
                        .tag(t.id)
                    }
                } else {
                    ForEach(model.messages) { m in
                        if m.id == model.firstMentionID { MentionsDivider().listRowSeparator(.hidden) }
                        NavigationLink(value: m) {
                            MessageRow(message: m, showRecipients: false, phone: true)
                        }
                        .modifier(PhoneRow(list: [m]))
                        .tag(m.id)
                    }
                }
                if model.canLoadMore && !selecting {
                    Button("Load more") { Task { await model.loadMore() } }
                        .buttonStyle(.slyyOutline)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await model.loadMore() } }
                }
            }
            .listStyle(.plain)
            #if os(iOS)
            .environment(\.editMode, Binding(get: { selecting ? .active : .inactive }, set: { selecting = $0.isEditing }))
            #endif
            .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
            .overlay {
                if model.messages.isEmpty && !model.isRefreshing {
                    Text(model.isSearchActive ? String(localized: "No results") : String(localized: "No messages"))
                        .foregroundStyle(Slyy.muted)
                }
            }
            .refreshable { await model.refresh() }
            if selecting { bulkBar }
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
    var mine: Set<String> = []
    var showRecipients = false
    var selected = false
    var phone = false
    var expanded = false
    var onToggle: (() -> Void)? = nil

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
                        if let onToggle {
                            Button(action: onToggle) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Slyy.ink2)
                                    .frame(width: 16, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(expanded ? "Fold conversation" : "Unfold conversation")
                        }
                        Text(thread.participants(mine: mine).map { $0 == "Me" ? String(localized: "Me") : $0 }.joined(separator: ", "))
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

/// One message under an unfolded conversation in the list.
struct ThreadChildRow: View {
    let message: MessageSummary
    var mine = false
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(message.isSeen ? Color.clear : Slyy.accent).frame(width: 6, height: 6)
            Text(mine ? String(localized: "Me") : (message.from.first?.display ?? "?"))
                .font(Slyy.font(13, message.isSeen ? .regular : .semibold))
                .lineLimit(1)
            if message.hasAttachments { Image(systemName: "paperclip").imageScale(.small).foregroundStyle(Slyy.muted) }
            Spacer(minLength: 6)
            Text(MessageRow.shortDate(message.date)).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
        }
        .padding(.leading, 44)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(selected ? Slyy.tint : Slyy.sidebar)
        .bottomHairline()
        .accessibilityElement(children: .combine)
    }
}

/// One row of the iPhone list: flush layout, swipe actions, long-press menu.
struct PhoneRow: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let list: [MessageSummary]

    func body(content: Content) -> some View {
        let seen = list.allSatisfy(\.isSeen)
        let flagged = list.allSatisfy(\.isFlagged)
        content
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.white)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { Task { await model.toggleFlag("\\Seen", for: list) } } label: {
                    Label(seen ? "Unread" : "Read", systemImage: seen ? "envelope.badge" : "envelope.open")
                }
                .tint(Slyy.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { Task { await model.delete(list, undo: undoManager) } } label: { Label("Delete", systemImage: "trash") }
                Button { Task { await model.archive(list) } } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(Slyy.ink2)
                Button { Task { await model.toggleFlag("\\Flagged", for: list) } } label: {
                    Label(flagged ? "Unflag" : "Flag", systemImage: flagged ? "flag.slash" : "flag")
                }
                .tint(.orange)
            }
            .contextMenu { MessageMenu(list: list) }
    }
}
