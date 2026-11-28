import Foundation
import SlyyMailKit
import Security

/// Account passwords in the system Keychain (never in UserDefaults or files).
enum Keychain {
    static let service = "ai.slyy.mailr"

    private static func baseQuery(_ account: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
        ]
    }

    static func setPassword(_ password: String, for account: UUID) throws {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func password(for account: UUID) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for account: UUID) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error \(status)" }
    }
}

/// Recipients I've written to or received from, for address autocomplete.
@MainActor
final class ContactsStore {
    private(set) var contacts: [EmailAddress] = []
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Slyy Mailr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("contacts.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([EmailAddress].self, from: data) {
            contacts = list
        }
    }

    func add(_ addresses: [EmailAddress]) {
        var changed = false
        for a in addresses where a.isValid {
            if let i = contacts.firstIndex(where: { $0.id == a.id }) {
                if contacts[i].name.isEmpty && !a.name.isEmpty { contacts[i].name = a.name; changed = true }
            } else {
                contacts.append(a)
                changed = true
            }
        }
        if changed, let data = try? JSONEncoder().encode(contacts) { try? data.write(to: url, options: .atomic) }
    }

    func suggestions(for query: String, limit: Int = 6) -> [EmailAddress] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 1 else { return [] }
        return Array(contacts.filter { $0.address.lowercased().contains(q) || $0.name.lowercased().contains(q) }.prefix(limit))
    }
}
