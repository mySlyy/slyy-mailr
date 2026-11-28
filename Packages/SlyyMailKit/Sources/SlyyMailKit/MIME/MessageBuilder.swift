import Foundation

public struct OutgoingAttachment: Sendable, Hashable, Codable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// An iMIP calendar part: sent both as text/calendar alternative and as invite.ics attachment (Outlook + Gmail + Apple read either).
public struct CalendarAttachment: Sendable, Hashable {
    public var method: String
    public var ics: String

    public init(method: String, ics: String) {
        self.method = method
        self.ics = ics
    }
}

public struct OutgoingMessage: Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var text: String
    public var html: String?
    public var attachments: [OutgoingAttachment]
    public var calendar: CalendarAttachment?
    public var inReplyTo: String?
    public var references: [String]
    public var messageID: String
    public var date: Date
    /// Extra header fields (name → value), e.g. what a saved draft needs to reopen as it was; plain ASCII values.
    public var extraHeaders: [String: String] = [:]

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [], subject: String, text: String, html: String? = nil, attachments: [OutgoingAttachment] = [], calendar: CalendarAttachment? = nil, inReplyTo: String? = nil, references: [String] = [], messageID: String? = nil, date: Date = Date()) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.attachments = attachments
        self.calendar = calendar
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageID = messageID ?? OutgoingMessage.newMessageID(domain: from.domain)
        self.date = date
    }

    public static func newMessageID(domain: String) -> String {
        "<\(UUID().uuidString.lowercased())@\(domain.isEmpty ? "slyy.mail" : domain)>"
    }

    /// Everyone the SMTP server must deliver to (To + Cc + Bcc), de-duplicated.
    public var envelopeRecipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).map(\.address).filter { seen.insert($0.lowercased()).inserted }
    }

    /// RFC 5322 bytes with CRLF line endings. Bcc is never written to the headers.
    public func render() -> Data {
        var h: [String] = []
        h.append("Date: \(RFC822Date.format(date))")
        h.append("From: \(from.headerValue)")
        if !to.isEmpty { h.append("To: \(to.map(\.headerValue).joined(separator: ",\r\n "))") }
        if !cc.isEmpty { h.append("Cc: \(cc.map(\.headerValue).joined(separator: ",\r\n "))") }
        h.append("Subject: \(EncodedWord.encodeIfNeeded(subject))")
        h.append("Message-ID: \(messageID)")
        if let inReplyTo { h.append("In-Reply-To: \(inReplyTo)") }
        if !references.isEmpty { h.append("References: \(references.joined(separator: "\r\n "))") }
        h.append("MIME-Version: 1.0")
        h.append("User-Agent: Slyy Mailr")
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) where !value.contains("\r") && !value.contains("\n") {
            h.append("\(name): \(value)")
        }

        let body = renderBody()
        return Data((h.joined(separator: "\r\n") + "\r\n" + body).utf8)
    }

    private func boundary() -> String { "=_slyy_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))" }

    /// Returns "Content-Type...\r\n\r\nbody" for the whole MIME body.
    private func renderBody() -> String {
        let textPart = leaf(type: "text/plain; charset=utf-8", encoding: "quoted-printable", body: QuotedPrintable.encode(text))
        var core: String
        var alternatives = [textPart]
        if let html {
            alternatives.append(leaf(type: "text/html; charset=utf-8", encoding: "quoted-printable", body: QuotedPrintable.encode(html)))
        }
        if let calendar {
            alternatives.append(leaf(type: "text/calendar; charset=utf-8; method=\(calendar.method)", encoding: "base64", body: Base64Lines.encode(Data(calendar.ics.utf8))))
        }
        core = alternatives.count == 1 ? textPart : multipart("alternative", alternatives)

        var mixed: [String] = []
        if let calendar {
            mixed.append(leaf(
                type: "application/ics; name=\"invite.ics\"",
                encoding: "base64",
                body: Base64Lines.encode(Data(calendar.ics.utf8)),
                disposition: "attachment; filename=\"invite.ics\""
            ))
        }
        for a in attachments {
            let name = parameterValue(a.filename)
            mixed.append(leaf(
                type: "\(a.mimeType); name=\(name)",
                encoding: "base64",
                body: Base64Lines.encode(a.data),
                disposition: "attachment; filename=\(name)"
            ))
        }
        if mixed.isEmpty { return core }
        return multipart("mixed", [core] + mixed)
    }

    private func leaf(type: String, encoding: String, body: String, disposition: String? = nil) -> String {
        var s = "Content-Type: \(type)\r\nContent-Transfer-Encoding: \(encoding)\r\n"
        if let disposition { s += "Content-Disposition: \(disposition)\r\n" }
        return s + "\r\n" + body
    }

    private func multipart(_ sub: String, _ parts: [String]) -> String {
        let b = boundary()
        var s = "Content-Type: multipart/\(sub); boundary=\"\(b)\"\r\n\r\n"
        for p in parts { s += "--\(b)\r\n\(p)\r\n" }
        return s + "--\(b)--\r\n"
    }

    /// Quoted ASCII filename, or an RFC 2047 encoded word for non-ASCII names (widely supported by mail clients).
    private func parameterValue(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        if safe.unicodeScalars.allSatisfy(\.isASCII) { return "\"\(safe)\"" }
        return "\"=?UTF-8?B?\(Data(safe.utf8).base64EncodedString())?=\""
    }
}

