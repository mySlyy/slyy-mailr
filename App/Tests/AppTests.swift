import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SlyyMailKit
@testable import SlyyMailr

@MainActor
final class AppLogicTests: XCTestCase {
    func testFontsAreBundledAndLoad() {
        Slyy.registerFonts()
        for name in ["HankenGrotesk-Regular", "HankenGrotesk-Medium", "HankenGrotesk-SemiBold", "HankenGrotesk-Bold", "MartianMono-Regular", "MartianMono-Medium"] {
            #if os(macOS)
            XCTAssertNotNil(NSFont(name: name, size: 14), "\(name) missing from the app bundle")
            #else
            XCTAssertNotNil(UIFont(name: name, size: 14), "\(name) missing from the app bundle")
            #endif
        }
    }

    func testComposeAddsVideoLinkAndKeepsBccOutOfHeaders() {
        var d = ComposeDraft()
        d.to = "\"Schott, Jürgen\" <j@schott.de>, bob@slyy.ai"
        d.bcc = "secret@slyy.ai"
        d.subject = "Angebot"
        d.body = "Hallo"
        d.videoURL = URL(string: "https://vid.rocket.re-cloud.io/slyy-abc")
        let m = d.message(from: EmailAddress(name: "Anna", address: "anna@slyy.ai"))
        XCTAssertEqual(m.to.map(\.address), ["j@schott.de", "bob@slyy.ai"])
        XCTAssertEqual(m.envelopeRecipients, ["j@schott.de", "bob@slyy.ai", "secret@slyy.ai"])
        XCTAssertTrue(m.text.hasPrefix("Join video call"))
        XCTAssertTrue(m.text.contains("https://vid.rocket.re-cloud.io/slyy-abc"))
        XCTAssertTrue(m.text.hasSuffix("Hallo"))
        XCTAssertFalse(String(decoding: m.render(), as: UTF8.self).contains("secret@slyy.ai"))
    }

