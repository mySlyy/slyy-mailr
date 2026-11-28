import Foundation

/// Big mail providers that need more than a normal password: their servers, and where users create an app password.
/// Google (Gmail and Google Workspace) for now; Microsoft 365 follows.
public struct KnownProvider: Sendable, Equatable {
    public enum Kind: String, Sendable { case google }

    public var kind: Kind
    public var name: String
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    /// CalDAV address that works with an app password; empty when the provider allows calendars only through OAuth.
    public var caldavURL: String
    /// Page where the user creates an app password.
    public var appPasswordURL: URL
    /// What must be on before app passwords exist (e.g. 2-Step Verification).
    public var prerequisite: String

    public static let google = KnownProvider(
        kind: .google, name: "Google",
        imap: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls),
        smtp: ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls),
        caldavURL: "",
        appPasswordURL: URL(string: "https://myaccount.google.com/apppasswords")!,
        prerequisite: "2-Step Verification")

    static let googleDomains: Set<String> = ["gmail.com", "googlemail.com"]

    /// By address (gmail.com) or, for own domains on Google Workspace, by MX host.
    public static func detect(email: String, mxHosts: [String] = []) -> KnownProvider? {
        let domain = EmailAddress(address: email).domain.lowercased()
        if googleDomains.contains(domain) { return .google }
        for mx in mxHosts.map({ $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }) {
            if mx.hasSuffix("google.com") || mx.hasSuffix("googlemail.com") { return .google }
        }
        return nil
    }

    /// Account settings for this provider (app-password login).
    public func settings(email: String, displayName: String = "") -> AccountSettings {
        AccountSettings(email: email, displayName: displayName, imap: imap, smtp: smtp, caldavURL: caldavURL)
    }

    /// The provider behind already detected settings (Workspace domains are only known after the MX lookup).
    public static func forSettings(_ s: AccountSettings) -> KnownProvider? {
        if let p = detect(email: s.email) { return p }
        let host = s.imap.host.lowercased()
        return host == google.imap.host || host.hasSuffix(".gmail.com") ? .google : nil
    }

    /// Google Workspace (own domain) rather than a gmail.com address: the admin decides about IMAP and app passwords.
    public static func isWorkspace(_ email: String) -> Bool {
        !googleDomains.contains(EmailAddress(address: email).domain.lowercased())
    }

    /// Does a login error look like "normal password refused, app password needed"?
    // CLEANUP(C10): only tests call it; wire into the Gmail app-password guide on login failure, or remove.
    public static func needsAppPassword(_ serverText: String) -> Bool {
        let t = serverText.lowercased()
        return ["application-specific password", "app password", "web login required", "authenticationfailed", "invalid credentials", "534-5.7.9", "535-5.7.8"]
            .contains { t.contains($0) }
    }
}
