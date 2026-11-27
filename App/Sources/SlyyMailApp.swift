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
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
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
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        #if os(macOS)
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
                .frame(width: 880, height: 680) // tabs, a 200 pt section pane and the form with even margins
        }
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
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // New-mail notification: open that message.
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
