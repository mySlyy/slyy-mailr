import Foundation

/// One content line: NAME;PARAM=value:VALUE (value kept raw; use `text` for TEXT unescaping).
public struct ICalProperty: Hashable, Sendable {
    public var name: String
    public var params: [String: String]
    public var value: String

    public init(_ name: String, _ value: String, params: [String: String] = [:]) {
        self.name = name.uppercased()
        self.value = value
        self.params = params
    }

    /// Unescaped TEXT value.
    public var text: String { ICalText.unescape(value) }

    public func param(_ key: String) -> String? { params[key.uppercased()] }
}

/// A component (VCALENDAR, VEVENT, VTIMEZONE, VALARM ...) with its properties and sub-components.
public final class ICalComponent: @unchecked Sendable {
    public var name: String
    public var properties: [ICalProperty]
    public var components: [ICalComponent]

    public init(_ name: String, properties: [ICalProperty] = [], components: [ICalComponent] = []) {
        self.name = name.uppercased()
        self.properties = properties
        self.components = components
    }

    public func first(_ name: String) -> ICalProperty? {
        let n = name.uppercased()
        return properties.first { $0.name == n }
    }

    public func all(_ name: String) -> [ICalProperty] {
        let n = name.uppercased()
        return properties.filter { $0.name == n }
    }

    public func set(_ prop: ICalProperty) {
        remove(prop.name)
        properties.append(prop)
    }

    public func set(_ name: String, _ value: String, params: [String: String] = [:]) {
        set(ICalProperty(name, value, params: params))
    }

    public func setText(_ name: String, _ value: String?) {
        if let value, !value.isEmpty {
            set(name, ICalText.escape(value))
        } else {
            remove(name)
        }
    }

    public func remove(_ name: String) {
        let n = name.uppercased()
        properties.removeAll { $0.name == n }
    }

    public func children(_ name: String) -> [ICalComponent] {
        let n = name.uppercased()
        return components.filter { $0.name == n }
    }

    public func copy() -> ICalComponent {
        ICalComponent(name, properties: properties, components: components.map { $0.copy() })
    }

    // MARK: Parse / serialise

    /// Parses iCalendar text; returns the first top-level component (normally VCALENDAR).
    public static func parse(_ text: String) -> ICalComponent? {
        // Unfold: CRLF/LF followed by a space or tab continues the previous line.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = raw.first, f == " " || f == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        var stack: [ICalComponent] = []
        var root: ICalComponent?
        for line in lines {
            guard let prop = parseLine(line) else { continue }
            if prop.name == "BEGIN" {
                let c = ICalComponent(prop.value)
                stack.last?.components.append(c)
                stack.append(c)
            } else if prop.name == "END" {
                let c = stack.popLast()
                if stack.isEmpty, root == nil { root = c }
            } else {
                stack.last?.properties.append(prop)
            }
        }
        return root ?? stack.first
    }

    static func parseLine(_ line: String) -> ICalProperty? {
        // Find the first ':' outside quotes.
        var inQuotes = false
        var colon: String.Index?
        for idx in line.indices {
            let ch = line[idx]
            if ch == "\"" { inQuotes.toggle() }
            if ch == ":" && !inQuotes { colon = idx; break }
        }
        guard let colon else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        var segments: [String] = []
        var cur = ""
        inQuotes = false
        for ch in head {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == ";" && !inQuotes { segments.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        segments.append(cur)
        guard let name = segments.first, !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for s in segments.dropFirst() {
            guard let eq = s.firstIndex(of: "=") else { continue }
            params[s[..<eq].uppercased()] = String(s[s.index(after: eq)...])
        }
        return ICalProperty(name, value, params: params)
    }

    public func serialize() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        out += "BEGIN:\(name)\r\n"
        for p in properties {
            var line = p.name
            for (k, v) in p.params.sorted(by: { $0.key < $1.key }) {
                let needsQuote = v.contains(where: { $0 == ":" || $0 == ";" || $0 == "," }) && !v.hasPrefix("\"")
                line += ";\(k)=\(needsQuote ? "\"\(v)\"" : v)"
            }
            line += ":" + p.value
            out += ICalComponent.fold(line)
        }
        for c in components { c.write(to: &out) }
        out += "END:\(name)\r\n"
    }

    /// Folds at 75 octets without splitting UTF-8 sequences.
    static func fold(_ line: String) -> String {
        var out = ""
        var count = 0
        for ch in line {
            let n = String(ch).utf8.count
            if count + n > 75 {
                out += "\r\n "
                count = 1
            }
            out.append(ch)
            count += n
        }
        return out + "\r\n"
    }
}

public enum ICalText {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    public static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n", "N": out.append("\n")
            case ",": out.append(",")
            case ";": out.append(";")
            case "\\": out.append("\\")
            case let other?: out.append(other)
            case nil: break
            }
        }
        return out
    }
}