    func testOverlappingEventsGetSeparateColumns() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let a = CalendarEvent(uid: "a", summary: "A", start: base, end: base.addingTimeInterval(7200))
        let b = CalendarEvent(uid: "b", summary: "B", start: base.addingTimeInterval(1800), end: base.addingTimeInterval(3600))
        let c = CalendarEvent(uid: "c", summary: "C", start: base.addingTimeInterval(9000), end: base.addingTimeInterval(9600))
        let l = TimeGridView.layout([a, b, c])
        XCTAssertEqual(l["a"]?.0, 0); XCTAssertEqual(l["a"]?.1, 2)
        XCTAssertEqual(l["b"]?.0, 1); XCTAssertEqual(l["b"]?.1, 2)
        XCTAssertEqual(l["c"]?.0, 0); XCTAssertEqual(l["c"]?.1, 1)
    }

    func testCalendarColours() {
        XCTAssertNotNil(Color(hex: "#2B3BFF"))
        XCTAssertNotNil(Color(hex: "#2B3BFFCC"))
        XCTAssertNil(Color(hex: "blue"))
    }

    func testSignInErrorsAreReadable() {
        let s = AccountSettings(email: "anna@slyy.ai", imap: ServerEndpoint(host: "mail.mc1.simplify-erp.de", port: 993, security: .tls), smtp: ServerEndpoint(host: "mail.mc1.simplify-erp.de", port: 587, security: .startTLS))
        XCTAssertTrue(SignInError.explain(IMAPError.authenticationFailed("x"), settings: s).contains("password"))
        XCTAssertTrue(SignInError.explain(TransportError.timeout, settings: s).contains("mail.mc1.simplify-erp.de"))
    }

    func testDraftFromAliasAndReplyPicksAlias() {
        let m = AppModel.sample()
        XCTAssertEqual(m.identities.map(\.email), ["anna@slyy.ai", "info@slyy.ai"])
        var d = ComposeDraft()
        d.to = "k@x.de"
        d.from = m.identities[1]
        XCTAssertEqual(d.message(from: m.account!.address).from.address, "info@slyy.ai")
        XCTAssertEqual(d.message(from: m.account!.address).from.name, "Slyy Info")
        let toInfo = ParsedMessage(data: Data("From: k@x.de\r\nTo: info@slyy.ai\r\nSubject: Frage\r\n\r\nx\r\n".utf8))
        m.compose(.reply(toInfo))
        XCTAssertEqual(m.composeDraft?.from?.email, "info@slyy.ai")
        XCTAssertTrue(m.composeDraft?.body.contains("Slyy · info@slyy.ai") == true, "alias signature used")
        XCTAssertTrue(m.isMine("INFO@slyy.ai"))
    }

    func testRepliesAreBlueAndQuoteIsNot() throws {
        let m = AppModel.sample()
        m.blueReplies = true
        defer { UserDefaults.standard.removeObject(forKey: "blueReplies") }
        let orig = ParsedMessage(data: Data("From: k@x.de\r\nTo: anna@slyy.ai\r\nSubject: Frage\r\nMessage-ID: <q1@x.de>\r\n\r\nOriginal text\r\n".utf8))
        m.compose(.reply(orig))
        var d = try XCTUnwrap(m.composeDraft)
        XCTAssertTrue(d.blueReply)
        XCTAssertTrue(d.quoted.contains("> Original text"))
        XCTAssertFalse(d.body.contains("Original text"), "the quote is kept apart from my text")
        d.body = "Meine Antwort" + d.body
        let out = d.message(from: m.account!.address)
        let html = try XCTUnwrap(out.html)
        XCTAssertTrue(html.hasPrefix("<div style=\"color:rgba(0, 0, 255, 1)\">"))
        let blueEnd = try XCTUnwrap(html.range(of: "</div></div>"))
        XCTAssertTrue(html[..<blueEnd.lowerBound].contains("Meine Antwort"))
        XCTAssertTrue(html[blueEnd.upperBound...].contains("Original text"), "quote stays outside the blue block")
        XCTAssertTrue(out.text.hasPrefix("Meine Antwort") && out.text.contains("> Original text"))
        XCTAssertEqual(out.inReplyTo, "<q1@x.de>")

        m.compose(.forward(orig))
        XCTAssertEqual(m.composeDraft?.blueReply, false, "forwards are not blue")
        m.blueReplies = false
        m.compose(.reply(orig))
        XCTAssertEqual(m.composeDraft?.blueReply, false)
        XCTAssertFalse(m.composeDraft!.message(from: m.account!.address).html!.contains("0, 0, 255"))
    }

    func testInboxGroupsConversations() {
        let m = AppModel.sample()
        XCTAssertEqual(m.messages.count, 6)
        XCTAssertEqual(m.threads.count, 5, "Jürgen's original and his reply are one conversation")
        let juergen = m.threads.first { $0.subject == "Angebot Wärmepumpe" }
        XCTAssertEqual(juergen?.count, 2)
        XCTAssertEqual(juergen?.unreadCount, 1)
        m.threaded = false
        XCTAssertEqual(m.thread(containing: m.messages[0]).count, 1)
        m.threaded = true
    }

    func testNewMailIsAnnouncedOnceAndNotOnFirstSync() async {
        func msg(_ uid: UInt32, seen: Bool = false) -> MessageSummary {
            MessageSummary(uid: uid, folder: "INBOX", flags: seen ? ["\\Seen"] : [], date: Date(), size: 1, from: [EmailAddress(name: "K", address: "k@x.de")], to: [], cc: [], subject: "S\(uid)", messageID: nil, hasAttachments: false, isInvite: false)
        }
        XCTAssertNil(MailNotifier.arrivals(in: [msg(5), msg(4)], after: nil), "first sync only sets the baseline")
        let r = MailNotifier.arrivals(in: [msg(8), msg(7, seen: true), msg(6), msg(5)], after: 5)
        XCTAssertEqual(r?.messages.map(\.uid), [8, 6], "new and unread only, newest first")
        XCTAssertEqual(r?.highestUID, 8)
        XCTAssertEqual(MailNotifier.arrivals(in: [msg(8), msg(6)], after: 8)?.messages.count, 0, "nothing twice")
        XCTAssertEqual(MailNotifier.arrivals(in: [], after: 8)?.highestUID, 8, "an empty inbox keeps the mark")

        let store = UserDefaults(suiteName: "notifier-test")!
        store.removePersistentDomain(forName: "notifier-test")
        store.set(false, forKey: "notifyNewMail") // no real notifications from the test host
        let id = UUID()
        await MailNotifier.process(inbox: [msg(3), msg(2)], account: id, store: store)
        XCTAssertEqual(MailNotifier.lastUID(account: id, store: store), 3, "first sync: baseline")
        await MailNotifier.process(inbox: [msg(4), msg(3)], account: id, store: store)
        XCTAssertEqual(MailNotifier.lastUID(account: id, store: store), 4)
    }

    func testAgendaGroupsByDayAndAlwaysShowsToday() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let t9 = cal.date(byAdding: .hour, value: 9, to: today)!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let in3 = cal.date(byAdding: .day, value: 3, to: today)!
        let meeting = CalendarEvent(summary: "Standup", start: cal.date(byAdding: .hour, value: 10, to: in3)!, end: cal.date(byAdding: .hour, value: 11, to: in3)!)
        var allDay = CalendarEvent(summary: "Messe", start: tomorrow, end: cal.date(byAdding: .day, value: 2, to: tomorrow)!)
        allDay.isAllDay = true
        let late = CalendarEvent(summary: "Call", start: cal.date(byAdding: .hour, value: 15, to: in3)!, end: cal.date(byAdding: .hour, value: 16, to: in3)!)
        let days = AgendaListView.days(from: t9, count: 14, events: [late, meeting, allDay], today: t9)
        XCTAssertEqual(days.map(\.date), [today, tomorrow, cal.date(byAdding: .day, value: 2, to: today)!, in3], "empty days are skipped, today stays")
        XCTAssertTrue(days[0].events.isEmpty)
        XCTAssertEqual(days[1].events.map(\.summary), ["Messe"])
        XCTAssertEqual(days[2].events.map(\.summary), ["Messe"], "a two-day event shows on both days")
        XCTAssertEqual(days[3].events.map(\.summary), ["Standup", "Call"])
        XCTAssertEqual(CalendarMode.available(compact: true), [.agenda, .day, .month])
        XCTAssertFalse(CalendarMode.available(compact: false).contains(.agenda))

        let m = AppModel.sample()
        let r = m.range(for: t9, mode: .agenda)
        XCTAssertEqual(r.0, today)
        XCTAssertEqual(cal.dateComponents([.day], from: r.0, to: r.1).day, CalendarMode.agendaDays)
        m.calendarMode = .agenda
        m.calendarDate = t9
        m.moveCalendar(by: 1)
        XCTAssertEqual(cal.dateComponents([.day], from: t9, to: m.calendarDate).day, CalendarMode.agendaDays)
    }

    func testSampleModelMatchesWireframe() {
        let m = AppModel.sample()
        XCTAssertEqual(m.folders.first?.unseen, 12)
        XCTAssertTrue(m.messages.first?.isInvite == true)
        XCTAssertEqual(m.openMessage?.calendarParts.isEmpty, false)
    }
}

