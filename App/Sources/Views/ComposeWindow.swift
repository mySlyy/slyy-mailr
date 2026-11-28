#if os(macOS)
import SwiftUI
import SlyyMailKit

/// A message being written in its own resizable window (the "compose" WindowGroup).
/// The draft comes from `AppModel.composeWindows`; a window restored after relaunch finds none and closes.
struct ComposeWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let id: UUID?
    /// Taken once when the window opens; the editor keeps its own copy from then on.
    @State private var draft: ComposeDraft?
    @State private var looked = false

    var body: some View {
        Group {
            if let draft {
                ComposeView(draft: draft)
            } else {
                Color.white
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.openComposeWindow = { id in openWindow(id: "compose", value: id) }
            if !looked {
                looked = true
                draft = id.flatMap { model.composeWindows[$0] }
            }
            if draft == nil { DispatchQueue.main.async { dismiss() } }
        }
        .onDisappear {
            if let id { model.composeWindows[id] = nil }
            model.openNextRecovered()
        }
    }
}
#endif
