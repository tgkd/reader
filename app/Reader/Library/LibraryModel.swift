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
            let keys = services.firstChapterKeys(for: doc)
            // Offline audio available = already synthesized to disk (under the current
            // default model or an earlier one, both of which play), OR a bundled
            // fixture exists.
            let cached = keys.contains { services.audioStore.has($0) }
                || services.fixtures.hasFixture(for: text)
            return Item(document: doc, cached: cached)
        }
    }

    /// Remove a document from the shelf and reclaim its cached narration, then
    /// refresh the list. Backs the row's swipe-to-delete (confirmed in the UI).
    /// Returns whether the shelf change was durably committed.
    @discardableResult
    func delete(_ document: Document, _ services: AppServices) async -> Bool {
        services.library.remove(document.id)
        // An explicit deletion must survive a kill before the UI reports it done:
        // the store writes `library.json` off the main actor, so a force-quit in
        // that gap brings the "deleted" book back on the next launch. (The frequent
        // progress saves stay best-effort — this is a user-visible destructive act.)
        let committed = services.library.flush()
        services.invalidateKey(for: document.id)
        // Refresh the shelf BEFORE the purge: `purgeAudio` waits for any in-flight
        // synthesis to unwind (see AppServices), and the row must disappear at once.
        load(services)
        // Reclaim the narration only once the deletion is DURABLE. An uncommitted
        // delete leaves the book in `library.json`, so it returns on the next launch —
        // purging now would strip the audio it was already paid for and force a
        // re-synthesis of a book the user still has.
        if committed { await services.purgeAudio(for: document) }
        return committed
    }
}
