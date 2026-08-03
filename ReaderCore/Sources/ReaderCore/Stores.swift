import Foundation

/// Persists the user's shelf of documents + reading progress. Base UI uses an
/// in-memory/JSON impl seeded with sample texts; the seam is the same when this
/// becomes a real on-disk store.
public protocol LibraryStore {
    func all() -> [Document]
    func save(_ document: Document)
    func remove(_ id: Document.ID)
    /// Wait for every queued mutation to be durably committed, reporting whether
    /// the last write succeeded. A caller that must not report success before the
    /// data survives a kill calls this — import writes the ONLY copy of a book's
    /// text, unlike the frequent progress saves that may stay queued. Defaults to
    /// `true` for impls that commit synchronously (or don't persist at all).
    @discardableResult
    func flush() -> Bool
}

public extension LibraryStore {
    @discardableResult
    func flush() -> Bool { true }
}

/// Caches synthesized audio + alignment keyed by `ContentKey`, so a chapter is
/// synthesized once and re-read for free, offline. A no-op/in-memory impl is
/// fine for base UI; the production impl writes the mp3 + alignment JSON to disk
/// (Phase 5). This is what makes the Worker round-trip (Phase 6) a one-time cost.
public protocol GeneratedAudioStore {
    func load(_ key: ContentKey) -> SynthesizedAudio?
    func save(_ audio: SynthesizedAudio, for key: ContentKey)
    /// Cheap existence check for the library "cached" indicator — must not load
    /// the audio bytes. Defaults to a full `load`; disk impls override.
    func has(_ key: ContentKey) -> Bool
    /// Delete a cached entry (audio + alignment). Used to reclaim space when a
    /// document is deleted, and to prune redundant per-segment entries once a
    /// chunked chapter has been stitched. Idempotent. Defaults to a no-op for
    /// in-memory impls; disk impls override.
    func remove(_ key: ContentKey)
    /// Delete every cached entry (the Settings "clear cached audio" action).
    /// Chapters regenerate on next play. Defaults to a no-op.
    func clear()
    /// Total bytes currently on disk, for the Settings cache-size readout.
    /// Defaults to 0 for impls that don't persist.
    func totalBytes() -> Int
}

public extension GeneratedAudioStore {
    func has(_ key: ContentKey) -> Bool { load(key) != nil }
    func remove(_ key: ContentKey) {}
    func clear() {}
    func totalBytes() -> Int { 0 }

    /// Cached audio for `request`, accepting an entry an EARLIER DEFAULT MODEL wrote
    /// (`SynthesisRequest.legacyCacheKeys`) — the upgrade path for narration the user
    /// has already paid for. The key that actually hit comes back with it, because a
    /// caller evicting a corrupt entry has to evict the one it loaded, not the one it
    /// asked for.
    func loadAllowingLegacyModel(_ request: SynthesisRequest) -> (key: ContentKey, audio: SynthesizedAudio)? {
        for key in request.cacheKeyCandidates {
            if let audio = load(key) { return (key, audio) }
        }
        return nil
    }

    /// Existence check matching `loadAllowingLegacyModel`, for the "is it downloaded?"
    /// indicators — they must answer for the audio that will actually play.
    func hasAllowingLegacyModel(_ request: SynthesisRequest) -> Bool {
        request.cacheKeyCandidates.contains { has($0) }
    }
}
