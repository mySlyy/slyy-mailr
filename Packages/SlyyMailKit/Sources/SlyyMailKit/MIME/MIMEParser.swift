import Foundation

/// Ordered, case-insensitive message headers (folded lines already joined).
public struct MessageHeaders: Sendable, Hashable {
    public private(set) var fields: [(name: String, value: String)] = []

    public init() {}

    public init(parsing data: Data) {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var current: (String, String)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                if current != nil { current!.1 += " " + line.trimmingCharacters(in: .whitespacesAndNewlines) }
                continue
            }
            if let c = current { fields.append((c.0, c.1)) }
            if let colon = line.firstIndex(of: ":") {
                current = (String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines),
                           String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                current = nil
            }
        }
        if let c = current { fields.append((c.0, c.1)) }
    }

    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append((name, value))
    }

    public static func == (a: MessageHeaders, b: MessageHeaders) -> Bool {
        a.fields.map { "\($0.name):\($0.value)" } == b.fields.map { "\($0.name):\($0.value)" }
    }

    public func hash(into hasher: inout Hasher) {
        for f in fields { hasher.combine(f.name); hasher.combine(f.value) }
    }
}

/// "text/plain; charset=utf-8; name*=UTF-8''%C3%A4.pdf" → value + parameters (RFC 2045 + RFC 2231).
public struct HeaderValue: Sendable {
    public var value: String
    public var params: [String: String]

    public init(_ raw: String) {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        value = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let key = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = EmailAddress.unquote(p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            // RFC 2231: name*0*=..., name*1=..., name*=charset''value
            let segs = key.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            if segs.count >= 2 {
                let base = segs[0]
                let extended = key.hasSuffix("*")
                let index = segs.count >= 2 ? Int(segs[1]) ?? 0 : 0
                continuations[base, default: []].append((index, val, extended))
            } else {
                params[key] = EncodedWord.decode(val)
            }
        }
        for (base, pieces) in continuations {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            var charset = "utf-8"
            var bytes = Data()
            for (i, piece) in sorted.enumerated() {
                var v = piece.1
                if piece.2 {
                    if i == 0, let first = v.firstIndex(of: "'"), let second = v[v.index(after: first)...].firstIndex(of: "'") {
                        charset = String(v[..<first])
                        v = String(v[v.index(after: second)...])
                    }
                    bytes.append(HeaderValue.percentDecode(v))
                } else {
                    bytes.append(Data(v.utf8))
                }
            }
            params[base] = Charset.decode(bytes, charset: charset.isEmpty ? "utf-8" : charset)
        }
        self.params = params
    }

    static func percentDecode(_ s: String) -> Data {
        var out = Data()
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            if c == UInt8(ascii: "%"), it.count >= 2, let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) {
                out.append(v)
                it = it.dropFirst(2)
            } else {
                out.append(c)
            }
        }
        return out
    }
}

/// One node of a MIME tree. Leaf bodies are transfer-decoded bytes.
public struct MIMEPart: Sendable {
    public var headers: MessageHeaders
    public var contentType: String
    public var params: [String: String]
    public var body: Data
    public var children: [MIMEPart]

    public var isMultipart: Bool { contentType.hasPrefix("multipart/") }

    public var disposition: HeaderValue? {
        headers["Content-Disposition"].map(HeaderValue.init)
    }

    public var filename: String? {
        disposition?.params["filename"] ?? params["name"]
    }

    public var contentID: String? {
        headers["Content-ID"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
    }

    public var text: String {
        Charset.decode(body, charset: params["charset"])
    }
}

public enum MIMEParser {
    /// Parses a full RFC 5322 message (or a body part).
    public static func parse(_ data: Data, depth: Int = 0) -> MIMEPart {
        let (headerData, bodyData) = split(data)
        let headers = MessageHeaders(parsing: headerData)
        let ct = HeaderValue(headers["Content-Type"] ?? "text/plain; charset=us-ascii")
        let contentType = ct.value.isEmpty ? "text/plain" : ct.value
        if contentType.hasPrefix("multipart/"), let boundary = ct.params["boundary"], depth < 20 {
            let children = splitMultipart(bodyData, boundary: boundary).map { parse($0, depth: depth + 1) }
            return MIMEPart(headers: headers, contentType: contentType, params: ct.params, body: Data(), children: children)
        }
        if contentType == "message/rfc822", depth < 20 {
            let decoded = decodeTransfer(bodyData, encoding: headers["Content-Transfer-Encoding"])
            return MIMEPart(headers: headers, contentType: contentType, params: ct.params, body: decoded, children: [parse(decoded, depth: depth + 1)])
        }
        let decoded = decodeTransfer(bodyData, encoding: headers["Content-Transfer-Encoding"])
        return MIMEPart(headers: headers, contentType: contentType, params: ct.params, body: decoded, children: [])
    }

    static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch (encoding ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": return Base64Lines.decode(data)
        case "quoted-printable": return QuotedPrintable.decode(data)
        default: return data
        }
    }

