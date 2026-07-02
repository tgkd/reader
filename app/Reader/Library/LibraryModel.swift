import SwiftUI
import ReaderCore
import struct ReaderCore.Document   // disambiguate from SwiftUI.Document

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

    /// OCR progress for a scanned-PDF import (`completed`, `total`), driving a
    /// determinate banner. `nil` when not importing or for instant (text-layer)
    /// imports. Set on the main actor from the import progress callback.
    var importProgress: (completed: Int, total: Int)?

    /// Cache the (expensive, SHA-256) `ContentKey` per document so reappearing
    /// in the library — which calls `load` each time — doesn't re-hash every
    /// first-chapter text on the main thread. Keyed by id; a doc's first-chapter
    /// text is stable for its lifetime.
    private var keyCache: [Document.ID: ContentKey] = [:]

    func load(_ services: AppServices) {
        items = services.library.all().map { doc in
            let text = doc.chapters.first?.text ?? ""
            let key: ContentKey
            if let cached = keyCache[doc.id] {
                key = cached
            } else {
                key = SynthesisRequest(text: text).cacheKey
                keyCache[doc.id] = key
            }
            // Offline audio available = already synthesized to disk, OR a bundled
            // fixture exists (DEBUG offline fallback).
            let cached = services.audioStore.has(key) || services.fixtures.hasFixture(for: text)
            return Item(document: doc, cached: cached)
        }
    }

    /// Remove a document from the shelf and reclaim its cached narration, then
    /// refresh the list. Backs the row's swipe-to-delete (confirmed in the UI).
    func delete(_ document: Document, _ services: AppServices) {
        services.library.remove(document.id)
        services.purgeAudio(for: document)
        keyCache[document.id] = nil
        load(services)
    }
}
