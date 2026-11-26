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
    public var domain: String { address.domain }
}

/// Finds server settings for an email address: Thunderbird-style autoconfig, then common host names.
public enum AutoConfig {
    public static func discover(email: String, session: URLSession = .shared) async -> AccountSettings {
        let domain = EmailAddress(address: email).domain
        let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let candidates = [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(encoded)",
            "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=\(encoded)",
        ]
        for c in candidates {
            guard let url = URL(string: c) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            if let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               var settings = parse(data, email: email) {
                if settings.caldavURL.isEmpty { settings.caldavURL = "https://\(domain)/.well-known/caldav" }
                return settings
            }
        }
        return guess(email: email)
    }

    public static func guess(email: String) -> AccountSettings {
        let domain = EmailAddress(address: email).domain
        return AccountSettings(
            email: email,
            imap: ServerEndpoint(host: "imap.\(domain)", port: 993, security: .tls),
            smtp: ServerEndpoint(host: "smtp.\(domain)", port: 587, security: .startTLS),
            caldavURL: "https://\(domain)/.well-known/caldav"
        )
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
