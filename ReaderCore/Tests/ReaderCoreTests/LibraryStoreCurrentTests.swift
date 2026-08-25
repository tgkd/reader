import XCTest
@testable import ReaderCore

final class LibraryStoreCurrentTests: XCTestCase {
    private final class MemoryStore: LibraryStore {
        private var docs: [Document]
        init(_ docs: [Document]) { self.docs = docs }
        func all() -> [Document] { docs }
        func save(_ document: Document) {
            if let i = docs.firstIndex(where: { $0.id == document.id }) { docs[i] = document }
            else { docs.append(document) }
        }
        func remove(_ id: Document.ID) { docs.removeAll { $0.id == id } }
    }

    private func book(charOffset: Int) -> Document {
        Document(title: "t", chapters: [Chapter(text: String(repeating: "あ", count: 100))],
                 progress: ReadingProgress(chapterIndex: 0, charOffset: charOffset))
    }

    func testACopyTakenBeforeASaveGoesStale() {
        let store = MemoryStore([book(charOffset: 20)])
        let listed = store.all()[0]

        var moved = listed
        moved.progress.charOffset = 30
        store.save(moved)

        XCTAssertEqual(listed.progress.charOffset, 20)
        XCTAssertEqual(store.all()[0].progress.charOffset, 30)
    }

    func testCurrentResolvesTheStaleCopyToWhatWasLastSaved() {
        let store = MemoryStore([book(charOffset: 20)])
        let listed = store.all()[0]

        var moved = listed
        moved.progress.charOffset = 30
        store.save(moved)

        XCTAssertEqual(store.current(listed).progress.charOffset, 30)
        XCTAssertEqual(store.current(listed).id, listed.id)
    }

    func testCurrentKeepsTheGivenDocumentWhenTheStoreHasNoSuchRow() {
        let store = MemoryStore([])
        let orphan = book(charOffset: 7)
        XCTAssertEqual(store.current(orphan).progress.charOffset, 7)
        XCTAssertEqual(store.current(orphan).id, orphan.id)
    }
}
