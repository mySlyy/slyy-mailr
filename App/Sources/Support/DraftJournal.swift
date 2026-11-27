import Foundation
import SlyyMailKit

/// Crash safety for the mail editor: every open draft (new mail, reply, edited draft) is written to disk
/// shortly after each change, and removed when the editor closes normally (sent, saved, discarded).
/// Whatever is left after a crash is reopened on the next launch.
struct DraftJournal {
    let directory: URL

    static let standard: DraftJournal = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return DraftJournal(directory: base.appendingPathComponent("Slyy Mailr", isDirectory: true).appendingPathComponent("Unsent", isDirectory: true))
    }()

    func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    func save(_ draft: ComposeDraft) {
        guard !draft.isEmpty else { return remove(draft.id) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(draft) else { return }
        // Atomic write: a crash mid-write leaves the previous version, never half a file.
        try? data.write(to: url(draft.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// Unsent drafts left behind, newest first.
    func leftovers() -> [ComposeDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { f -> (ComposeDraft, Date)? in
                guard let data = try? Data(contentsOf: f), let d = try? JSONDecoder().decode(ComposeDraft.self, from: data) else { return nil }
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (d, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
