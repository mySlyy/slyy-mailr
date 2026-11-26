import Foundation

/// A parsed IMAP data item.
public indirect enum IMAPValue: Equatable, Sendable, CustomStringConvertible {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nil_

    public var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(decoding: d, as: UTF8.self)
        case .nil_, .list: return nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let s): return Data(s.utf8)
        default: return nil
        }
    }

    public var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    public var int: Int? { text.flatMap { Int($0) } }

    public var description: String {
        switch self {
        case .atom(let s): return s
        case .string(let d): return "\"\(String(decoding: d.prefix(80), as: UTF8.self))\""
        case .list(let l): return "(" + l.map(\.description).joined(separator: " ") + ")"
        case .nil_: return "NIL"
        }
    }
}

public enum IMAPResponse: Sendable {
    /// "* ..." — tokens after the asterisk.
    case untagged([IMAPValue])
    /// "A1 OK [CODE] text"
    case tagged(tag: String, status: String, code: [IMAPValue]?, text: String)
    /// "+ text"
    case continuation(String)
}

/// Parses one complete server response (line plus any literals it announced).
public struct IMAPParser {
    private let bytes: [UInt8]
    private var i = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public static func parse(_ raw: Data) -> IMAPResponse {
        var p = IMAPParser(raw)
        return p.response()
    }

    mutating func response() -> IMAPResponse {
        if bytes.first == UInt8(ascii: "+") {
            return .continuation(String(decoding: bytes.dropFirst().drop(while: { $0 == 0x20 }), as: UTF8.self))
        }
        if bytes.first == UInt8(ascii: "*") {
            i = 1
            return .untagged(values())
        }
        let tag = atom()
        skipSpaces()
        let status = atom().uppercased()
        skipSpaces()
        var code: [IMAPValue]?
        if i < bytes.count, bytes[i] == UInt8(ascii: "[") {
            i += 1
            var items: [IMAPValue] = []
            while i < bytes.count, bytes[i] != UInt8(ascii: "]") {
                skipSpaces()
                if bytes[i] == UInt8(ascii: "]") { break }
                items.append(value())
            }
            i += 1
            code = items
            skipSpaces()
        }
        let text = String(decoding: bytes[min(i, bytes.count)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .tagged(tag: tag, status: status, code: code, text: text)
    }

    /// Parses values until end of input. Text after a status code like "OK [..] free text" ends up as atoms.
    mutating func values() -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            if i >= bytes.count || bytes[i] == 0x0D || bytes[i] == 0x0A { break }
            if bytes[i] == UInt8(ascii: "[") {
                // Response code inside an untagged OK/NO/BAD: keep as list
                i += 1
                var items: [IMAPValue] = []
                while i < bytes.count, bytes[i] != UInt8(ascii: "]") {
                    skipSpaces()
                    if i < bytes.count, bytes[i] == UInt8(ascii: "]") { break }
                    items.append(value())
                }
                i += 1
                out.append(.list([.atom("[")] + items))
                continue
            }
            out.append(value())
        }
        return out
    }

    mutating func value() -> IMAPValue {
        skipSpaces()
        guard i < bytes.count else { return .nil_ }
        switch bytes[i] {
        case UInt8(ascii: "("):
            i += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                if i >= bytes.count { break }
                if bytes[i] == UInt8(ascii: ")") { i += 1; break }
                if bytes[i] == 0x0D || bytes[i] == 0x0A { i += 1; continue }
                items.append(value())
            }
            return .list(items)
        case UInt8(ascii: "\""):
            return .string(quoted())
        case UInt8(ascii: "{"):
            return .string(literal())
        case UInt8(ascii: "~"):
            // literal8 (BINARY)
            if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "{") {
                i += 1
                return .string(literal())
            }
            return .atom(atom())
        default:
            let a = atom()
            if a.uppercased() == "NIL" { return .nil_ }
            return .atom(a)
        }
    }

    mutating func skipSpaces() {
        while i < bytes.count, bytes[i] == 0x20 { i += 1 }
    }

    mutating func atom() -> String {
        let start = i
        var bracket = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "[") { bracket += 1 }
            if b == UInt8(ascii: "]") {
                if bracket == 0 { break }
                bracket -= 1
            }
            if bracket == 0 && (b == 0x20 || b == UInt8(ascii: "(") || b == UInt8(ascii: ")") || b == 0x0D || b == 0x0A) {
                // "(" may legitimately follow inside BODY[...] sections; we only stop on it outside brackets
                break
            }
            i += 1
        }
        if i == start, i < bytes.count {
            i += 1 // never loop forever on an unexpected byte
            return String(UnicodeScalar(bytes[start]))
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    mutating func quoted() -> Data {
        i += 1
        var out = Data()
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\\"), i + 1 < bytes.count {
                out.append(bytes[i + 1])
                i += 2
                continue
            }
            if b == UInt8(ascii: "\"") { i += 1; break }
            out.append(b)
            i += 1
        }
        return out
    }

    mutating func literal() -> Data {
        i += 1
        var n = 0
        while i < bytes.count, let d = digit(bytes[i]) {
            n = n * 10 + d
            i += 1
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "+") { i += 1 }
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1 }
        if i < bytes.count, bytes[i] == 0x0D { i += 1 }
        if i < bytes.count, bytes[i] == 0x0A { i += 1 }
        let end = min(i + n, bytes.count)
        let out = Data(bytes[i..<end])
        i = end
        return out
    }

    private func digit(_ b: UInt8) -> Int? {
        (b >= 48 && b <= 57) ? Int(b - 48) : nil
    }

    /// If a line ends with a literal announcement "{123}" / "{123+}", returns 123.
    public static func trailingLiteralLength(_ line: Data) -> Int? {
        guard line.last == UInt8(ascii: "}") else { return nil }
        guard let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = line[(open + 1)..<(line.endIndex - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}

/// IMAP "modified UTF-7" for mailbox names (RFC 3501 5.1.3).
public enum ModifiedUTF7 {
    public static func encode(_ s: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var data = Data()
            for u in pending { data.append(UInt8(u >> 8)); data.append(UInt8(u & 0xFF)) }
            let b64 = data.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "")
            out += "&" + b64 + "-"
            pending.removeAll()
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return out
    }

    public static func decode(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "&" else { out.append(c); continue }
            var b64 = ""
            while let n = it.next(), n != "-" { b64.append(n) }
            if b64.isEmpty { out.append("&"); continue }
            var std = b64.replacingOccurrences(of: ",", with: "/")
            while std.count % 4 != 0 { std += "=" }
            guard let data = Data(base64Encoded: std) else { out += "&" + b64 + "-"; continue }
            var units: [UInt16] = []
            var bytes = [UInt8](data)
            if bytes.count % 2 == 1 { bytes.removeLast() }
            for k in stride(from: 0, to: bytes.count, by: 2) { units.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])) }
            out += String(decoding: units, as: UTF16.self)
        }
        return out
    }
}