#if os(macOS)
@MainActor
final class CleanupTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func touch(_ path: String, modified: Date = Date()) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func makeApp(_ path: String, bundleID: String) throws {
        let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL", "CFBundleExecutable": "x"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testRemovesOnlyOurOldInstallersAndThePreRenameApp() throws {
        let installed = Date()
        try makeApp("Applications/Slyy Mailr.app", bundleID: "ai.slyy.mailr")
        try FileManager.default.setAttributes([.modificationDate: installed], ofItemAtPath: root.appendingPathComponent("Applications/Slyy Mailr.app").path)
        try touch("Downloads/slyy-mailr-0.2.1-mac-universal.dmg")
        try touch("Downloads/slyy-mailr-0.2.1-mac-universal.dmg.sha256")
        try touch("Downloads/slyy-mailr-0.2.2-mac-universal.dmg")             // = running version → old installer
        try touch("Downloads/slyy-mailr-0.3.0-mac-universal.dmg")             // newer → keep
        try touch("Downloads/SlyyMailr.dmg", modified: installed.addingTimeInterval(-3600)) // before install → old
        try touch("Downloads/SlyyMailr (1).dmg", modified: installed.addingTimeInterval(3600)) // after install → keep
        try touch("Downloads/slyy-desktop-1.0.dmg")                            // other product → keep
        try touch("Downloads/Rechnung.pdf")
        try makeApp("Applications/Slyy Mail.app", bundleID: "ai.slyy.mail")   // pre-rename app → trash
        try makeApp("OtherApps/Slyy Mail.app", bundleID: "com.someone.else")   // same name, not ours → keep
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Volumes/Slyy Mailr 0.2.1/Slyy Mailr.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Volumes/Backup"), withIntermediateDirectories: true)

        var trashed: [String] = []
        var ejected: [String] = []
        var c = InstallerCleanup(currentVersion: "0.2.2",
                                 appBundle: root.appendingPathComponent("Applications/Slyy Mailr.app"),
                                 downloads: root.appendingPathComponent("Downloads"),
                                 applicationsFolders: [root.appendingPathComponent("Applications"), root.appendingPathComponent("OtherApps")])
        c.volumes = root.appendingPathComponent("Volumes")
        c.trash = { trashed.append($0.lastPathComponent) }
        c.eject = { ejected.append($0.lastPathComponent) }
        let report = c.run()

