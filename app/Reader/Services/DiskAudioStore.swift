import Foundation
import ReaderCore

/// Content-addressed on-disk cache of synthesized narration, keyed by
/// `ContentKey` = hash(nfkc(text)+voice+model). Each entry is `<key>.mp3` (audio)
/// + `<key>.json` (the alignment + the exact text it indexes). This is what makes
/// the Worker round-trip a one-time cost: re-reads play from disk, offline.
/// Lives in Caches (the OS may evict under pressure; regenerable).
final class DiskAudioStore: GeneratedAudioStore {
    private let dir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("Narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        // Atomic so two concurrent writers of the same key (e.g. a chapter with two
        // identical segments) can't leave a half-written file behind.
        try? audio.audio.write(to: mp3URL(key), options: .atomic)
        let side = Sidecar(text: audio.text, alignment: audio.alignment)
        if let data = try? JSONEncoder().encode(side) { try? data.write(to: jsonURL(key), options: .atomic) }
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
