import Foundation
import ReaderCore

final class DiskAudioStore: GeneratedAudioStore {
    private let dir: URL
    private let writeLock = NSLock()

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
        guard let side = try? JSONEncoder().encode(Sidecar(text: audio.text, alignment: audio.alignment)) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
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
            return
        }
        try? FileManager.default.removeItem(at: jsonURL(key))
        try? FileManager.default.removeItem(at: mp3URL(key))
        do {
            try FileManager.default.moveItem(at: stagedMP3, to: mp3URL(key))
            try FileManager.default.moveItem(at: stagedJSON, to: jsonURL(key))
        } catch {
            remove(key)
        }
    }

    func remove(_ key: ContentKey) {
        try? FileManager.default.removeItem(at: mp3URL(key))
        try? FileManager.default.removeItem(at: jsonURL(key))
    }

    func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func totalBytes() -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