public enum ReplyKind {
    case reply, replyAll, forward
}

public extension ParsedMessage {
    /// "On <date>, <sender> wrote:" for a reply; the forwarded-message header block for a forward.
    func quoteIntro(_ kind: ReplyKind) -> String {
        let when = date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
        let who = from.first?.headerValue ?? ""
        if kind == .forward {
            return "---------- Forwarded message ----------\nFrom: \(who)\nDate: \(when)\nSubject: \(subject)\nTo: \(to.map(\.headerValue).joined(separator: ", "))"
        }
        return "On \(when), \(who) wrote:"
    }

    /// The original as HTML for the reply's or forward's HTML part (nil for a text-only mail or a quoted selection).
    func htmlQuote(_ kind: ReplyKind) -> String? {
        guard let htmlBody, !htmlBody.isEmpty else { return nil }
        return HTMLText.fromPlain("\n" + quoteIntro(kind)) + HTMLText.quoteBlock(htmlBody)
    }

    /// Prepares a reply/forward draft: recipients, subject prefix, threading headers and quoted text.
    func draft(_ kind: ReplyKind, me: EmailAddress) -> OutgoingMessage {
        draft(kind, me: me, myAddresses: [me.address.lowercased()])
    }

    /// Same, with all of my addresses (aliases) left out of Reply All.
    func draft(_ kind: ReplyKind, me: EmailAddress, myAddresses: Set<String>) -> OutgoingMessage {
        let sender = replyTo.isEmpty ? from : replyTo
        var to: [EmailAddress] = []
        var cc: [EmailAddress] = []
        switch kind {
        case .reply:
            to = sender
        case .replyAll:
            let mine = myAddresses.union([me.address.lowercased()])
            to = sender.filter { !mine.contains($0.address.lowercased()) }
            var seen = Set(to.map { $0.address.lowercased() })
            to += self.to.filter { a in !mine.contains(a.address.lowercased()) && seen.insert(a.address.lowercased()).inserted }
            cc = self.cc.filter { a in !mine.contains(a.address.lowercased()) && seen.insert(a.address.lowercased()).inserted }
            if to.isEmpty && cc.isEmpty { to = sender } // only I was involved: reply to the sender
        case .forward:
            break
        }
        let prefix = kind == .forward ? "Fwd: " : "Re: "
        let lower = subject.lowercased()
        let hasPrefix = kind == .forward ? (lower.hasPrefix("fwd:") || lower.hasPrefix("wg:") || lower.hasPrefix("fw:")) : (lower.hasPrefix("re:") || lower.hasPrefix("aw:"))
        let newSubject = hasPrefix ? subject : prefix + subject

        let original = textBody ?? htmlBody.map(HTMLText.toPlain) ?? ""
        let quoted: String
        if kind == .forward {
            quoted = "\n\n" + quoteIntro(kind) + "\n\n\(original)"
        } else {
            quoted = "\n\n" + quoteIntro(kind) + "\n" + original.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        }
        var refs = references
        if let messageID { refs.append(messageID) }
        var msg = OutgoingMessage(from: me, to: to, cc: cc, subject: newSubject, text: quoted)
        if kind != .forward {
            msg.inReplyTo = messageID
            msg.references = refs
        }
        if kind == .forward {
            msg.attachments = attachments.filter { !$0.isInline }.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        }
        return msg
    }
}