    /// Splits at the first empty line.
    static func split(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var i = 0
        func head(_ end: Int) -> Data {
            var e = end
            if e > 0, bytes[e - 1] == 0x0D { e -= 1 }
            return Data(bytes[0..<e])
        }
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { return (head(i), Data(bytes[(i + 2)...])) }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { return (head(i), Data(bytes[(i + 3)...])) }
            }
            i += 1
        }
        // Headers only (or a body with no headers at all if it starts with a blank line).
        if bytes.first == 0x0A { return (Data(), Data(bytes.dropFirst())) }
        if bytes.starts(with: [0x0D, 0x0A]) { return (Data(), Data(bytes.dropFirst(2))) }
        return (data, Data())
    }

    static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let delimiter = Array("--\(boundary)".utf8)
        let bytes = [UInt8](data)
        var parts: [Data] = []
        var lineStart = 0
        var partStart: Int?
        var i = 0
        func lineEnd(from: Int) -> Int {
            var j = from
            while j < bytes.count, bytes[j] != 0x0A { j += 1 }
            return j
        }
        while lineStart < bytes.count {
            let end = lineEnd(from: lineStart)
            let line = bytes[lineStart..<end]
            if line.starts(with: delimiter) {
                let rest = line.dropFirst(delimiter.count)
                let isClose = rest.starts(with: [UInt8(ascii: "-"), UInt8(ascii: "-")])
                if let ps = partStart {
                    // Part body ends before the CRLF preceding the delimiter line.
                    var pe = lineStart
                    if pe > ps, bytes[pe - 1] == 0x0A { pe -= 1 }
                    if pe > ps, bytes[pe - 1] == 0x0D { pe -= 1 }
                    parts.append(Data(bytes[ps..<max(ps, pe)]))
                }
                if isClose { return parts }
                partStart = min(end + 1, bytes.count)
            }
            lineStart = end + 1
            i += 1
        }
        if let ps = partStart, ps < bytes.count { parts.append(Data(bytes[ps...])) }
        return parts
    }
}

public struct Attachment: Identifiable, Sendable, Hashable {
    public var id: Int
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var contentID: String?
    public var isInline: Bool

    public init(id: Int, filename: String, mimeType: String, data: Data, contentID: String? = nil, isInline: Bool = false) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
        self.isInline = isInline
    }
}

/// A message reduced to what the reader needs.
public struct ParsedMessage: Sendable {
    public var headers: MessageHeaders
    public var subject: String
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [Attachment]
    /// text/calendar parts (invites, replies, cancellations).
    public var calendarParts: [String]

    public init(data: Data) {
        let root = MIMEParser.parse(data)
        headers = root.headers
        subject = EncodedWord.decode(root.headers["Subject"] ?? "")
        from = EmailAddress.parseList(root.headers["From"] ?? "")
        to = EmailAddress.parseList(root.headers["To"] ?? "")
        cc = EmailAddress.parseList(root.headers["Cc"] ?? "")
        replyTo = EmailAddress.parseList(root.headers["Reply-To"] ?? "")
        date = root.headers["Date"].flatMap(RFC822Date.parse)
        messageID = root.headers["Message-ID"]?.trimmingCharacters(in: .whitespaces)
        inReplyTo = root.headers["In-Reply-To"]?.trimmingCharacters(in: .whitespaces)
        references = (root.headers["References"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var text: String?
        var html: String?
        var atts: [Attachment] = []
        var cals: [String] = []
        ParsedMessage.walk(root, text: &text, html: &html, attachments: &atts, calendars: &cals)
        textBody = text
        htmlBody = html
        attachments = atts
        calendarParts = cals
    }

    private static func walk(_ part: MIMEPart, text: inout String?, html: inout String?, attachments: inout [Attachment], calendars: inout [String]) {
        if part.contentType == "multipart/alternative" {
            // Prefer the richest alternative we understand; still collect calendar parts.
            for child in part.children where child.contentType == "text/calendar" {
                calendars.append(child.text)
            }
            if let h = part.children.last(where: { $0.contentType == "text/html" || $0.isMultipart }) , h.isMultipart {
                walk(h, text: &text, html: &html, attachments: &attachments, calendars: &calendars)
                if text == nil, let t = part.children.first(where: { $0.contentType == "text/plain" }) { text = t.text }
                return
            }
            for child in part.children where !child.isMultipart && child.contentType != "text/calendar" {
                walk(child, text: &text, html: &html, attachments: &attachments, calendars: &calendars)
            }
            return
        }
        if part.isMultipart {
            for child in part.children { walk(child, text: &text, html: &html, attachments: &attachments, calendars: &calendars) }
            return
        }
        if part.contentType == "message/rfc822" {
            attachments.append(Attachment(id: attachments.count, filename: part.filename ?? "message.eml", mimeType: part.contentType, data: part.body))
            return
        }
        let isAttachment = part.disposition?.value == "attachment"
        if part.contentType == "text/calendar" || part.contentType == "application/ics" {
            calendars.append(part.text)
            if !isAttachment { return }
        }
        if !isAttachment, part.contentType == "text/plain", text == nil {
            text = part.text
            return
        }
        if !isAttachment, part.contentType == "text/html", html == nil {
            html = part.text
            return
        }
        let name = part.filename ?? defaultName(part.contentType, index: attachments.count)
        attachments.append(Attachment(
            id: attachments.count,
            filename: name,
            mimeType: part.contentType,
            data: part.body,
            contentID: part.contentID,
            isInline: part.disposition?.value == "inline" || (part.contentID != nil && !isAttachment)
        ))
    }

    static func defaultName(_ type: String, index: Int) -> String {
        let ext = type.split(separator: "/").last.map(String.init) ?? "bin"
        return "attachment-\(index + 1).\(ext)"
    }
}
