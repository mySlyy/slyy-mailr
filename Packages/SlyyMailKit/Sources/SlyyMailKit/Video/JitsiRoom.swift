import Foundation

/// Jitsi Meet rooms on our server (vid.rocket.re-cloud.io runs Jitsi Meet with open rooms, so names must be unguessable).
public enum JitsiRoom {
    public static let defaultServer = "https://vid.rocket.re-cloud.io"
    static let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")

    /// New room URL with a random 20-char slug (~100 bits); never derived from the meeting title.
    public static func newURL(server: String = defaultServer, prefix: String = "slyy") -> URL {
        var rng = SystemRandomNumberGenerator()
        let slug = String((0..<20).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] })
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        return URL(string: "\(base)/\(prefix)-\(slug)")!
    }

    /// URL with display name/email pre-filled for the Jitsi web app (hash config, ignored by other servers).
    public static func joinURL(_ room: URL, displayName: String, email: String) -> URL {
        let name = displayName.isEmpty ? email : displayName
        let enc: (String) -> String = { "%22" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + "%22" }
        var s = room.absoluteString
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        return URL(string: "\(s)#userInfo.displayName=\(enc(name))&userInfo.email=\(enc(email))&config.prejoinConfig.enabled=true") ?? room
    }

    /// Finds a meeting link in free text (description, location) for any Jitsi-style or common meeting host.
    public static func findLink(in text: String, server: String = defaultServer) -> URL? {
        let host = URL(string: server)?.host ?? "vid.rocket.re-cloud.io"
        let pattern = "https?://[^\\s<>\"']+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let urls = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { URL(string: ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>"))) }
        let meetingHosts = [host, "meet.jit.si", "teams.microsoft.com", "zoom.us", "meet.google.com", "whereby.com"]
        return urls.first { u in meetingHosts.contains { u.host?.hasSuffix($0) == true } && u.path.count > 1 }
    }

    /// Text block placed at the top of the event description so every calendar app shows the link.
    public static func descriptionBlock(_ url: URL) -> String {
        "Join video call / Videokonferenz beitreten:\n\(url.absoluteString)\n"
    }

    public static func stripDescriptionBlock(_ text: String) -> String {
        guard text.hasPrefix("Join video call") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
