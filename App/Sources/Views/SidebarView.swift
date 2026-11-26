import SwiftUI
import SlyyMailKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: IMAPFolder?
    @State private var renameText = ""
    @State private var showSettings = false

    var body: some View {
        List(selection: Binding(get: { model.sidebarSelection }, set: { model.select($0) })) {
            Section("Mail") {
                ForEach(model.folders.filter(\.isSelectable)) { f in
                    Label(f.name, systemImage: icon(for: f))
                        .padding(.leading, CGFloat(f.specialUse == nil ? f.depth * 12 : 0))
                        .badge(f.specialUse == .drafts || f.specialUse == .sent ? 0 : f.unseen)
                        .tag(SidebarItem.folder(f.serverPath))
                        .contextMenu {
                            if f.specialUse == nil {
                                Button("Rename…") { renaming = f; renameText = f.name }
                                Button("Delete Folder", role: .destructive) { Task { await model.deleteFolder(f) } }
                            }
                            Button("New Folder…") { showNewFolder = true }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            let list = model.messages.filter { ids.contains($0.id) }
                            guard !list.isEmpty else { return false }
                            Task { await model.move(list, to: f) }
                            return true
                        }
                }
            }
            Section("Calendar") {
                Label("Calendar", systemImage: "calendar")
                    .tag(SidebarItem.calendar)
                if model.sidebarSelection == .calendar {
                    ForEach(model.calendars) { c in
                        Toggle(isOn: Binding(
                            get: { !model.hiddenCalendars.contains(c.url) },
                            set: { on in if on { model.hiddenCalendars.remove(c.url) } else { model.hiddenCalendars.insert(c.url) } }
                        )) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: c.color) ?? .accentColor).frame(width: 9, height: 9)
                                Text(c.name).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .navigationTitle(model.account?.displayName.isEmpty == false ? model.account!.displayName : "Slyy Mail")
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItemGroup {
                Button { model.compose(.new) } label: { Label("New Message", systemImage: "square.and.pencil") }
                Button { model.meetNow() } label: { Label("Meet Now", systemImage: "video") }
                    .help("Start a video call now; the link is copied to the clipboard")
                #if os(iOS)
                Button { showSettings = true } label: { Label("Settings", systemImage: "gear") }
                #endif
            }
        }
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

    func icon(for f: IMAPFolder) -> String {
        switch f.specialUse {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive: return "archivebox"
        case .flagged: return "flag"
        case .all: return "tray.full"
        case nil: return "folder"
        }
    }
}

#if os(iOS)
extension ToggleStyle where Self == SwitchToggleStyle {
    /// iOS has no checkbox style; use a switch.
    static var checkbox: SwitchToggleStyle { .switch }
}
#endif

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
