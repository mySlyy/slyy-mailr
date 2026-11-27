import Foundation
#if os(macOS)
import AppKit

/// Removes what earlier versions and their installers leave behind, once per installed version:
/// - Slyy Mailr installer DMGs (and .sha256 files) in Downloads that are older than the running version,
/// - mounted "Slyy Mailr …" / "Slyy Mail …" installer volumes (unless the app runs from one),
/// - the pre-rename app "Slyy Mail.app" (bundle id ai.slyy.mail) in /Applications or ~/Applications.
/// Everything goes to the Trash, never deleted outright, and only items that are provably ours.
struct InstallerCleanup {
    struct Report: Equatable {
        var trashed: [String] = []
        var ejected: [String] = []
        var failed: [String] = []

        var summary: String {
            var parts: [String] = []
            if !trashed.isEmpty { parts.append(String(localized: "\(trashed.count) old file(s) moved to the Trash")) }
            if !ejected.isEmpty { parts.append(String(localized: "\(ejected.count) installer disk(s) ejected")) }
            if !failed.isEmpty { parts.append(String(localized: "could not remove: \(failed.joined(separator: ", "))")) }
            return parts.isEmpty ? String(localized: "Nothing to clean up") : parts.joined(separator: " · ")
        }
    }

    var currentVersion: String
    var appBundle: URL
    var downloads: URL?
    var applicationsFolders: [URL]
    var volumes: URL = URL(fileURLWithPath: "/Volumes")
    /// Replaced in tests.
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var eject: (URL) throws -> Void = { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) }

    static func live() -> InstallerCleanup {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return InstallerCleanup(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            appBundle: Bundle.main.bundleURL,
            downloads: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            applicationsFolders: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        )
    }

    // MARK: Rules

    /// "slyy-mailr-0.2.1-mac-universal.dmg" → "0.2.1"; nil for names without a version.
    static func version(inInstallerName name: String) -> String? {
        let lower = name.lowercased()
        for prefix in ["slyy-mailr-", "slyy-mail-"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count)
            let v = rest.prefix { $0.isNumber || $0 == "." }
            return v.isEmpty ? nil : String(v)
        }
        return nil
    }

    static func isOurInstaller(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".dmg") || lower.hasSuffix(".dmg.sha256") else { return false }
        return lower.hasPrefix("slyy-mailr-") || lower.hasPrefix("slyy-mail-") || lower.hasPrefix("slyymailr")
    }

    /// Semantic-ish comparison: "0.10.0" > "0.9.2".
    static func isOlder(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    var runningFromVolume: URL? {
        let path = appBundle.standardizedFileURL.path
        guard path.hasPrefix(volumes.path + "/") else { return nil }
        let comps = path.dropFirst(volumes.path.count + 1).split(separator: "/")
        return comps.first.map { volumes.appendingPathComponent(String($0)) }
    }

    // MARK: Run

    func run() -> Report {
        var report = Report()
        let fm = FileManager.default
        let appDate = (try? appBundle.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        // 1. Installer files in Downloads.
        if let downloads, let items = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for url in items where Self.isOurInstaller(url.lastPathComponent) {
                let name = url.lastPathComponent
                let old: Bool
                if let v = Self.version(inInstallerName: name) {
                    old = Self.isOlder(v, than: currentVersion) || v == currentVersion
                } else {
                    // "SlyyMailr.dmg": no version in the name; old if it predates the installed app.
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    old = modified <= appDate
                }
                guard old else { continue }
                do { try trash(url); report.trashed.append(name) } catch { report.failed.append(name) }
            }
        }

        // 2. Mounted installer volumes.
        if let vols = try? fm.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for v in vols where v.lastPathComponent.hasPrefix("Slyy Mailr") || v.lastPathComponent.hasPrefix("Slyy Mail ") {
                guard v.standardizedFileURL != runningFromVolume?.standardizedFileURL else { continue }
                guard fm.fileExists(atPath: v.appendingPathComponent("Slyy Mailr.app").path) || fm.fileExists(atPath: v.appendingPathComponent("Slyy Mail.app").path) else { continue }
                do { try eject(v); report.ejected.append(v.lastPathComponent) } catch { report.failed.append(v.lastPathComponent) }
            }
        }

        // 3. The app from before the rename (only if its bundle id proves it is ours).
        for folder in applicationsFolders {
            let old = folder.appendingPathComponent("Slyy Mail.app")
            guard old.standardizedFileURL != appBundle.standardizedFileURL, fm.fileExists(atPath: old.path) else { continue }
            let id = Bundle(url: old)?.bundleIdentifier
            guard id == "ai.slyy.mail" else { continue }
            do { try trash(old); report.trashed.append(old.lastPathComponent) } catch { report.failed.append(old.path) }
        }
        return report
    }

    /// Runs once per installed version, in the background.
    @MainActor
    static func runOncePerVersion(store: UserDefaults = .standard, completion: @escaping @MainActor (Report) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard store.string(forKey: "cleanup.doneForBuild") != version else { return }
        let cleanup = InstallerCleanup.live()
        guard cleanup.runningFromVolume == nil else { return } // still running from the disk image: wait until installed
        Task.detached(priority: .utility) {
            let report = cleanup.run()
            await MainActor.run {
                store.set(version, forKey: "cleanup.doneForBuild")
                store.set(report.summary, forKey: "cleanup.lastSummary")
                store.set(Date(), forKey: "cleanup.lastRun")
                completion(report)
            }
        }
    }
}
#endif