public extension ParsedMessage {
    /// The message reduced to a text selection, for a reply or forward of just that part:
    /// the selection becomes the whole text, with no HTML, attachments or invitations.
    /// An empty (or whitespace-only) selection leaves the message as it is.
    func quoting(_ selection: String) -> ParsedMessage {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        var copy = self
        copy.textBody = trimmed
        copy.htmlBody = nil
        copy.attachments = []
        copy.calendarParts = []
        return copy
    }
}

public enum HTMLText {
    /// HTML → readable text for quotes, plain alternatives and the assistant: no markup, comments, styles or
    /// scripts; the HTML source's own line breaks and indentation are just spaces; <br> is one line break,
    /// a paragraph two; list items get "- "; entities (named and numeric) are decoded; invisible characters go.
    public static func toPlain(_ html: String) -> String {
        var s = html
        func sub(_ pattern: String, _ with: String) {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        sub("(?s)<!--.*?-->", "")
        sub("(?is)<(script|style|head|title|xml|svg|noscript)\\b[^>]*>.*?</\\1\\s*>", "")
        if let r = s.range(of: "(?is)<body\\b[^>]*>(.*)</body\\s*>", options: .regularExpression) {
            s = String(s[r]).replacingOccurrences(of: "(?is)^<body\\b[^>]*>|</body\\s*>$", with: "", options: .regularExpression)
        }
        sub("[ \\t\\r\\n\\f]+", " ")                                  // source whitespace is not layout
        sub("(?i)<br\\s*/?>", "\n")
        sub("(?i)</?p\\b[^>]*>", "\n\n")
        sub("(?i)<li\\b[^>]*>", "\n- ")
        sub("(?i)</?(div|tr|table|tbody|thead|ul|ol|h[1-6]|blockquote|section|article|header|footer|center|hr)\\b[^>]*>", "\n")
        sub("(?i)</t[dh]\\s*>", " ")
        sub("<[^>]+>", "")
        s = decodeEntities(s)
        // Zero-width and other invisible characters (common in newsletters), soft hyphens.
        s = s.unicodeScalars.filter { !["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{034F}", "\u{00AD}"].contains($0) }
            .map(String.init).joined()
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = s.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        s = lines.joined(separator: "\n")
        sub("\n{3,}", "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// &amp; &nbsp; &#8217; &#x2019; … → characters (unknown names stay as they are).
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "nbsp": "\u{00A0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'",
            "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚", "bdquo": "„",
            "laquo": "«", "raquo": "»", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "deg": "°",
            "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è",
            "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{00AD}", "times": "×", "para": "¶", "sect": "§",
        ]
        guard let rx = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,7});") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            var rep: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                rep = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                rep = named[name] ?? UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                rep = named[name]
            }
            out += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The original HTML for quoting inside a reply or forward: the body's content only, without scripts, styles,
    /// comments, forms or event handlers, in a cite blockquote.
    public static func quoteBlock(_ html: String) -> String {
        var s = html
        func sub(_ pattern: String, _ with: String) {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        sub("(?s)<!--.*?-->", "")
        sub("(?is)<(script|style|head|title|xml|noscript|form|iframe|object|embed)\\b[^>]*>.*?</\\1\\s*>", "")
        if let r = s.range(of: "(?is)<body\\b[^>]*>(.*)</body\\s*>", options: .regularExpression) {
            s = String(s[r]).replacingOccurrences(of: "(?is)^<body\\b[^>]*>|</body\\s*>$", with: "", options: .regularExpression)
        }
        sub("(?is)</?(html|body|meta|link|base|input|button|script|style)\\b[^>]*>", "")
        sub("(?i)\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", "")
        return "<blockquote type=\"cite\" style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(s)</blockquote>"
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Plain text → simple HTML with clickable links (used for display of text-only mail).
    public static func fromPlain(_ text: String) -> String {
        let escaped = escape(text)
        let linked = escaped.replacingOccurrences(
            of: "(https?://[^\\s<>\"]+[^\\s<>\".,;:!?)])",
            with: "<a href=\"$1\">$1</a>",
            options: .regularExpression
        )
        return "<div style=\"white-space:pre-wrap\">\(linked)</div>"
    }
}
