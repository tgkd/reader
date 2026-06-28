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
}

public extension GeneratedAudioStore {
    func has(_ key: ContentKey) -> Bool { load(key) != nil }
}
