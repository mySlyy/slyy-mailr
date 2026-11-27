import Foundation
#if os(macOS) && canImport(Sparkle)
import Sparkle

/// Automatic updates (Sparkle 2): checks the appcast on the Slyy Mailr releases page every few hours,
/// downloads in the background and installs on quit. Every update must carry our EdDSA signature
/// (SUPublicEDKey) and Apple's notarization. Builds without a public key have the updater switched off.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    private let updater: SPUUpdater?
    /// Our window instead of Sparkle's standard one (which shows the GitHub release page in a web view).
    private let driver = SlyyUpdateDriver()

    private init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !key.isEmpty, !feed.isEmpty else { updater = nil; return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try u.start()
            updater = u
        } catch {
            updater = nil
        }
    }

    var isAvailable: Bool { updater != nil }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Download and install updates without asking (installed when the app quits or relaunches).
    var installsAutomatically: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }
}
#else

/// iOS/iPadOS update through TestFlight/App Store; nothing to do in the app.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()
    var isAvailable: Bool { false }
    func checkForUpdates() {}
    var installsAutomatically = false
    var checksAutomatically = false
    var lastCheck: Date? { nil }
}
#endif
