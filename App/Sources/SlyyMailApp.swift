import SwiftUI
import SlyyMailKit
import UserNotifications

@main
struct SlyyMailApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Slyy.registerFonts()
        _model = State(initialValue: AppModel.shared)
        #if os(macOS)
        _ = AppUpdater.shared // starts background update checks
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                #if os(iOS)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { BackgroundRefresh.schedule() }
                }
                #endif
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.id)) { await BackgroundRefresh.run() }
        #endif
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        #endif
        .commands {
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                // ⌥⌘U: checks now and shows the answer (an update with its notes, or "up to date").
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .disabled(!AppUpdater.shared.isAvailable)
            }
            #endif
            CommandGroup(replacing: .newItem) {
                Button("New Message") { model.compose(.new) }
                    .keyboardShortcut("n")
                Button("New Event") { model.newEvent(at: nil) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Meet Now") { model.meetNow() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Fetch Mail") { Task { await model.refresh() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Bigger Text") { model.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Text Size") { model.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        #if os(macOS)
        // Double-click a message: the whole conversation in its own window.
        WindowGroup("Conversation", for: MessageSummary.self) { $summary in
            if let summary {
                ThreadWindow(summary: summary)
                    .environment(model)
                    .frame(minWidth: 560, minHeight: 480)
            }
        }
        .defaultSize(width: 900, height: 820)

        // Double-click a message's header (or "…" → Open in New Window): just that message.
        WindowGroup("Message", for: SingleMessage.self) { $message in
            if let message {
                ThreadWindow(summary: message.summary, single: true)
                    .environment(model)
                    .frame(minWidth: 560, minHeight: 480)
            }
        }
        .defaultSize(width: 860, height: 760)

        // A message being written: its own resizable window (iOS writes in a sheet).
        WindowGroup("New Message", id: "compose", for: UUID.self) { $id in
            ComposeWindow(id: id)
                .environment(model)
        }
        .defaultSize(width: 860, height: 700)

        WindowGroup("Video Call", for: URL.self) { $url in
            if let url {
                VideoCallView(url: url)
                    .environment(model)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
                .environment(model)
                // Opens at 880×680 (tabs, a 200 pt section pane, the form with even margins); can be made larger.
                .frame(minWidth: 760, idealWidth: 880, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        }
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// Notification actions ("Join" on meeting reminders) and app-level hooks.
final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    func setup() {
        UNUserNotificationCenter.current().delegate = self
        ReminderScheduler.registerCategories()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A snooze ended while Mailr is open: the message shows again in the list.
        if notification.request.content.userInfo["snooze"] != nil {
            await AppModel.shared.snoozeDue()
        }
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // New-mail or snooze reminder: open that message (loading the list releases a due snooze first).
        if let folder = info["folder"] as? String {
            let uid = (info["uid"] as? Int).map { UInt32($0) }
            await AppModel.shared.openFromNotification(folder: folder, uid: uid)
            return
        }
        guard let link = info["videoURL"] as? String, let url = URL(string: link) else { return }
        if response.actionIdentifier == ReminderScheduler.joinAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { AppModel.shared.join(url) }
        }
    }
}

#if os(macOS)
import AppKit
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setup()
        // Leftovers of earlier versions and installers, once per installed build.
        InstallerCleanup.runOncePerVersion { _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#else
import UIKit
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        setup()
        return true
    }
}
#endif
