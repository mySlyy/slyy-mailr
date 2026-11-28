import SwiftUI
import SlyyMailKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: IMAPFolder?
    /// The folder under the pointer while mail is dragged (highlighted, so the drop is precise).
    @State private var dropTarget: String?
    @State private var renameText = ""
    @State private var showSettings = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var specialFolders: [IMAPFolder] {
        model.folders.filter { $0.isSelectable && $0.specialUse != nil && $0.specialUse != .all && $0.specialUse != .flagged }
    }

    var customFolders: [IMAPFolder] {
        model.folders.filter { $0.isSelectable && $0.specialUse == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SlyyLogo()
                .padding(.horizontal, 6)
                #if os(macOS)
                .padding(.top, 22) // room for the window buttons (hidden title bar)
                #endif
            if model.sidebarSelection == .calendar {
                Button { model.newEvent(at: nil) } label: {
                    Label("New event", systemImage: "plus")
                }
                .buttonStyle(.slyyPrimary(fullWidth: true))
            } else {
                Button { model.compose(.new) } label: {
                    Label("New message", systemImage: SlyyIcon.compose)
                }
                .buttonStyle(.slyyPrimary(fullWidth: true))
            }
            Button { model.meetNow() } label: {
                Label("Meet now", systemImage: SlyyIcon.video)
            }
            .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, height: 40))
            .help("Start a video call now; the link is copied to the clipboard")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Mail") {
                        ForEach(specialFolders) { folderRow($0) }
                    }
                    if !customFolders.isEmpty {
                        section("Folders") {
                            ForEach(customFolders) { folderRow($0) }
                        }
                    }
                    section("Calendar") {
                        Button { model.select(.calendar) } label: {
                            HStack {
                                Text("Calendar")
                                Spacer()
                                if let next = nextEvent {
                                    Text("Next \(next.start.formatted(date: .omitted, time: .shortened))")
                                        .font(Slyy.font(12))
                                        .foregroundStyle(Slyy.muted)
                                }
                            }
                        }
                        .buttonStyle(SlyyRowButtonStyle(selected: model.sidebarSelection == .calendar))
                        if model.sidebarSelection == .calendar {
                            ForEach(model.calendars) { c in
                                CalendarToggle(calendar: c) {
                                    HStack(spacing: 8) {
                                        Rectangle().fill(Color(hex: c.color) ?? Slyy.accent).frame(width: 10, height: 10)
                                        Text(c.name).lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            accountFooter
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Slyy.sidebar)
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { let n = newFolderName; newFolderName = ""; Task { await model.createFolder(n) } }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let f = renaming { let n = renameText; Task { await model.renameFolder(f, to: n) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environment(model)
        }
        #endif
    }

    var nextEvent: CalendarEvent? {
        model.visibleEvents.first { $0.start > Date() && !$0.isAllDay }
    }

    @ViewBuilder
    func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(title).padding(.horizontal, 8).padding(.vertical, 4)
            content()
        }
    }

    func folderRow(_ f: IMAPFolder) -> some View {
        let selected = model.sidebarSelection == .folder(f.serverPath)
        let count = f.specialUse == .drafts ? f.total : (f.specialUse == .sent || f.specialUse == .trash || f.specialUse == .archive ? 0 : f.unseen)
        return Button { model.select(.folder(f.serverPath)) } label: {
            HStack {
                Text(f.name)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(f.specialUse == nil ? f.depth * 12 : 0))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(Slyy.mono(11))
                        .foregroundStyle(f.specialUse == .inbox ? Slyy.accent : Slyy.muted)
                }
            }
        }
        .buttonStyle(SlyyRowButtonStyle(selected: selected))
        .overlay {
            if dropTarget == f.serverPath {
                Rectangle().fill(Slyy.accent.opacity(0.12)).overlay(Rectangle().stroke(Slyy.accent, lineWidth: 1.5)).allowsHitTesting(false)
            }
        }
        .contextMenu {
            if f.specialUse == nil {
                Button("Rename…") { renaming = f; renameText = f.name }
                Button("Delete Folder", role: .destructive) { Task { await model.deleteFolder(f) } }
            }
            Button("New Folder…") { showNewFolder = true }
        }
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            let ids = MailDrag.ids(items)
            let list = model.messages.filter { ids.contains($0.id) && $0.folder != f.serverPath }
            guard !list.isEmpty else { return false }
            Task { await model.move(list, to: f) }
            return true
        } isTargeted: { over in
            if over { dropTarget = f.serverPath } else if dropTarget == f.serverPath { dropTarget = nil }
        }
    }

    var accountFooter: some View {
        Button {
            // Mac: the Settings window (same as ⌘,), resizable; iPad: a sheet.
            #if os(macOS)
            openSettings()
            #else
            showSettings = true
            #endif
        } label: {
            HStack(spacing: 10) {
                InitialsAvatar(name: model.account?.displayName.isEmpty == false ? model.account!.displayName : (model.account?.email ?? ""))
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.account?.displayName.isEmpty == false ? model.account!.displayName : (model.account?.email ?? ""))
                        .font(Slyy.font(13, .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.isRefreshing ? Slyy.orange : Color(rgb: 0x1F9D55)).frame(width: 6, height: 6)
                        Text(model.account?.email ?? "")
                            .font(Slyy.font(12))
                            .foregroundStyle(Slyy.muted)
                            .lineLimit(1)
                    }
                    .help(model.isRefreshing ? String(localized: "Syncing") : String(localized: "Synced"))
                }
                Spacer(minLength: 0)
                Image(systemName: "gearshape").foregroundStyle(Slyy.muted)
            }
            .padding(.top, 10)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
        .help("Account settings")
    }
}

extension Color {
    /// "#RRGGBB" or "#RRGGBBAA" (as CalDAV servers store calendar colours).
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
