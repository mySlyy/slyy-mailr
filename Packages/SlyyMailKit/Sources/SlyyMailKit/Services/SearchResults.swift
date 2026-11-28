import Foundation

/// Orders and cleans the server's search hits. IMAP SEARCH matches anywhere (also footers, quotes, HTML),
/// so hits in sender, recipients or subject come first and the rest ("mentioned in the text") after them.
/// Each message is listed once: the same UID twice, or the same Message-ID twice (e.g. a Gmail label copy).
public struct SearchResults: Equatable, Sendable {
    public var direct: [MessageSummary]
    public var mentions: [MessageSummary]

    public var all: [MessageSummary] { direct + mentions }

    public init(query: String, hits: [MessageSummary]) {
        var seenUID = Set<UInt32>(), seenID = Set<String>()
        var unique: [MessageSummary] = []
        for m in hits.sorted(by: { $0.date > $1.date }) {
            guard seenUID.insert(m.uid).inserted else { continue }
            if let id = m.messageID?.lowercased(), !id.isEmpty, !seenID.insert(id).inserted { continue }
            unique.append(m)
        }
        let terms = SearchQuery(query).terms.map(Self.fold)
        func inHeaders(_ m: MessageSummary) -> Bool {
            let fields = ([m.subject] + (m.from + m.to + m.cc).flatMap { [$0.name, $0.address] }).joined(separator: " ")
            let hay = Self.fold(fields)
            return !terms.isEmpty && terms.allSatisfy { hay.contains($0) }
        }
        direct = unique.filter(inHeaders)
        mentions = unique.filter { !inHeaders($0) }
    }

    /// Case and accents ignored; runs of spaces count as one, so a phrase matches across line wraps in headers.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// A search as typed: "quoted text" is one phrase (those words in that order), other words each stand alone;
/// all must match, case ignored. Curly quotes count too; an unclosed quote runs to the end.
public struct SearchQuery: Equatable, Sendable {
    public var terms: [String]

    public init(_ text: String) {
        var terms: [String] = []
        var current = ""
        var inQuotes = false
        func flush() {
            let t = current.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !t.isEmpty { terms.append(t) }
            current = ""
        }
        for ch in text {
            if ch == "\"" || ch == "“" || ch == "”" || ch == "„" {
                flush()
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
        self.terms = terms
    }
}
