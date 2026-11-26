import SwiftUI
import SlyyMailKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil {
                AccountSetupView()
            } else {
                MainView()
            }
        }
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

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            Group {
                if model.sidebarSelection == .calendar {
                    CalendarView()
                } else {
                    MessageListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: model.sidebarSelection == .calendar ? 640 : 360)
        } detail: {
            if model.sidebarSelection == .calendar {
                if let e = model.selectedEvent {
                    EventDetailView(event: e)
                } else {
                    ContentUnavailableView("No event selected", systemImage: "calendar", description: Text("Select an event or create a new one."))
                }
            } else {
                MessageDetailView()
            }
        }
    }
}

struct VideoCallView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            JitsiWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.deletingFragment.lastPathComponent)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .destructive) { dismiss() } label: {
                            Label("Leave", systemImage: "phone.down.fill")
                        }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { model.copyToClipboard(url.deletingFragment.absoluteString) } label: {
                            Label("Copy link", systemImage: "link")
                        }
                        Button { openExternally(url) } label: {
                            Label("Open in browser", systemImage: "safari")
                        }
                    }
                }
        }
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
