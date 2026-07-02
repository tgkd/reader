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

    func load(_ services: AppServices) {
        items = services.library.all().map { doc in
            let text = doc.chapters.first?.text ?? ""
            // ContentKey is memoized in AppServices (survives route switches), so a
            // return to the Library doesn't re-hash every first chapter on the main actor.
            let key = services.firstChapterKey(for: doc)
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
        services.invalidateKey(for: document.id)
        load(services)
    }
}
