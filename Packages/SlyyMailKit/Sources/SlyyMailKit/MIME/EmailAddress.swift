import Foundation

public struct EmailAddress: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var address: String

    public var id: String { address.lowercased() }

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    /// "Name <a@b>" or just "a@b".
    public var display: String { name.isEmpty ? address : name }

    /// RFC 5322 form for headers, with the display name quoted/encoded as needed.
    public var headerValue: String {
        guard !name.isEmpty else { return address }
        let encoded = EncodedWord.encodeIfNeeded(name)
        if encoded != name { return "\(encoded) <\(address)>" }
        let needsQuotes = name.contains(where: { "()<>[]:;@\\,.\"".contains($0) })
        let n = needsQuotes ? "\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" : name
        return "\(n) <\(address)>"
    }

    public var isValid: Bool {
        let parts = address.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(" ")
    }

    public var domain: String {
        address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
    }

    /// Parses an address list header ("A <a@x>, \"B, C\" <b@x>, c@x"), decoding encoded words.
    public static func parseList(_ header: String) -> [EmailAddress] {
        var result: [EmailAddress] = []
        var current = ""
        var inQuotes = false
        var depthAngle = 0
        var depthParen = 0
        var escape = false
        for ch in header {
            if escape { current.append(ch); escape = false; continue }
            switch ch {
            case "\\" where inQuotes: escape = true; current.append(ch)
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: depthAngle += 1; current.append(ch)
            case ">" where !inQuotes: depthAngle = max(0, depthAngle - 1); current.append(ch)
            case "(" where !inQuotes: depthParen += 1; current.append(ch)
            case ")" where !inQuotes: depthParen = max(0, depthParen - 1); current.append(ch)
            case ",", ";":
                if inQuotes || depthAngle > 0 || depthParen > 0 {
                    current.append(ch)
                } else {
                    if let a = parseOne(current) { result.append(a) }
                    current = ""
                }
            default: current.append(ch)
            }
        }
        if let a = parseOne(current) { result.append(a) }
        return result
    }

    static func parseOne(_ raw: String) -> EmailAddress? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Group syntax "Team: a@b, c@d;" — we only see the part before ':' on the first item.
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("<"), !s[..<colon].contains("\""), !s[..<colon].contains("@") {
            s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return nil }
        }
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let addr = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            name = unquote(name)
            return EmailAddress(name: EncodedWord.decode(name), address: addr)
        }
        // "a@b (Name)"
        var addr = s
        var name = ""
        if let p = s.firstIndex(of: "("), let q = s.lastIndex(of: ")"), p < q {
            name = String(s[s.index(after: p)..<q])
            addr = String(s[..<p]).trimmingCharacters(in: .whitespaces)
        }
        guard addr.contains("@") else { return nil }
        return EmailAddress(name: EncodedWord.decode(name), address: addr)
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return s }
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

public enum RFC822Date {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
    ]

    private static func formatter(_ f: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = f
        return df
    }

    public static func parse(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing comments like "(CET)".
        if let p = s.firstIndex(of: "(") { s = String(s[..<p]).trimmingCharacters(in: .whitespaces) }
        s = s.replacingOccurrences(of: "  ", with: " ")
        for f in formats {
            if let d = formatter(f).date(from: s) { return d }
        }
        return nil
    }

    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let df = formatter("EEE, dd MMM yyyy HH:mm:ss Z")
        df.timeZone = timeZone
        return df.string(from: date)
    }
}

/// Typing addresses into To / Cc / Bcc: the field's text is the finished entries (chips) joined by ", ",
/// then what is still being typed. Commas, semicolons and line breaks separate entries (not inside quotes or <…>),
/// so a pasted list splits cleanly; a space after a complete address finishes it too.
public enum AddressEntry {
    /// Entries in order, trimmed; the last one is what is being typed (empty after a separator).
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false, angle = 0
        for ch in text {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: angle += 1; current.append(ch)
            case ">" where !inQuotes: angle = max(0, angle - 1); current.append(ch)
            case ",", ";", "\n", "\r":
                // (a `where` here would only guard the last pattern)
                if inQuotes || angle > 0 { current.append(ch) } else { out.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            default: current.append(ch)
            }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// The finished entries (everything but the one being typed), without blanks.
    public static func chips(_ text: String) -> [String] { tokens(text).dropLast().filter { !$0.isEmpty } }

    /// All non-blank entries (for a field that isn't being edited: everything is a chip).
    public static func entries(_ text: String) -> [String] { tokens(text).filter { !$0.isEmpty } }

    public static func join(_ chips: [String], current: String) -> String {
        let done = chips.filter { !$0.isEmpty }
        return done.isEmpty ? current : done.joined(separator: ", ") + ", " + current
    }

    /// The field text after the user changed what is being typed to `value`.
    public static func typing(_ value: String, chips: [String]) -> String {
        let parts = tokens(value)
        var done = chips + parts.dropLast().filter { !$0.isEmpty }
        var current = parts.last ?? ""
        // "anna@x.de " (a space after a complete, plain address) finishes it.
        if value.last == " ", !current.contains("\""), !current.contains("<"), EmailAddress(address: current).isValid {
            done.append(current); current = ""
        } else if parts.count == 1 {
            current = value.hasPrefix(" ") ? String(value.drop(while: { $0 == " " })) : value // keep what is typed as is
        }
        return join(done, current: current)
    }

    /// Finishes what is being typed (Return, leaving the field).
    public static func commit(_ text: String) -> String {
        let all = entries(text)
        return all.isEmpty ? "" : all.joined(separator: ", ") + ", "
    }
}
