import SwiftUI
import ReaderCore
import struct ReaderCore.Document

@MainActor
@Observable
final class LibraryModel {
    struct Item: Identifiable {
        let document: Document
        let cached: Bool
        var id: Document.ID { document.id }

        var fraction: Double { document.readFraction }
        var percent: Int { fraction <= 0 ? 0 : max(1, Int((fraction * 100).rounded())) }
        var statusLabel: String {
            if fraction <= 0 { return L10n.statusUnread }
            if fraction >= 1 { return L10n.statusDone }
            return "\(min(99, percent))%"
        }
    }

    private(set) var items: [Item] = []

    func load(_ services: AppServices) {
        items = services.library.all().map { doc in
            let text = doc.chapters.first?.text ?? ""
            let keys = services.firstChapterKeys(for: doc)
            let cached = keys.contains { services.audioStore.has($0) }
                || services.fixtures.hasFixture(for: text)
            return Item(document: doc, cached: cached)
        }
    }

    @discardableResult
    func delete(_ document: Document, _ services: AppServices) async -> Bool {
        services.library.remove(document.id)
        let committed = services.library.flush()
        services.invalidateKey(for: document.id)
        load(services)
        if committed { await services.purgeAudio(for: document) }
        return committed
    }
}
