import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Everything needed to talk to one mailbox. The password lives in the Keychain, not here.
public struct AccountSettings: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var email: String
    public var displayName: String
    /// Login name; usually the email address.
    public var username: String
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    /// CalDAV server root or principal URL. Empty = calendar disabled.
    public var caldavURL: String
    public var jitsiURL: String
    public var signature: String
    /// Extra From addresses (aliases) on this mailbox. Optional so settings saved by older versions still load.
    public var aliases: [SenderIdentity]?
    /// Address new mails start from (the account address or an alias). nil = the account address.
    public var defaultSender: String?
    /// How Mailr logs in. nil = password (settings saved before 0.3.3).
    public var authMethod: AuthMethod?

    public enum AuthMethod: String, Codable, Sendable {
        case password
        /// Browser sign-in; IMAP/SMTP use XOAUTH2 with a refreshed access token (Microsoft 365 will use this).
        case oauth
    }

    public var usesOAuth: Bool { authMethod == .oauth }

    /// Gmail files every mail sent through its SMTP server in Sent by itself; a second copy would be a duplicate.
    public var serverSavesSent: Bool {
        let h = smtp.host.lowercased()
        return h == "smtp.gmail.com" || h.hasSuffix(".gmail.com")
    }

    public init(id: UUID = UUID(), email: String, displayName: String = "", username: String? = nil, imap: ServerEndpoint, smtp: ServerEndpoint, caldavURL: String = "", jitsiURL: String = JitsiRoom.defaultServer, signature: String = "") {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.username = username ?? email
        self.imap = imap
        self.smtp = smtp
        self.caldavURL = caldavURL
        self.jitsiURL = jitsiURL
        self.signature = signature
    }

    public var address: EmailAddress { EmailAddress(name: displayName, address: email) }

    /// The primary address first, then the aliases.
    public var identities: [SenderIdentity] {
        [SenderIdentity(id: id, name: displayName, email: email, signature: signature)] + (aliases ?? []).filter { EmailAddress(address: $0.email).isValid }
    }

    /// Every address that is "me" (lower-cased), for reply-all, conversations and invites.
    public var myAddresses: Set<String> { Set(identities.map { $0.email.lowercased() }) }

    public func isMine(_ address: String) -> Bool { myAddresses.contains(address.lowercased()) }

    /// The identity new mails are written from.
    public var defaultIdentity: SenderIdentity {
        guard let d = defaultSender?.lowercased() else { return identities[0] }
        return identities.first { $0.email.lowercased() == d } ?? identities[0]
    }

    /// The identity a reply should come from: the address the original was sent to; for mail that names
    /// none of my addresses (lists, Bcc), the default sender.
    public func identity(forReplyTo m: ParsedMessage) -> SenderIdentity {
        var delivered: [String] = []
        for h in ["Delivered-To", "X-Original-To", "Envelope-To"] { delivered += m.headers.all(h).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) } }
        let visible = (m.to + m.cc).map(\.address)
        func match(_ list: [SenderIdentity], in candidates: [String]) -> SenderIdentity? {
            for c in candidates {
                if let id = list.first(where: { $0.email.caseInsensitiveCompare(c) == .orderedSame }) { return id }
            }
            return nil
        }
        // Aliases first: the account address is a delivery target of every mail, so it only counts when the sender wrote to it.
        if let alias = match(Array(identities.dropFirst()), in: delivered + visible) { return alias }
        if let primary = match([identities[0]], in: visible) { return primary }
        return defaultIdentity
    }
    public var domain: String { address.domain }
}

/// Finds server settings for an email address, like Thunderbird does:
/// 1. autoconfig at the mail domain, 2. autoconfig at the domain's MX host, 3. a guess based on the MX host,
/// 4. a guess based on the domain. The CalDAV address is probed, never assumed.
public enum AutoConfig {
    /// MX hosts for a domain, best first. Replaceable for tests.
    nonisolated(unsafe) public static var mxLookup: (String) async -> [String] = { await DNS.mxHosts(for: $0) }
    /// Whether a URL answers like a CalDAV endpoint. Replaceable for tests.
    nonisolated(unsafe) public static var davProbe: (URL, URLSession) async -> Bool = { await AutoConfig.probeDAV($0, session: $1) }

    public static func discover(email: String, session: URLSession = .shared) async -> AccountSettings {
        let domain = EmailAddress(address: email).domain
        // Gmail addresses: known servers, no lookups.
        if let known = KnownProvider.detect(email: email) { return known.settings(email: email) }
        let encoded = email.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? email
        var settings = await fetchFirst([
            "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(encoded)",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=\(encoded)",
        ], email: email, session: session)
        var mxHost: String?
        if settings == nil {
            let mxHosts = await mxLookup(domain)
            mxHost = mxHosts.first
            // Own domains on Google Workspace.
            if let known = KnownProvider.detect(email: email, mxHosts: mxHosts) { return known.settings(email: email) }
            if let mx = mxHost {
                settings = await fetchFirst([
                    "https://\(mx)/mail/config-v1.1.xml?emailaddress=\(encoded)",
                    "https://autoconfig.\(parentDomain(of: mx))/mail/config-v1.1.xml?emailaddress=\(encoded)",
                ], email: email, session: session)
            }
        }
        var result = settings ?? guess(email: email, mailHost: mxHost)
        if result.caldavURL.isEmpty {
            result.caldavURL = await findCalDAV(domain: domain, mailHost: result.imap.host, session: session) ?? ""
        }
        return result
    }

