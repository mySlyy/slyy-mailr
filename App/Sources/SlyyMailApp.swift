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
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
        }
        .commands {
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
                .frame(width: 520)
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
