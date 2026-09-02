import Foundation
import ReaderCore

/// Generated narration on disk: one mp3 per chapter plus a sidecar of its timings, named by
/// `ContentKey`. This is what makes a re-listen free.
///
/// It lives in **Application Support, excluded from backup** — deliberately, and it used to live
/// in Caches. Caches is the directory iOS empties on its own when storage runs low, which is
/// correct for data that can be regenerated and wrong for this: regenerating a chapter costs real
/// money, about $0.20, and once narration is metered it also costs the reader part of an
/// allowance they did not spend. A purge would also quietly break the rule that cached narration
/// plays regardless of entitlement, by deleting audio a lapsed subscriber already paid for.
///
/// The cost of moving is that nothing reclaims this automatically any more — an hour of narration
/// is ~58 MB, a novel several hundred. That is why Settings keeps an explicit size readout and a
/// clear control, and why deleting a book purges its audio: the reclamation is the user's to
/// make, deliberately, rather than the system's to make blindly in the middle of a chapter.
///
/// Backup exclusion is not optional. Without it a few hundred megabytes per book would go into
/// the reader's iCloud backup — a worse problem than the one this move solves.
final class DiskAudioStore: GeneratedAudioStore {
    private let dir: URL
    private let writeLock = NSLock()

    init(dir: URL? = nil) {
        if let dir {
            self.dir = dir
            Self.prepare(dir)
        } else {
            let target = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Narration", isDirectory: true)
            Self.prepare(target)
            if let legacy = Self.legacyCacheDirectory {
                Self.adoptLegacyCache(from: legacy, into: target)
            }
            self.dir = target
        }
    }

    /// Create the directory and keep it out of iCloud and iTunes backups.
    ///
    /// Called again after `clear()`, because removing the directory takes the exclusion with it —
    /// a cleared cache that silently starts backing itself up would be the same bug wearing a
    /// different hat. The flag is set on the directory, which covers everything written inside it.
    private static func prepare(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Move whatever the previous version left in Caches.
    ///
    /// Without this the update that fixes the problem is also the update that deletes everyone's
    /// narration — indistinguishable, from the reader's side, from the purge this exists to
    /// prevent. A move within the same volume is a rename, so a large library costs nothing.
    ///
    /// The old directory is removed only once it is empty. `removeItem` on a directory is
    /// recursive, so clearing it unconditionally would delete exactly the files whose move had
    /// just failed — this function destroying the audio it exists to rescue.
    static func adoptLegacyCache(from legacy: URL, into target: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
        else { return }
        for url in entries {
            let destination = target.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: url)
            } else {
                try? fm.moveItem(at: url, to: destination)
            }
        }
        let left = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        if left.isEmpty { try? fm.removeItem(at: legacy) }
    }

    private static var legacyCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Narration", isDirectory: true)
    }

    /// Whether this store's directory is held out of backup. Read back from the filesystem
    /// rather than remembered, because the answer that matters is the one on disk.
    var isExcludedFromBackup: Bool {
        (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    private struct Sidecar: Codable {
        let text: String
        let alignment: Alignment
        let alignmentSource: AlignmentSource?
    }

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
        return SynthesizedAudio(audio: audio, alignment: side.alignment, text: side.text,
                                alignmentSource: side.alignmentSource ?? .provider)
    }

    func save(_ audio: SynthesizedAudio, for key: ContentKey) {
        guard let side = try? JSONEncoder().encode(Sidecar(text: audio.text, alignment: audio.alignment,
                                                           alignmentSource: audio.alignmentSource)) else { return }
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
        Self.prepare(dir)
    }

    func totalBytes() -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