    static func fetchFirst(_ urls: [String], email: String, session: URLSession) async -> AccountSettings? {
        for c in urls {
            guard let url = URL(string: c) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            if let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               let settings = parse(data, email: email) {
                return settings
            }
        }
        return nil
    }

    /// Fallback when no autoconfig exists: the MX host if known, else imap./smtp. + domain.
    public static func guess(email: String, mailHost: String? = nil) -> AccountSettings {
        let domain = EmailAddress(address: email).domain
        return AccountSettings(
            email: email,
            imap: ServerEndpoint(host: mailHost ?? "imap.\(domain)", port: 993, security: .tls),
            smtp: ServerEndpoint(host: mailHost ?? "smtp.\(domain)", port: 587, security: .startTLS),
            caldavURL: ""
        )
    }

    /// First URL that behaves like CalDAV: the domain's well-known URL, the mail host's, then SOGo's path.
    public static func findCalDAV(domain: String, mailHost: String, session: URLSession = .shared) async -> String? {
        var hosts = [domain]
        if mailHost.lowercased() != domain { hosts.append(mailHost) }
        for host in hosts {
            if let u = URL(string: "https://\(host)/.well-known/caldav"), await davProbe(u, session) { return "https://\(host)/" }
        }
        for host in hosts {
            if let u = URL(string: "https://\(host)/SOGo/dav/"), await davProbe(u, session) { return u.absoluteString }
        }
        return nil
    }

    /// Unauthenticated PROPFIND: a DAV server answers 207 or asks for credentials (401); a web site gives 404/405/200.
    static func probeDAV(_ url: URL, session: URLSession) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.timeoutInterval = 8
        guard let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 207 || http.statusCode == 401
    }

    /// "mail.mc1.example.de" → "example.de" (good enough for autoconfig.<domain> lookups).
    static func parentDomain(of host: String) -> String {
        let parts = host.split(separator: ".")
        return parts.suffix(2).joined(separator: ".")
    }

    /// Parses a Thunderbird autoconfig document.
    public static func parse(_ data: Data, email: String) -> AccountSettings? {
        let doc = XMLTree.parse(data)
        guard let provider = doc?.first("emailProvider") else { return nil }
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        let domain = EmailAddress(address: email).domain
        func endpoint(_ node: XMLTree.Node) -> (ServerEndpoint, String)? {
            guard let host = node.first("hostname")?.text, let port = node.first("port").flatMap({ Int($0.text) }) else { return nil }
            let sock = node.first("socketType")?.text.uppercased() ?? "SSL"
            let security: ConnectionSecurity = sock == "STARTTLS" ? .startTLS : sock == "PLAIN" ? .plain : .tls
            let user = (node.first("username")?.text ?? "%EMAILADDRESS%")
                .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
                .replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
                .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
            let h = host.replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
            return (ServerEndpoint(host: h, port: port, security: security), user)
        }
        let incoming = provider.all("incomingServer").first { $0.attributes["type"] == "imap" && endpoint($0)?.0.security != .plain }
            ?? provider.all("incomingServer").first { $0.attributes["type"] == "imap" }
        let outgoing = provider.all("outgoingServer").first { $0.attributes["type"] == "smtp" && endpoint($0)?.0.security != .plain }
            ?? provider.all("outgoingServer").first { $0.attributes["type"] == "smtp" }
        guard let i = incoming.flatMap(endpoint), let o = outgoing.flatMap(endpoint) else { return nil }
        return AccountSettings(email: email, username: i.1, imap: i.0, smtp: o.0)
    }
}

/// Tiny DOM over XMLParser; namespace prefixes are stripped from element names.
public enum XMLTree {
    public final class Node {
        public let name: String
        public var attributes: [String: String]
        public var children: [Node] = []
        public var text: String = ""
        weak var parent: Node?

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        /// First descendant (depth-first) with this local name.
        public func first(_ name: String) -> Node? {
            for c in children {
                if c.name == name { return c }
                if let hit = c.first(name) { return hit }
            }
            return nil
        }

        /// All descendants with this local name.
        public func all(_ name: String) -> [Node] {
            var out: [Node] = []
            for c in children {
                if c.name == name { out.append(c) }
                out += c.all(name)
            }
            return out
        }

        /// Direct children with this local name.
        public func childrenNamed(_ name: String) -> [Node] {
            children.filter { $0.name == name }
        }
    }

    public static func parse(_ data: Data) -> Node? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.root
    }

    final class Builder: NSObject, XMLParserDelegate {
        let root = Node(name: "#document", attributes: [:])
        var current: Node

        override init() {
            current = root
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let n = Node(name: local, attributes: attributeDict)
            n.parent = current
            current.children.append(n)
            current = n
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            current.text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            current = current.parent ?? root
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            current.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            current.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
