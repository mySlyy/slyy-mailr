import SwiftUI
import SlyyMailKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil {
                AccountSetupView()
            } else if sizeClass == .compact {
                PhoneShell()
            } else {
                DesktopShell()
            }
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .tint(Slyy.accent)
        .background(Color.white)
        .preferredColorScheme(.light)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.composeDraft) { draft in
            ComposeView(draft: draft)
                .environment(model)
        }
        .sheet(item: $model.editingEvent) { event in
            EventEditorView(event: event)
                .environment(model)
        }
        #if os(macOS)
        .onChange(of: model.videoCall) { _, url in
            if let url {
                openWindow(value: url)
                model.videoCall = nil
            }
        }
        #else
        .fullScreenCover(isPresented: Binding(get: { model.videoCall != nil }, set: { if !$0 { model.videoCall = nil } })) {
            if let url = model.videoCall {
                VideoCallView(url: url)
                    .environment(model)
            }
        }
        #endif
    }
}

/// Mac and iPad: sidebar | list | reader (mail) or sidebar | calendar | details (calendar).
struct DesktopShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 232)
                .trailingHairline()
            if model.sidebarSelection == .calendar {
                CalendarView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let e = model.selectedEvent {
                    EventDetailView(event: e)
                        .frame(width: 310)
                        .overlay(alignment: .leading) { Rectangle().fill(Slyy.line).frame(width: 1) }
                }
            } else {
                MessageListView()
                    .frame(minWidth: 300, idealWidth: 370, maxWidth: 400)
                    .trailingHairline()
                MessageDetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 640)
        #endif
    }
}

/// iPhone: Mail / Calendar / Settings tabs, as in the mobile wireframes.
struct PhoneShell: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                PhoneInboxView()
            }
            .tabItem { Label("Mail", systemImage: "envelope") }
            .badge(model.folders.first { $0.specialUse == .inbox }?.unseen ?? 0)
            .tag(0)

            NavigationStack {
                CalendarView()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(1)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(2)
        }
        .onChange(of: tab) { _, t in
            if t == 1 { model.select(.calendar) } else if t == 0, model.sidebarSelection == .calendar { model.select(.folder("INBOX")) }
        }
        .sheet(item: Binding(get: { model.selectedEvent }, set: { model.selectedEvent = $0 })) { e in
            NavigationStack {
                EventDetailView(event: e)
            }
            .environment(model)
            .presentationDetents([.medium, .large])
        }
    }
}

struct VideoCallView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Label("Leave", systemImage: "phone.down.fill")
                        .font(Slyy.font(14, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(Slyy.leave)
                }
                .buttonStyle(.plain)
                Text(url.deletingFragment.lastPathComponent)
                    .font(Slyy.font(14, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.copyToClipboard(url.deletingFragment.absoluteString)
                    copied = true
                } label: {
                    Label(copied ? "Link copied" : "Copy link", systemImage: "link")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .overlay(Rectangle().stroke(Slyy.ink2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { openExternally(url) } label: {
                    Text("Open in browser")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .overlay(Rectangle().stroke(Slyy.ink2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .font(Slyy.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Slyy.callBackground)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(rgb: 0x2A2A2A)).frame(height: 1) }

            JitsiWebView(url: url)
                .background(Slyy.callBackground)
        }
        .background(Slyy.callBackground)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(edges: .bottom)
    }
}

extension URL {
    /// The URL without "#..." (display names etc. stay private when sharing the link).
    var deletingFragment: URL {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        c.fragment = nil
        return c.url ?? self
    }
}
