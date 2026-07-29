import Foundation
import ReaderCore

/// Carries audio chunks from an in-flight synthesis to whoever is waiting to play
/// it, keyed by `ContentKey`.
///
/// The reader can't simply be handed the stream: `SynthesisCoordinator` owns the
/// request so that leaving and re-entering a chapter re-attaches instead of
/// re-billing, which means the reader listening to a chapter may not be the one
/// that started it. Keying on `ContentKey` — the same identity the cache and the
/// coordinator use — lets a re-entering reader pick up a generation already in
/// progress.
///
/// Chunks are delivered on the main queue because their only consumer mutates
/// `@Observable` reader state.
final class SynthesisStream: @unchecked Sendable {
    /// Incremental, NOT cumulative: the audio bytes and alignment entries new to
    /// this chunk. Cumulative delivery would re-copy the whole chapter on each of
    /// ~1,200 chunks.
    typealias Sink = (Data, Alignment) -> Void

    private let lock = NSLock()
    private var sinks: [String: Sink] = [:]

    /// Only one listener per key: two readers on the same chapter would each be
    /// building their own player from the same bytes, and the later one wins the
    /// cache entry anyway.
    func subscribe(_ key: ContentKey, _ sink: @escaping Sink) {
        lock.lock(); sinks[key.value] = sink; lock.unlock()
    }

    func unsubscribe(_ key: ContentKey) {
        lock.lock(); sinks[key.value] = nil; lock.unlock()
    }

    func publish(_ key: ContentKey, audio: Data, alignment: Alignment) {
        lock.lock()
        let sink = sinks[key.value]
        lock.unlock()
        guard let sink else { return }
        DispatchQueue.main.async { sink(audio, alignment) }
    }
}
