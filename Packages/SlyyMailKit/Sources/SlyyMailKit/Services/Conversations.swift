import Foundation

/// Mails that belong together, oldest first. Never empty.
public struct Conversation: Identifiable, Hashable, Sendable {
    public let messages: [MessageSummary]

    public init(messages: [MessageSummary]) {
        precondition(!messages.isEmpty, "a conversation has at least one message")
        self.messages = messages.sorted { ($0.date, $0.uid, $0.folder) < ($1.date, $1.uid, $1.folder) }
    }

    /// The oldest message's id: stable while replies arrive.
    public var id: String { messages[0].id }
    public var latest: MessageSummary { messages[messages.count - 1] }
    public var count: Int { messages.count }
    public var date: Date { latest.date }
    public var isUnread: Bool { messages.contains { !$0.isSeen } }
    public var isFlagged: Bool { messages.contains(where: \.isFlagged) }
    public var hasAttachments: Bool { messages.contains(where: \.hasAttachments) }

    /// Distinct senders, most recent first.
    public var senders: [EmailAddress] {
        var seen = Set<String>()
        return messages.reversed().flatMap(\.from).filter { seen.insert($0.address.lowercased()).inserted }
    }
}

/// Client-side conversation threading (JWZ, https://www.jwz.org/doc/threading.html) on
/// Message-ID, In-Reply-To and References, with a fallback on the normalised subject for replies
/// whose references are missing. Works on any IMAP server and across folders (IMAP THREAD is per mailbox).
public enum Threader {
    /// Groups `messages` (the folder shown) into conversations, newest first. `context` (e.g. the
    /// Sent folder) only joins conversations that already contain one of `messages`; a context mail
    /// with a Message-ID already in `messages` is dropped as a duplicate.
    public static func conversations(_ messages: [MessageSummary], context: [MessageSummary] = []) -> [Conversation] {
        var table: [String: Node] = [:]
        var messageNodes: [Node] = []

        func node(_ id: String) -> Node {
            if let n = table[id] { return n }
            let n = Node()
            table[id] = n
            return n
        }

        // 1. One node per message, keyed by Message-ID (or a private key when it has none).
        for (m, primary) in messages.map({ ($0, true) }) + context.map({ ($0, false) }) {
            let own = m.messageID.flatMap { MessageHeaders.messageIDs($0).first }
            let n: Node
            if let own, let existing = table[own], let first = existing.message {
                // Same Message-ID twice: a context copy is a duplicate, a second copy in the folder joins the first.
                guard primary else { continue }
                n = node("\u{0}" + m.id)
                if first.folder == m.folder { link(parent: existing, child: n) }
            } else {
                n = node(own ?? "\u{0}" + m.id)
            }
            n.message = m
            n.isPrimary = primary
            messageNodes.append(n)
        }

        // 2. Link the References chain, then make the message a child of its last reference
        //    (its own headers beat a parent presumed from another mail's References).
        for n in messageNodes {
            guard let m = n.message else { continue }
            var refs = m.references
            if let irt = m.inReplyTo, refs.last != irt { refs.removeAll { $0 == irt }; refs.append(irt) }
            let own = m.messageID.flatMap { MessageHeaders.messageIDs($0).first }
            refs.removeAll { $0 == own }
            for (p, c) in zip(refs, refs.dropFirst()) { link(parent: node(p), child: node(c)) }
            guard let last = refs.last else { continue }
            let parent = node(last)
            guard parent !== n, !n.isAncestor(of: parent) else { continue }
            n.detach()
            link(parent: parent, child: n)
        }

        // 3. Each root is a tree; keep trees with at least one message.
        var trees: [[Node]] = table.values.filter { $0.parent == nil }.map { $0.subtree.filter { $0.message != nil } }.filter { !$0.isEmpty }
        trees.sort { start($0) < start($1) }

        // 4. Subject fallback: a tree whose first mail is a reply ("Re: x") joins the latest earlier
        //    tree that started as "x"; trees that both start without a reply prefix never merge.
        var originals: [String: [Int]] = [:]
        var replies: [Int] = []
        for (i, t) in trees.enumerated() {
            let subject = first(t).subject
            let key = normalizedSubject(subject)
            guard !key.isEmpty else { continue }
            if isReply(subject) { replies.append(i) } else { originals[key, default: []].append(i) }
        }
        var mergedInto: [Int: Int] = [:]
        for i in replies {
            let key = normalizedSubject(first(trees[i]).subject)
            let candidates = originals[key] ?? []
            if let target = candidates.last(where: { start(trees[$0]) <= start(trees[i]) }) ?? candidates.first {
                mergedInto[i] = target
            } else {
                originals[key] = [i]  // several replies to a mail we do not have: one conversation
            }
        }
        var groups: [Int: [Node]] = [:]
        for (i, t) in trees.enumerated() { groups[mergedInto[i] ?? i, default: []] += t }

        return groups.values
            .filter { $0.contains(where: \.isPrimary) }
            .map { Conversation(messages: $0.compactMap(\.message)) }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Subject without reply/forward prefixes (Re, AW, Fwd, Fw, WG, Antw, SV, VS, Re[2], Re(2)),
    /// whitespace collapsed, lowercased. "" for empty subjects.
    public static func normalizedSubject(_ subject: String) -> String {
        var s = Substring(subject)
        while let next = droppingPrefix(s) { s = next }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// True when the subject starts with a reply or forward prefix.
    public static func isReply(_ subject: String) -> Bool {
        droppingPrefix(Substring(subject)) != nil
    }

    static let prefixes: Set<String> = ["re", "aw", "fwd", "fw", "wg", "antw", "sv", "vs"]

    /// The subject after one leading prefix, or nil when there is none.
    static func droppingPrefix(_ s: Substring) -> Substring? {
        let t = s.drop(while: \.isWhitespace)
        guard let colon = t.prefix(12).firstIndex(of: ":") else { return nil }
        var word = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        if let bracket = word.firstIndex(where: { $0 == "[" || $0 == "(" }),
           word[bracket...].dropFirst().dropLast().allSatisfy(\.isNumber), word.last == "]" || word.last == ")" {
            word = String(word[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        return prefixes.contains(word) ? t[t.index(after: colon)...] : nil
    }

    private static func first(_ tree: [Node]) -> MessageSummary {
        tree.compactMap(\.message).min { ($0.date, $0.uid) < ($1.date, $1.uid) }!
    }

    private static func start(_ tree: [Node]) -> Date { first(tree).date }

    /// Links unless the child already has a parent or the link would close a loop.
    private static func link(parent: Node, child: Node) {
        guard child.parent == nil, parent !== child, !child.isAncestor(of: parent) else { return }
        child.parent = parent
        parent.children.append(child)
    }

    final class Node {
        var message: MessageSummary?
        var isPrimary = false
        weak var parent: Node?
        var children: [Node] = []

        /// True when `self` is `other` or one of its ancestors.
        func isAncestor(of other: Node) -> Bool {
            var x: Node? = other
            while let y = x {
                if y === self { return true }
                x = y.parent
            }
            return false
        }

        func detach() {
            parent?.children.removeAll { $0 === self }
            parent = nil
        }

        var subtree: [Node] { [self] + children.flatMap(\.subtree) }
    }
}
