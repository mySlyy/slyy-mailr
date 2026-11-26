import Foundation
#if canImport(CoreFoundation) && canImport(Darwin)
import CoreFoundation
#endif

public enum Charset {
    /// Decodes bytes in the named charset; falls back to UTF-8, then Latin-1 (never fails).
    public static func decode(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let enc = encoding(for: name), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func encoding(for name: String) -> String.Encoding? {
        switch name {
        case "utf-8", "utf8", "us-ascii", "ascii", "unicode-1-1-utf-8": return .utf8
        case "iso-8859-1", "latin1", "iso8859-1", "l1": return .isoLatin1
        case "windows-1252", "cp1252", "x-cp1252": return .windowsCP1252
        case "iso-8859-2", "latin2": return .isoLatin2
        case "windows-1250", "cp1250": return .windowsCP1250
        case "windows-1251", "cp1251": return .windowsCP1251
        case "utf-16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "iso-2022-jp": return .iso2022JP
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "euc-jp": return .japaneseEUC
        default:
            #if canImport(Darwin)
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
            #endif
            // ISO-8859-15 differs from Latin-1 only in 8 code points; Latin-1 is a close fallback.
            if name == "iso-8859-15" || name == "latin-9" { return .isoLatin1 }
            return nil
        }
    }
}

public enum QuotedPrintable {
    public static func decode(_ input: Data, header: Bool = false) -> Data {
        var out = Data()
        out.reserveCapacity(input.count)
        let bytes = [UInt8](input)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                // Soft line break: "=\r\n" or "=\n"
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                out.append(b)
                i += 1
            } else if header && b == UInt8(ascii: "_") {
                out.append(0x20)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    /// Encodes text for a body part, lines max 76 chars, CRLF line endings.
    public static func encode(_ text: String) -> String {
        var out = ""
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (li, line) in lines.enumerated() {
            var current = ""
            let bytes = Array(line.utf8)
            for (bi, b) in bytes.enumerated() {
                let isLast = bi == bytes.count - 1
                var piece: String
                if (b == 0x20 || b == 0x09) && isLast {
                    piece = String(format: "=%02X", b)
                } else if (b >= 33 && b <= 126 && b != UInt8(ascii: "=")) || b == 0x20 || b == 0x09 {
                    piece = String(UnicodeScalar(b))
                } else {
                    piece = String(format: "=%02X", b)
                }
                if current.count + piece.count > 75 {
                    out += current + "=\r\n"
                    current = ""
                }
                current += piece
            }
            out += current
            if li < lines.count - 1 { out += "\r\n" }
        }
        return out
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}

public enum Base64Lines {
    /// Base64 with 76-char lines and CRLF, as MIME requires.
    public static func encode(_ data: Data) -> String {
        let s = data.base64EncodedString()
        var lines: [Substring] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
            lines.append(s[i..<j])
            i = j
        }
        return lines.joined(separator: "\r\n")
    }

    public static func decode(_ data: Data) -> Data {
        let cleaned = data.filter { b in
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47
        }
        var s = String(decoding: cleaned, as: UTF8.self)
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s) ?? Data()
    }
}

/// RFC 2047 encoded words in headers ("=?utf-8?Q?Gr=C3=BC=C3=9Fe?=").
public enum EncodedWord {
    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var rest = Substring(input)
        var lastWasEncoded = false
        while let start = rest.range(of: "=?") {
            let before = rest[rest.startIndex..<start.lowerBound]
            guard let decoded = decodeWord(rest[start.lowerBound...]) else {
                result += before + "=?"
                rest = rest[start.upperBound...]
                lastWasEncoded = false
                continue
            }
            // Whitespace between two adjacent encoded words is dropped.
            if !(lastWasEncoded && before.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })) {
                result += before
            }
            result += decoded.text
            rest = rest[decoded.end...]
            lastWasEncoded = true
        }
        result += rest
        return result
    }

    private static func decodeWord(_ s: Substring) -> (text: String, end: Substring.Index)? {
        // =?charset?enc?text?=
        let parts = s.dropFirst(2)
        guard let q1 = parts.firstIndex(of: "?") else { return nil }
        let charset = String(parts[parts.startIndex..<q1]).split(separator: "*").first.map(String.init) ?? ""
        let afterCharset = parts[parts.index(after: q1)...]
        guard let q2 = afterCharset.firstIndex(of: "?") else { return nil }
        let enc = afterCharset[afterCharset.startIndex..<q2].uppercased()
        let textStart = afterCharset.index(after: q2)
        guard let endRange = afterCharset[textStart...].range(of: "?=") else { return nil }
        let text = afterCharset[textStart..<endRange.lowerBound]
        if text.contains(" ") { return nil }
        let raw: Data
        switch enc {
        case "B": raw = Base64Lines.decode(Data(text.utf8))
        case "Q": raw = QuotedPrintable.decode(Data(text.utf8), header: true)
        default: return nil
        }
        return (Charset.decode(raw, charset: charset), endRange.upperBound)
    }

    /// Encodes a header value if it contains non-ASCII characters.
    public static func encodeIfNeeded(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) { return value }
        // Split into chunks so each encoded word stays under 75 chars.
        var words: [String] = []
        var chunk = ""
        for ch in value {
            let candidate = chunk + String(ch)
            if Data(candidate.utf8).base64EncodedString().count > 45 {
                words.append(chunk)
                chunk = String(ch)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}
