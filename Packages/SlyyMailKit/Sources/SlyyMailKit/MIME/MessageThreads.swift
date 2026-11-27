import Foundation

/// One conversation: messages linked by Message-ID / In-Reply-To / References (oldest first).
public struct MessageThread: Identifiable, Hashable, Sendable {
    public var id: String
    public var messages: [MessageSummary]

    public var latest: MessageSummary { messages.last! }
    public var count: Int { messages.count }
    public var subject: String { MessageThreads.baseSubject(messages.first?.subject ?? "") }
    public var unreadCount: Int { messages.filter { !$0.isSeen }.count }
    public var isFlagged: Bool { messages.contains(where: \.isFlagged) }
    public var hasAttachments: Bool { messages.contains(where: \.hasAttachments) }
    public var isInvite: Bool { messages.contains(where: \.isInvite) }
    public var date: Date { latest.date }

    /// Senders in order of first appearance, de-duplicated.
    public func participants(me: String?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in messages {
            guard let a = m.from.first else { continue }
            let key = a.address.lowercased()
            guard seen.insert(key).inserted else { continue }
            if let me, key == me.lowercased() { out.append("Me") } else { out.append(a.name.isEmpty ? a.address : a.name.components(separatedBy: " ").first ?? a.name) }
        }
        return out
    }
}

public enum MessageThreads {
    /// "<a@b> <c@d>" → ["<a@b>", "<c@d>"]
    public static func ids(in header: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inside = false
        for ch in header {
            if ch == "<" { inside = true; current = "<"; continue }
            if ch == ">" && inside { out.append(current + ">"); inside = false; continue }
            if inside && !ch.isWhitespace { current.append(ch) }
        }
        return out
    }

    /// "Re: AW: Fwd: Angebot" → "Angebot"
    public static func baseSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "aw:", "fwd:", "fw:", "wg:", "antw:", "sv:", "vs:"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where s.lowercased().hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            // "Re[2]:" / "Re(2):"
            if let m = s.range(of: #"^(re|aw)\s*[\[\(]\d+[\]\)]\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(m)
                changed = true
            }
        }
        return s
    }

    /// Oldest first; a message that references another sorts after it even when clocks or
    /// second-resolution Date headers say otherwise.
    static func inConversationOrder(_ a: MessageSummary, _ b: MessageSummary) -> Bool {
        if let ida = a.messageID, (b.references ?? []).contains(ida) || b.inReplyTo == ida { return true }
        if let idb = b.messageID, (a.references ?? []).contains(idb) || a.inReplyTo == idb { return false }
        if a.date != b.date { return a.date < b.date }
        return (a.references ?? []).count < (b.references ?? []).count
    }

    /// Groups messages into conversations, newest conversation first.
    /// Links come from Message-ID, In-Reply-To and References; a reply without those headers
    /// joins the conversation with the same base subject (as many clients strip them).
    public static func group(_ messages: [MessageSummary]) -> [MessageThread] {
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: String, _ b: String) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        func key(_ m: MessageSummary) -> String { m.messageID?.lowercased() ?? "uid:\(m.id)" }

        for m in messages {
            let k = key(m)
            if parent[k] == nil { parent[k] = k }
            for ref in (m.references ?? []) + (m.inReplyTo.map { [$0] } ?? []) {
                union(k, ref.lowercased())
            }
        }
        // Subject fallback for replies that carry no threading headers.
        var bySubject: [String: String] = [:]
        for m in messages.sorted(by: { $0.date < $1.date }) {
            let base = baseSubject(m.subject).lowercased()
            guard !base.isEmpty else { continue }
            let k = key(m)
            let isReply = m.subject.count != baseSubject(m.subject).count
            let hasHeaders = !(m.references ?? []).isEmpty || m.inReplyTo != nil
            if let existing = bySubject[base], isReply && !hasHeaders {
                union(k, existing)
            } else if bySubject[base] == nil {
                bySubject[base] = k
            }
        }
        var groups: [String: [MessageSummary]] = [:]
        for m in messages { groups[find(key(m)), default: []].append(m) }
        return groups.map { root, list in
            MessageThread(id: root, messages: list.sorted(by: inConversationOrder))
        }
        .sorted { $0.date > $1.date }
    }
}
