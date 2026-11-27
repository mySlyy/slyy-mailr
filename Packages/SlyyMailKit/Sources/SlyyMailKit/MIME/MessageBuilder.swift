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

        let when = date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
        let who = from.first?.headerValue ?? ""
        let original = textBody ?? htmlBody.map(HTMLText.toPlain) ?? ""
        let quoted: String
        if kind == .forward {
            quoted = "\n\n---------- Forwarded message ----------\nFrom: \(who)\nDate: \(when)\nSubject: \(subject)\nTo: \(self.to.map(\.headerValue).joined(separator: ", "))\n\n\(original)"
        } else {
            quoted = "\n\nOn \(when), \(who) wrote:\n" + original.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
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

public enum HTMLText {
    /// Rough HTML → text for quoting and plain alternatives.
    public static func toPlain(_ html: String) -> String {
        var s = html
        let replacements: [(String, String)] = [
            ("(?is)<(script|style|head)[^>]*>.*?</\\1>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|tr|h[1-6]|li|blockquote)>", "\n"),
            ("(?i)<li[^>]*>", "- "),
            ("<[^>]+>", ""),
        ]
        for (pattern, with) in replacements {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
