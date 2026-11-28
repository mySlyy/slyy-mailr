import XCTest
@testable import SlyyMailKit

final class MIMETests: XCTestCase {
    func testEncodedWords() {
        XCTAssertEqual(EncodedWord.decode("=?utf-8?Q?Gr=C3=BC=C3=9Fe_aus_Bayreuth?="), "Grüße aus Bayreuth")
        XCTAssertEqual(EncodedWord.decode("=?ISO-8859-1?Q?M=FCller?= <m@x.de>"), "Müller <m@x.de>")
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?SGFsbG8=?= =?UTF-8?B?IFdlbHQ=?="), "Hallo Welt")
        XCTAssertEqual(EncodedWord.decode("plain text"), "plain text")
        let enc = EncodedWord.encodeIfNeeded("Angebot für Öffis – Wärmepumpe")
        XCTAssertTrue(enc.hasPrefix("=?UTF-8?B?"))
        XCTAssertEqual(EncodedWord.decode(enc.replacingOccurrences(of: "\r\n", with: "")), "Angebot für Öffis – Wärmepumpe")
    }

    func testQuotedPrintableRoundTrip() {
        let text = "Grüße,\nLine with = sign and a very long line that definitely exceeds the seventy-six character limit of QP.\nEnd. "
        let enc = QuotedPrintable.encode(text)
        XCTAssertTrue(enc.split(separator: "\r\n").allSatisfy { $0.count <= 76 })
        let dec = String(decoding: QuotedPrintable.decode(Data(enc.utf8)), as: UTF8.self)
        XCTAssertEqual(dec, text.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testAddressList() {
        let list = EmailAddress.parseList("\"Müller, Hans\" <hans@slyy.ai>, bob@example.com, =?utf-8?Q?J=C3=BCrgen?= <j@x.de>, Team <team@x.de>")
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[0].name, "Müller, Hans")
        XCTAssertEqual(list[0].address, "hans@slyy.ai")
        XCTAssertEqual(list[1].address, "bob@example.com")
        XCTAssertEqual(list[2].name, "Jürgen")
        XCTAssertEqual(EmailAddress(name: "Müller, Hans", address: "h@x.de").headerValue.hasPrefix("=?UTF-8?B?"), true)
        XCTAssertEqual(EmailAddress(name: "Doe, John", address: "j@x.de").headerValue, "\"Doe, John\" <j@x.de>")
    }

    func testDates() {
        let d = RFC822Date.parse("Thu, 26 Nov 2026 16:40:00 +0100")
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2026-11-26T15:40:00Z"))
        XCTAssertNotNil(RFC822Date.parse("26 Nov 2026 16:40:00 +0100 (CET)"))
        XCTAssertNotNil(RFC822Date.parse(RFC822Date.format(Date())))
    }

    func testInlineImagesResolveWholeCIDsOnly() {
        // image1 must not match inside image10 (regression: substring replacement).
        let raw = """
        From: r8@example.com\r
        To: r8@example.com\r
        Subject: Inline\r
        MIME-Version: 1.0\r
        Content-Type: multipart/related; boundary="RR"\r
        \r
        --RR\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <img src="cid:image1"><img src='cid:image10'><div style="background:url(CID:image10)"></div><img src=cid:image1 alt=x><img src="cid:missing">\r
        --RR\r
        Content-Type: image/png\r
        Content-ID: <image1>\r
        Content-Transfer-Encoding: base64\r
        \r
        AQID\r
        --RR\r
        Content-Type: image/gif\r
        Content-ID: <image10>\r
        Content-Transfer-Encoding: base64\r
        \r
        CgsM\r
        --RR--\r
        """
        let m = ParsedMessage(data: Data(raw.utf8))
        let html = InlineImages.resolve(m.htmlBody ?? "", attachments: m.attachments)
        let one = "data:image/png;base64,AQID"
        let ten = "data:image/gif;base64,CgsM"
        XCTAssertEqual(html, "<img src=\"\(one)\"><img src='\(ten)'><div style=\"background:url(\(ten))\"></div><img src=\(one) alt=x><img src=\"cid:missing\">")

        // Content-ID with brackets, percent-encoded reference, and no false match on "acid:".
        let a = Attachment(id: 0, filename: "a b", mimeType: "image/png", data: Data([1]), contentID: "<a b@x>")
        XCTAssertEqual(InlineImages.resolve("<img src=\"cid:a%20b@x\"> acid:a b@x", attachments: [a]),
                       "<img src=\"data:image/png;base64,AQ==\"> acid:a b@x")
    }

    func testMultipartParsing() {
        let raw = """
        From: =?utf-8?Q?J=C3=BCrgen?= <j@example.com>\r
        To: alice@example.com\r
        Subject: Test\r
        Date: Thu, 26 Nov 2026 10:00:00 +0000\r
        Message-ID: <abc@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="XX"\r
        \r
        preamble\r
        --XX\r
        Content-Type: multipart/alternative; boundary="YY"\r
        \r
        --YY\r
        Content-Type: text/plain; charset=iso-8859-1\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Gr=FC=DFe\r
        --YY\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Grüße</p>\r
        --YY--\r
        --XX\r
        Content-Type: application/pdf; name*=UTF-8''Rechnung%20M%C3%A4rz.pdf\r
        Content-Disposition: attachment\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQK\r
        --XX--\r
        """
        let m = ParsedMessage(data: Data(raw.utf8))
        XCTAssertEqual(m.from.first?.name, "Jürgen")
        XCTAssertEqual(m.textBody, "Grüße")
        XCTAssertEqual(m.htmlBody, "<p>Grüße</p>")
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertEqual(m.attachments.first?.filename, "Rechnung März.pdf")
        XCTAssertEqual(String(decoding: m.attachments.first!.data, as: UTF8.self), "%PDF-1.4\n")
        XCTAssertEqual(m.messageID, "<abc@example.com>")
    }

    func testBuildAndReparse() {
        var msg = OutgoingMessage(
            from: EmailAddress(name: "Alice Ä", address: "alice@example.com"),
            to: [EmailAddress(address: "bob@example.com")],
            bcc: [EmailAddress(address: "secret@example.com")],
            subject: "Einladung: Planung",
            text: "Hallo Bob,\n.\nbis morgen",
            html: "<p>Hallo Bob</p>",
            attachments: [OutgoingAttachment(filename: "Ängebot.pdf", mimeType: "application/pdf", data: Data("PDF".utf8))]
        )
        msg.calendar = CalendarAttachment(method: "REQUEST", ics: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        let data = msg.render()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret@example.com"), "Bcc must not be in headers")
        XCTAssertEqual(msg.envelopeRecipients, ["bob@example.com", "secret@example.com"])
        let parsed = ParsedMessage(data: data)
        XCTAssertEqual(parsed.subject, "Einladung: Planung")
        XCTAssertEqual(parsed.from.first?.name, "Alice Ä")
        XCTAssertEqual(parsed.textBody, "Hallo Bob,\r\n.\r\nbis morgen")
        XCTAssertEqual(parsed.htmlBody, "<p>Hallo Bob</p>")
        XCTAssertEqual(parsed.calendarParts.count, 2) // inline alternative + invite.ics attachment
        XCTAssertTrue(parsed.attachments.contains { $0.filename == "Ängebot.pdf" })
    }

    func testReplyDraft() {
        let raw = "From: Bob <bob@example.com>\r\nTo: alice@example.com, carol@example.com\r\nCc: dave@example.com\r\nSubject: Plan\r\nMessage-ID: <m1@x>\r\n\r\nHi\r\n"
        let m = ParsedMessage(data: Data(raw.utf8))
        let me = EmailAddress(address: "alice@example.com")
        let r = m.draft(.replyAll, me: me)
        XCTAssertEqual(r.subject, "Re: Plan")
        XCTAssertEqual(r.to.map(\.address), ["bob@example.com", "carol@example.com"])
        XCTAssertEqual(r.cc.map(\.address), ["dave@example.com"])
        XCTAssertEqual(r.inReplyTo, "<m1@x>")
        XCTAssertTrue(r.text.contains("> Hi"))
        XCTAssertEqual(m.draft(.forward, me: me).subject, "Fwd: Plan")
    }

    func testDotStuffing() {
        let out = SMTPClient.dotStuff(Data("a\n.b\r\n..c".utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "a\r\n..b\r\n...c\r\n")
    }
}

final class IMAPParserTests: XCTestCase {
    func testFetchResponseWithLiteral() {
        let raw = Data("* 3 FETCH (UID 42 FLAGS (\\Seen \\Flagged) RFC822.SIZE 1234 BODY[HEADER.FIELDS (FROM SUBJECT)] {26}\r\nFrom: a@b\r\nSubject: Hi\r\n\r\n)".utf8)
        guard case .untagged(let v) = IMAPParser.parse(raw) else { return XCTFail() }
        XCTAssertEqual(v[0], .atom("3"))
        let map = IMAPClient.fetchMap(v[2].list ?? [])
        XCTAssertEqual(map["UID"]?.int, 42)
        XCTAssertEqual(map["FLAGS"]?.list, [.atom("\\Seen"), .atom("\\Flagged")])
        XCTAssertEqual(map["BODY[HEADER.FIELDS]"]?.text, "From: a@b\r\nSubject: Hi\r\n\r\n")
    }

    func testTaggedWithCode() {
        guard case .tagged(let tag, let status, let code, let text) = IMAPParser.parse(Data("S5 OK [APPENDUID 1700 12] Append completed.".utf8)) else { return XCTFail() }
        XCTAssertEqual(tag, "S5")
        XCTAssertEqual(status, "OK")
        XCTAssertEqual(code, [.atom("APPENDUID"), .atom("1700"), .atom("12")])
        XCTAssertEqual(text, "Append completed.")
    }

    func testListAndQuoted() {
        guard case .untagged(let v) = IMAPParser.parse(Data("* LIST (\\HasNoChildren \\Drafts) \"/\" \"Entw&APw-rfe\"".utf8)) else { return XCTFail() }
        XCTAssertEqual(v[2].text, "/")
        XCTAssertEqual(ModifiedUTF7.decode(v[3].text ?? ""), "Entwürfe")
        XCTAssertEqual(ModifiedUTF7.encode("Entwürfe"), "Entw&APw-rfe")
        XCTAssertEqual(ModifiedUTF7.encode("A&B"), "A&-B")
        XCTAssertEqual(ModifiedUTF7.decode("A&-B"), "A&B")
        XCTAssertEqual(ModifiedUTF7.decode(ModifiedUTF7.encode("Gelöschte Elemente/日本")), "Gelöschte Elemente/日本")
    }

    func testUIDSet() {
        XCTAssertEqual(IMAPClient.uidSet([5, 1, 2, 3, 9, 10]), "1:3,5,9:10")
        XCTAssertEqual(IMAPParser.trailingLiteralLength(Data("* 1 FETCH (BODY[] {123}".utf8)), 123)
        XCTAssertEqual(IMAPParser.trailingLiteralLength(Data("A1 APPEND x {12+}".utf8)), 12)
        XCTAssertNil(IMAPParser.trailingLiteralLength(Data("* OK done}".utf8)))
    }

    func testSpecialUseNames() {
        XCTAssertEqual(SpecialUse.from(name: "Gesendete Elemente"), .sent)
        XCTAssertEqual(SpecialUse.from(name: "Papierkorb"), .trash)
        XCTAssertEqual(SpecialUse.from(flags: ["\\HasNoChildren", "\\Junk"]), .junk)
    }
}

final class AutoConfigTests: XCTestCase {
    func testParseThunderbirdConfig() {
        let xml = """
        <?xml version="1.0"?>
        <clientConfig version="1.1"><emailProvider id="example.com">
          <incomingServer type="imap"><hostname>mail.%EMAILDOMAIN%</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username></incomingServer>
          <outgoingServer type="smtp"><hostname>mail.example.com</hostname><port>587</port><socketType>STARTTLS</socketType><username>%EMAILLOCALPART%</username></outgoingServer>
        </emailProvider></clientConfig>
        """
        let s = AutoConfig.parse(Data(xml.utf8), email: "alice@example.com")
        XCTAssertEqual(s?.imap, ServerEndpoint(host: "mail.example.com", port: 993, security: .tls))
        XCTAssertEqual(s?.smtp, ServerEndpoint(host: "mail.example.com", port: 587, security: .startTLS))
        XCTAssertEqual(s?.username, "alice@example.com")
    }

    func testJitsiRoom() {
        let u = JitsiRoom.newURL()
        XCTAssertEqual(u.host, "vid.rocket.re-cloud.io")
        XCTAssertEqual(u.lastPathComponent.count, "slyy-".count + 20)
        XCTAssertNotEqual(JitsiRoom.newURL(), u)
        XCTAssertEqual(JitsiRoom.findLink(in: "Join here: \(u.absoluteString). Thanks"), u)
        let desc = JitsiRoom.descriptionBlock(u) + "\nAgenda"
        XCTAssertEqual(JitsiRoom.stripDescriptionBlock(desc), "Agenda")
    }
}
