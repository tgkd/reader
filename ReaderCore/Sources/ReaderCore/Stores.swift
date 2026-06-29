import Foundation

/// Persists the user's shelf of documents + reading progress. Base UI uses an
/// in-memory/JSON impl seeded with sample texts; the seam is the same when this
/// becomes a real on-disk store.
public protocol LibraryStore {
    func all() -> [Document]
    func save(_ document: Document)
    func remove(_ id: Document.ID)
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
}