        XCTAssertEqual(Set(trashed), ["slyy-mailr-0.2.1-mac-universal.dmg", "slyy-mailr-0.2.1-mac-universal.dmg.sha256", "slyy-mailr-0.2.2-mac-universal.dmg", "SlyyMailr.dmg", "Slyy Mail.app"])
        XCTAssertEqual(ejected, ["Slyy Mailr 0.2.1"])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(report.summary.contains("5"))
    }

    func testNeverTouchesTheVolumeItRunsFrom() {
        var c = InstallerCleanup(currentVersion: "0.2.2", appBundle: URL(fileURLWithPath: "/Volumes/Slyy Mailr 0.2.2/Slyy Mailr.app"), downloads: nil, applicationsFolders: [])
        c.eject = { _ in XCTFail("must not eject the running app's disk") }
        XCTAssertEqual(c.runningFromVolume?.lastPathComponent, "Slyy Mailr 0.2.2")
    }

    func testVersionParsing() {
        XCTAssertEqual(InstallerCleanup.version(inInstallerName: "slyy-mailr-0.2.1-mac-universal.dmg"), "0.2.1")
        XCTAssertNil(InstallerCleanup.version(inInstallerName: "SlyyMailr.dmg"))
        XCTAssertTrue(InstallerCleanup.isOlder("0.9.2", than: "0.10.0"))
        XCTAssertFalse(InstallerCleanup.isOlder("0.2.2", than: "0.2.2"))
    }
}

/// Renders the main screens with sample data to PNGs (uploaded by CI) to compare with the wireframes.
@MainActor
final class ScreenshotTests: XCTestCase {
    var outDir: URL {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SLYY_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("screens")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Renders in a real (off-screen) window so scroll views, lists and text fields draw like in the app.
    func render<V: View>(_ view: V, _ name: String, width: CGFloat = 1280, height: CGFloat = 800) throws {
        Slyy.registerFonts()
        let content = view
            .frame(width: width, height: height)
            .font(Slyy.body)
            .foregroundStyle(Slyy.ink)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0)) // lazy stacks, async layout, fonts
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "\(name) did not render")
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(png.count, 5_000, "\(name) looks empty")
    }

    func testMail() throws {
        let m = AppModel.sample()
        try render(DesktopShell().environment(m), "1-mail")
    }

    func testConversation() throws {
        let m = AppModel.sample(conversation: true)
        try render(DesktopShell().environment(m), "6-conversation")
    }

    func testCompose() throws {
        let m = AppModel.sample()
        var d = ComposeDraft()
        d.to = "\"Jürgen Schott\" <j.schott@schott-haustechnik.de>, "
        d.subject = "Re: Angebot Wärmepumpe"
        d.body = "Hallo Herr Schott,\n\nanbei das überarbeitete Angebot. Wollen wir die Details morgen kurz per Video besprechen?\n\n-- \nAnna Weber · Slyy"
        d.videoURL = URL(string: "https://vid.rocket.re-cloud.io/slyy-p3w8kx2m9qtz7ghd4fna")
        d.attachments = [OutgoingAttachment(filename: "Angebot-2026-118.pdf", mimeType: "application/pdf", data: Data(count: 212_000))]
        d.lastSaved = Date()
        d.blueReply = true
        d.quoted = "\n\nOn 26 Nov 2026 at 09:12, Jürgen Schott <j.schott@schott-haustechnik.de> wrote:\n> Guten Morgen Frau Weber,\n> können Sie das Angebot bis Freitag anpassen?"
        try render(ComposeView(draft: d).environment(m), "2-compose", width: 860, height: 680)
    }

    func testSettingsTabs() throws {
        for (tab, name) in [(SettingsTab.mail, "7-settings-mail"), (.calendar, "8-settings-calendar"), (.video, "9-settings-video")] {
            let m = AppModel.sample(calendar: true)
            try render(SettingsView(tab: tab).environment(m), name, width: 720, height: 900)
        }
    }

    func testSetup() throws {
        let m = AppModel.sample()
        try render(AccountSetupView().environment(m), "3-setup")
    }

    func testCalendar() throws {
        let m = AppModel.sample(calendar: true)
        try render(DesktopShell().environment(m), "4-calendar")
    }

    func testEventEditor() throws {
        let m = AppModel.sample(calendar: true)
        var e = CalendarEvent(summary: "Abstimmung Angebot Schott", start: Date(), end: Date().addingTimeInterval(1800))
        e.attendees = [Attendee(email: "j.schott@schott-haustechnik.de", name: "Jürgen Schott"), Attendee(email: "heiko@slyy.ai", name: "Heiko Meier")]
        e.organizer = EmailAddress(name: "Anna Weber", address: "anna@slyy.ai")
        e.videoURL = URL(string: "https://vid.rocket.re-cloud.io/slyy-r4t9mw2kq8zx7bnhc3pe")
        e.notes = "Montage-Option und Lieferzeit klären."
        try render(EventEditorView(event: e).environment(m), "5-new-meeting", width: 640, height: 800)
    }
}
#endif
