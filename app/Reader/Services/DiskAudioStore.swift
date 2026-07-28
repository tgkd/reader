import Foundation
import ReaderCore

/// Content-addressed on-disk cache of synthesized narration, keyed by
/// `ContentKey` = hash(nfkc(text)+voice+model). Each entry is `<key>.mp3` (audio)
/// + `<key>.json` (the alignment + the exact text it indexes). This is what makes
/// the Worker round-trip a one-time cost: re-reads play from disk, offline.
/// Lives in Caches (the OS may evict under pressure; regenerable).
final class DiskAudioStore: GeneratedAudioStore {
    private let dir: URL
    /// Serializes the two-file commit of one entry (see `save`).
    private let writeLock = NSLock()

    /// `dir` defaults to the app's shared narration cache (`Caches/Narration`);
    /// an explicit directory gives a test an isolated store.
    init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    private struct Sidecar: Codable { let text: String; let alignment: Alignment }

    private func mp3URL(_ key: ContentKey) -> URL { dir.appendingPathComponent("\(key.value).mp3") }
    private func jsonURL(_ key: ContentKey) -> URL { dir.appendingPathComponent("\(key.value).json") }

    func has(_ key: ContentKey) -> Bool {
        FileManager.default.fileExists(atPath: mp3URL(key).path)
            && FileManager.default.fileExists(atPath: jsonURL(key).path)
    }

    func load(_ key: ContentKey) -> SynthesizedAudio? {
        guard let audio = try? Data(contentsOf: mp3URL(key)),
              let data = try? Data(contentsOf: jsonURL(key)),
              let side = try? JSONDecoder().decode(Sidecar.self, from: data) else { return nil }
        return SynthesizedAudio(audio: audio, alignment: side.alignment, text: side.text)
    }

    func save(_ audio: SynthesizedAudio, for key: ContentKey) {
        // Encode BEFORE touching disk: a sidecar that can't be encoded must not
        // leave an mp3 with no timings behind.
        guard let side = try? JSONEncoder().encode(Sidecar(text: audio.text, alignment: audio.alignment)) else { return }
        // One writer at a time per store: the mp3 and its sidecar are one entry, and
        // two concurrent writers of the same key (a chapter with two identical
        // segments, a voice demo racing a chapter) hold DIFFERENT generations of the
        // same text — interleaving the two writes would pair one generation's audio
        // with the other's timings, i.e. a silently drifting highlight.
        writeLock.lock()
        defer { writeLock.unlock() }
        // STAGE both halves beside the entry before touching the live pair: a
        // replacement that can't be written (a full disk) must leave the previously
        // committed entry intact, because that entry is paid narration and this is a
        // cache, not a queue — the same key is legitimately re-saved over a good one
        // (`ChunkingTTSService` saves the stitched chapter, then `SynthesisCoordinator`
        // saves it again). Writing straight through would have destroyed it.
        let stagedMP3 = mp3URL(key).appendingPathExtension("staging")
        let stagedJSON = jsonURL(key).appendingPathExtension("staging")
        defer {
            try? FileManager.default.removeItem(at: stagedMP3)
            try? FileManager.default.removeItem(at: stagedJSON)
        }
        do {
            try audio.audio.write(to: stagedMP3, options: .atomic)
            try side.write(to: stagedJSON, options: .atomic)
        } catch {
            return   // nothing published, nothing destroyed
        }
        // COMMIT. The sidecar is this entry's marker — `has` and `load` both require
        // it — so retract it FIRST and publish it LAST. The two files are evicted
        // independently by the OS, so "old sidecar, no mp3" is a real state: moving
        // the mp3 into place without clearing the sidecar first would republish the
        // entry as valid the instant the new audio lands, pairing NEW audio with OLD
        // timings — accepted by `has`, played with a drifting highlight, and enough
        // for `ChunkingTTSService` to prune the paid per-segment entries behind it.
        // Both moves are renames within one directory over bytes already on disk, so
        // the window between them is as small as the filesystem allows; anything
        // interrupted inside it reads as a clean cache miss.
        try? FileManager.default.removeItem(at: jsonURL(key))
        try? FileManager.default.removeItem(at: mp3URL(key))
        do {
            try FileManager.default.moveItem(at: stagedMP3, to: mp3URL(key))
            try FileManager.default.moveItem(at: stagedJSON, to: jsonURL(key))
        } catch {
            // Half an entry is worse than none: drop the pair so the next read misses
            // and regenerates, rather than mixing generations.
            remove(key)
        }
    }

    func remove(_ key: ContentKey) {
        try? FileManager.default.removeItem(at: mp3URL(key))
        try? FileManager.default.removeItem(at: jsonURL(key))
    }

    /// Drop every cached entry by removing and recreating the directory — cheaper
    /// and more thorough than enumerating files.
    func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Sum of all entry sizes on disk, for the Settings cache-size readout.
    func totalBytes() -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
