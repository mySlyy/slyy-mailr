import Foundation

/// A From address the user may send as: the account address or an alias on the same mailbox.
public struct SenderIdentity: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var email: String
    /// Empty = use the account signature.
    public var signature: String

    public init(id: UUID = UUID(), name: String = "", email: String, signature: String = "") {
        self.id = id
        self.name = name
        self.email = email
        self.signature = signature
    }

    public var address: EmailAddress { EmailAddress(name: name, address: email) }
}
