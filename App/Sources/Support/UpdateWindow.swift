#if os(macOS) && canImport(Sparkle)
import SwiftUI
import AppKit
import Sparkle

/// What the update window shows. Sparkle still does the checking, EdDSA verification and installing;
/// only the window is ours (Slyy look, Markdown release notes from the appcast, no web view).
@MainActor
@Observable
final class UpdatePrompt {
    enum Phase: Equatable {
        case checking
        case found(version: String, notes: String, downloaded: Bool)
        case downloading(received: UInt64, expected: UInt64)
        case extracting(Double)
        case ready
        case installing
        case upToDate
        case failed(String)
    }

    var phase: Phase = .checking
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var choose: (SPUUserUpdateChoice) -> Void = { _ in }
    var cancel: () -> Void = {}
    var acknowledge: () -> Void = {}
}

/// Sparkle's user driver with a SwiftUI window in the Slyy style. Sparkle calls these on the main thread.
final class SlyyUpdateDriver: NSObject, SPUUserDriver, NSWindowDelegate {
    @MainActor let prompt = UpdatePrompt()
    @MainActor private var window: NSWindow?

    @MainActor private func present() {
        if window == nil {
            let host = NSHostingView(rootView: UpdateView(prompt: prompt))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @MainActor private func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    // Closing with the red button means "Later" (or Cancel while downloading).
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            switch prompt.phase {
            case .found: prompt.choose(.dismiss)
            case .downloading, .checking: prompt.cancel()
            case .ready: prompt.choose(.dismiss)
            default: prompt.acknowledge()
            }
            window = nil
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Automatic checks are on by default (Info.plist); never send a system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            prompt.phase = .checking
            prompt.cancel = cancellation
            present()
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            prompt.phase = .found(version: appcastItem.displayVersionString, notes: appcastItem.itemDescription ?? "",
                                  downloaded: state.stage != .notDownloaded)
            prompt.choose = { [weak self] choice in
                reply(choice)
                if choice != .install { MainActor.assumeIsolated { self?.close() } }
            }
            present()
        }
    }

    // Notes travel inside the appcast (Markdown); nothing is downloaded separately.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            prompt.phase = .upToDate
            prompt.acknowledge = { [weak self] in acknowledgement(); MainActor.assumeIsolated { self?.close() } }
            present()
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            prompt.phase = .failed(error.localizedDescription)
            prompt.acknowledge = { [weak self] in acknowledgement(); MainActor.assumeIsolated { self?.close() } }
            present()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            prompt.phase = .downloading(received: 0, expected: 0)
            prompt.cancel = { [weak self] in cancellation(); MainActor.assumeIsolated { self?.close() } }
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated { prompt.phase = .downloading(received: 0, expected: expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated {
            if case .downloading(let r, let e) = prompt.phase { prompt.phase = .downloading(received: r + length, expected: e) }
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        MainActor.assumeIsolated { prompt.phase = .extracting(0) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        MainActor.assumeIsolated { prompt.phase = .extracting(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            prompt.phase = .ready
            prompt.choose = { [weak self] choice in
                reply(choice)
                if choice != .install { MainActor.assumeIsolated { self?.close() } }
            }
            present()
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        MainActor.assumeIsolated { prompt.phase = .installing }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        MainActor.assumeIsolated { present() }
    }

    func dismissUpdateInstallation() {
        MainActor.assumeIsolated { close() }
    }
}

/// The window's content: header, Markdown notes, progress, Slyy buttons.
struct UpdateView: View {
    let prompt: UpdatePrompt
    @State private var automatic = AppUpdater.shared.installsAutomatically

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Slyy.font(17, .semibold))
                    Text(subtitle).font(Slyy.font(13)).foregroundStyle(Slyy.muted)
                }
                Spacer()
            }
            content
            buttons
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 520)
        .background(Color.white)
        .foregroundStyle(Slyy.ink)
        .preferredColorScheme(.light)
    }

    var title: String {
        switch prompt.phase {
        case .checking: return String(localized: "Checking for updates…")
        case .found(let v, _, _): return String(localized: "Slyy Mailr \(v) is available")
        case .downloading, .extracting: return String(localized: "Downloading the update…")
        case .ready: return String(localized: "The update is ready")
        case .installing: return String(localized: "Installing…")
        case .upToDate: return String(localized: "Slyy Mailr is up to date")
        case .failed: return String(localized: "The update did not work")
        }
    }

