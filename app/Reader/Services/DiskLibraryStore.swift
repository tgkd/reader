import Foundation
import ReaderCore

/// Persists the user's shelf to `Application Support/library.json`. On first run
/// it seeds the starter texts (and writes them through), so the library survives
/// relaunches and reading-progress updates stick. Replaces the in-memory demo
/// store.
final class DiskLibraryStore: LibraryStore {
    private let url: URL
    private var docs: [Document]
    /// Serializes disk writes off the main actor. Saves stay ordered (last write wins)
    /// and, being atomic, never leave a torn file.
    private let writeQueue = DispatchQueue(label: "app.reader.library.write")

    init(starter: [Document]) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("library.json")

        if let data = try? Data(contentsOf: url) {
            if let saved = try? JSONDecoder().decode([Document].self, from: data) {
                docs = saved
            } else {
                // The file exists but won't decode (truncated by a kill mid-write, or a
                // schema it predates). Preserve it aside for possible recovery and start
                // empty WITHOUT writing through — overwriting here would make the loss
                // permanent. The library is the only copy of imported text.
                docs = []
                let backup = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
            }
        } else {
            // No file at all → genuine first run: seed and write the starter through.
            docs = starter
            persist()
        }
    }

    func all() -> [Document] { docs }

    func save(_ document: Document) {
        if let i = docs.firstIndex(where: { $0.id == document.id }) { docs[i] = document }
        else { docs.append(document) }
        persist()
    }

    func remove(_ id: Document.ID) {
        docs.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        // Snapshot (COW, O(1)) then encode+write off the main actor: a progress save
        // fires on pause/background and would otherwise re-encode every book's full
        // text synchronously on the main thread. Atomic so a kill mid-write can't
        // truncate library.json — the only copy of every imported book's text.
        let snapshot = docs
        let url = self.url
        writeQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
