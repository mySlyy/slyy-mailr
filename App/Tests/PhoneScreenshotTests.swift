#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import SlyyMailKit
@testable import SlyyMailr

/// iPhone screens with sample data, rendered in the simulator to PNGs (uploaded by CI as "screens-ios").
@MainActor
final class PhoneScreenshotTests: XCTestCase {
    var outDir: URL {
        let base = ProcessInfo.processInfo.environment["SLYY_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: base).appendingPathComponent("screens-ios")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// iPhone 15 size in points, rendered at 2x.
    func render<V: View>(_ view: V, _ name: String, width: CGFloat = 393, height: CGFloat = 852) throws {
        Slyy.registerFonts()
        let host = UIHostingController(rootView: view
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.colorScheme, .light))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5)) // lists, async layout, fonts
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        let png = try XCTUnwrap(image.pngData())
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(png.count, 10_000, "\(name) looks empty")
    }

    func testInbox() throws {
        let m = AppModel.sample()
        try render(PhoneShell().environment(m), "p1-inbox")
    }

    func testAgenda() throws {
        UserDefaults.standard.set(CalendarMode.agenda.rawValue, forKey: "phoneCalendarMode")
        let m = AppModel.sample(calendar: true)
        try render(NavigationStack { CalendarView() }.environment(m), "p2-agenda")
    }

    func testCompose() throws {
        let m = AppModel.sample()
        var d = ComposeDraft()
        d.to = "\"Jürgen Schott\" <j.schott@schott-haustechnik.de>, "
        d.subject = "Re: Angebot Wärmepumpe"
        d.body = "Hallo Herr Schott,\n\nanbei die Fotos von der Baustelle.\n\n-- \nAnna Weber · Slyy"
        d.blueReply = true
        d.quoted = "\n\nOn 26 Nov 2026 at 09:12, Jürgen Schott wrote:\n> Können Sie Fotos schicken?"
        d.attachments = [OutgoingAttachment(filename: "Photo 1.jpg", mimeType: "image/jpeg", data: Data(count: 840_000))]
        try render(ComposeView(draft: d).environment(m), "p3-compose")
    }

    func testMessage() throws {
        let m = AppModel.sample()
        try render(NavigationStack { MessageDetailView() }.environment(m), "p4-message")
    }

    func testSettings() throws {
        let m = AppModel.sample(calendar: true)
        try render(NavigationStack { SettingsView() }.environment(m), "p5-settings")
    }

    func testPhotoResize() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).image { ctx in UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4032, height: 3024)) }
        let data = try XCTUnwrap(PhotoAttachment.jpeg(big))
        let back = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(max(back.size.width * back.scale, back.size.height * back.scale), PhotoAttachment.maxSide, accuracy: 1)
        XCTAssertLessThan(data.count, 2_000_000)
    }
}
#endif
