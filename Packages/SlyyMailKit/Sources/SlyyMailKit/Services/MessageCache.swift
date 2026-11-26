import Foundation

/// Offline cache: newest message list per folder (JSON) and message sources (.eml) on disk.
/// Bodies older than `maxAgeDays` are pruned.
public final class MessageCache: @unchecked Sendable {
    public let root: URL
    public let maxAgeDays: Int
    private let lock = NSLock()

    public init(root: URL, maxAgeDays: Int = 30) {
        self.root = root
        self.maxAgeDays = maxAgeDays
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Default location: Application Support/Slyy Mail/Cache.
    public static func standard() -> MessageCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return MessageCache(root: base.appendingPathComponent("Slyy Mail/Cache", isDirectory: true))
    }

    func dir(_ account: UUID, _ folder: String) -> URL {
        let safe = Data(folder.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        let d = root.appendingPathComponent(account.uuidString).appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public func storeSummaries(_ list: [MessageSummary], folder: String, account: UUID) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(list) {
            try? data.write(to: dir(account, folder).appendingPathComponent("summaries.json"), options: .atomic)
        }
    }

    public func summaries(folder: String, account: UUID) -> [MessageSummary] {
        lock.lock(); defer { lock.unlock() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: dir(account, folder).appendingPathComponent("summaries.json")) else { return [] }
        return (try? dec.decode([MessageSummary].self, from: data)) ?? []
    }

    public func storeBody(_ data: Data, uid: UInt32, folder: String, account: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: dir(account, folder).appendingPathComponent("\(uid).eml"), options: .atomic)
    }

    public func body(uid: UInt32, folder: String, account: UUID) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: dir(account, folder).appendingPathComponent("\(uid).eml"))
    }

    public func removeBody(uid: UInt32, folder: String, account: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir(account, folder).appendingPathComponent("\(uid).eml"))
    }

    public func prune() {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for case let url as URL in e where url.pathExtension == "eml" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if mod < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    public func clear(account: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(account.uuidString))
    }
}
