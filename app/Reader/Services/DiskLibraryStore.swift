import Foundation
import ReaderCore

/// Persists the user's shelf to `Application Support/library.json`. On first run
/// it seeds the starter texts (and writes them through), so the library survives
/// relaunches and reading-progress updates stick. Replaces the in-memory demo
/// store.
final class DiskLibraryStore: LibraryStore {
    private let url: URL
    private var docs: [Document]

    init(starter: [Document]) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("library.json")

        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Document].self, from: data) {
            docs = saved
        } else {
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
        if let data = try? JSONEncoder().encode(docs) { try? data.write(to: url) }
    }
}
