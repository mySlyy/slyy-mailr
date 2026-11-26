import XCTest
import SwiftUI
import AppKit
import SlyyMailKit
@testable import SlyyMailr

@MainActor
final class AppLogicTests: XCTestCase {
    func testFontsAreBundledAndLoad() {
        Slyy.registerFonts()
        for name in ["HankenGrotesk-Regular", "HankenGrotesk-Medium", "HankenGrotesk-SemiBold", "HankenGrotesk-Bold", "MartianMono-Regular", "MartianMono-Medium"] {
            XCTAssertNotNil(NSFont(name: name, size: 14), "\(name) missing from the app bundle")
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

    func testSampleModelMatchesWireframe() {
        let m = AppModel.sample()
        XCTAssertEqual(m.folders.first?.unseen, 12)
        XCTAssertTrue(m.messages.first?.isInvite == true)
        XCTAssertEqual(m.openMessage?.calendarParts.isEmpty, false)
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

    func testCompose() throws {
        let m = AppModel.sample()
        var d = ComposeDraft()
        d.to = "\"Jürgen Schott\" <j.schott@schott-haustechnik.de>, "
        d.subject = "Re: Angebot Wärmepumpe"
        d.body = "Hallo Herr Schott,\n\nanbei das überarbeitete Angebot. Wollen wir die Details morgen kurz per Video besprechen?\n\n-- \nAnna Weber · Slyy"
        d.videoURL = URL(string: "https://vid.rocket.re-cloud.io/slyy-p3w8kx2m9qtz7ghd4fna")
        d.attachments = [OutgoingAttachment(filename: "Angebot-2026-118.pdf", mimeType: "application/pdf", data: Data(count: 212_000))]
        d.lastSaved = Date()
        try render(ComposeView(draft: d).environment(m), "2-compose", width: 860, height: 680)
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