    var subtitle: String {
        switch prompt.phase {
        case .found: return String(localized: "You have \(prompt.current). Signed by Slyy and notarized by Apple.")
        case .ready: return String(localized: "Slyy Mailr restarts to finish. Open mails and drafts are kept.")
        case .upToDate: return String(localized: "You have the newest version, \(prompt.current).")
        case .failed(let m): return m
        default: return ""
        }
    }

    @ViewBuilder var content: some View {
        switch prompt.phase {
        case .found(_, let notes, _):
            ScrollView {
                MarkdownNotes(text: notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 230)
            .background(Slyy.panel)
            Toggle("Install updates automatically", isOn: $automatic)
                .toggleStyle(SlyyCheckboxStyle())
                .font(Slyy.font(13))
                .onChange(of: automatic) { _, on in AppUpdater.shared.installsAutomatically = on }
        case .downloading(let r, let e):
            progress(e > 0 ? Double(r) / Double(e) : nil,
                     e > 0 ? "\(ByteCountFormatter.string(fromByteCount: Int64(r), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(e), countStyle: .file))" : "")
        case .extracting(let p):
            progress(p, String(localized: "Checking the signature…"))
        case .checking, .installing:
            progress(nil, "")
        default:
            EmptyView()
        }
    }

    func progress(_ value: Double?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value { ProgressView(value: value).tint(Slyy.accent) } else { ProgressView().progressViewStyle(.linear).tint(Slyy.accent) }
            if !label.isEmpty { Text(label).font(Slyy.mono(11)).foregroundStyle(Slyy.muted) }
        }
    }

    @ViewBuilder var buttons: some View {
        HStack(spacing: 10) {
            switch prompt.phase {
            case .found(_, _, let downloaded):
                Button("Skip this version") { prompt.choose(.skip) }
                    .buttonStyle(.plain)
                    .font(Slyy.font(13))
                    .foregroundStyle(Slyy.muted)
                Spacer()
                Button("Later") { prompt.choose(.dismiss) }
                    .buttonStyle(.slyyOutline)
                    .keyboardShortcut(.cancelAction)
                Button(downloaded ? "Restart and update" : "Install update") { prompt.choose(.install) }
                    .buttonStyle(SlyyPrimaryButtonStyle(height: 36))
                    .keyboardShortcut(.defaultAction)
            case .ready:
                Spacer()
                Button("When I quit") { prompt.choose(.dismiss) }
                    .buttonStyle(.slyyOutline)
                    .keyboardShortcut(.cancelAction)
                Button("Restart now") { prompt.choose(.install) }
                    .buttonStyle(SlyyPrimaryButtonStyle(height: 36))
                    .keyboardShortcut(.defaultAction)
            case .checking, .downloading, .extracting:
                Spacer()
                Button("Cancel") { prompt.cancel() }
                    .buttonStyle(.slyyOutline)
                    .keyboardShortcut(.cancelAction)
            case .upToDate, .failed:
                Spacer()
                Button("OK") { prompt.acknowledge() }
                    .buttonStyle(SlyyPrimaryButtonStyle(height: 36))
                    .keyboardShortcut(.defaultAction)
            case .installing:
                EmptyView()
            }
        }
    }
}

/// RELEASE_NOTES.md as shown in the update window: paragraphs (hard-wrapped lines joined), "- " bullets,
/// "#" headings, and inline Markdown (**bold**, *italic*, `code`, links). The first line is the release title.
struct MarkdownNotes: View {
    let text: String

    enum Block: Hashable {
        case heading(String), paragraph(String), bullet(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if case .bullet(let b)? = out.last, para.isEmpty, raw.hasPrefix("  ") {
                out[out.count - 1] = .bullet(b + " " + line) // continuation of a wrapped bullet
            } else {
                para.append(line)
            }
        }
        flush()
        // The first paragraph is the release title ("Slyy Mailr 0.3.3 — …"): shown as a heading.
        if case .paragraph(let p)? = out.first, out.count > 1 { out[0] = .heading(p) }
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let h):
                    Text(Self.inline(h)).font(Slyy.font(14, .semibold))
                case .paragraph(let p):
                    Text(Self.inline(p)).font(Slyy.font(13)).fixedSize(horizontal: false, vertical: true)
                case .bullet(let b):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Slyy.accent).frame(width: 5, height: 5).offset(y: -2)
                        Text(Self.inline(b)).font(Slyy.font(13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .tint(Slyy.accent)
    }
}
#endif
