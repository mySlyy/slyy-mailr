import Foundation

/// SASL XOAUTH2 initial response (IMAP and SMTP of Google and Microsoft 365).
public enum XOAUTH2 {
    public static func initialResponse(user: String, accessToken: String) -> String {
        Data("user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
    }
}
