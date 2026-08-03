import Foundation
import ReaderCore

final class DiskLibraryStore: LibraryStore {
    private let url: URL
    private var docs: [Document]
    private let writeQueue = DispatchQueue(label: "app.reader.library.write")

    init(starter: [Document]) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("library.json")

        if let data = try? Data(contentsOf: url) {
            if let saved = try? JSONDecoder().decode([Document].self, from: data) {
                docs = saved
            } else {
                docs = []
                let backup = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
            }
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

    @discardableResult
    func flush() -> Bool { writeQueue.sync { !writeState.failed } }

    private final class WriteState: @unchecked Sendable { var failed = false }
    private let writeState = WriteState()

    private func persist() {
        let snapshot = docs
        let url = self.url
        let state = writeState
        writeQueue.async {
            do {
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                state.failed = false
            } catch {
                state.failed = true
            }
        }
    }
}
