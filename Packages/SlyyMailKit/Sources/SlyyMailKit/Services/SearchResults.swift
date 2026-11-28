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
        let words = Self.words(query)
        func inHeaders(_ m: MessageSummary) -> Bool {
            let fields = ([m.subject] + (m.from + m.to + m.cc).flatMap { [$0.name, $0.address] }).joined(separator: " ")
            let hay = Self.fold(fields)
            return !words.isEmpty && words.allSatisfy { hay.contains($0) }
        }
        direct = unique.filter(inHeaders)
        mentions = unique.filter { !inHeaders($0) }
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    static func words(_ q: String) -> [String] {
        fold(q).split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }
}
