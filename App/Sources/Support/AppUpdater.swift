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

    private let controller: SPUStandardUpdaterController?

    private init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        if key.isEmpty || feed.isEmpty {
            controller = nil
        } else {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Download and install updates without asking (installed when the app quits or relaunches).
    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
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
