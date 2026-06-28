import SwiftUI
import ReaderCore

/// Backs the Library list: documents plus a per-row "cached" flag (whether
/// offline audio exists) and the status label (未読 / N% / 読了).
@MainActor
@Observable
final class LibraryModel {
    struct Item: Identifiable {
        let document: Document
        let cached: Bool
        var id: Document.ID { document.id }

        var percent: Int { Int((document.progress.fraction * 100).rounded()) }
        var statusLabel: String {
            if percent <= 0 { return L10n.statusUnread }
            if percent >= 100 { return L10n.statusDone }
            return "\(percent)%"
        }
    }

    private(set) var items: [Item] = []

    func load(_ services: AppServices) {
        items = services.library.all().map { doc in
            let text = doc.chapters.first?.text ?? ""
            let key = SynthesisRequest(text: text).cacheKey
            // Offline audio available = already synthesized to disk, OR a bundled
            // fixture exists (DEBUG offline fallback).
            let cached = services.audioStore.has(key) || services.fixtures.hasFixture(for: text)
            return Item(document: doc, cached: cached)
        }
    }
}
