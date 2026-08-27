import XCTest
import ReaderCore
@testable import Reader

final class AudioCacheTests: XCTestCase {
    private struct FakeTTS: TTSService {
        var failOn: String? = nil
        var slowByMillis: UInt64 = 0
        var calls: Counter? = nil
        func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
            calls?.increment()
            if let failOn, request.text.value == failOn { throw FakeError.failed }
            if slowByMillis > 0 { try await Task.sleep(nanoseconds: slowByMillis * 1_000_000) }
            let chars = request.text.value.map(String.init)
            let starts = chars.indices.map(Double.init)
            let ends = chars.indices.map { Double($0 + 1) }
            return SynthesizedAudio(audio: Data(request.text.value.utf8),
                                    alignment: Alignment(characters: chars, startTimes: starts, endTimes: ends),
                                    text: request.text.value)
        }
    }
    private enum FakeError: Error { case failed }

    private final class RuleRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seen: [[PronunciationRule]] = []
        func record(_ rules: [PronunciationRule]) { lock.withLock { seen.append(rules) } }
    }

    private struct RecordingTTS: TTSService {
        let recorder: RuleRecorder
        func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
            recorder.record(request.pronunciation)
            let chars = request.text.value.map(String.init)
            return SynthesizedAudio(
                audio: Data(request.text.value.utf8),
                alignment: Alignment(characters: chars,
                                     startTimes: chars.indices.map(Double.init),
                                     endTimes: chars.indices.map { Double($0 + 1) }),
                text: request.text.value)
        }
    }

    private final class MemoryAudioStore: GeneratedAudioStore, @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: SynthesizedAudio] = [:]
        func load(_ key: ContentKey) -> SynthesizedAudio? { lock.withLock { map[key.value] } }
        func save(_ audio: SynthesizedAudio, for key: ContentKey) { lock.withLock { map[key.value] = audio } }
        func has(_ key: ContentKey) -> Bool { lock.withLock { map[key.value] != nil } }
        func remove(_ key: ContentKey) { lock.withLock { _ = map.removeValue(forKey: key.value) } }
        var count: Int { lock.withLock { map.count } }
    }

    func testDeletingAReimportedCopyKeepsSharedNarration() {
        let text = "吾輩は猫である。"
        let original = Document(title: "book", chapters: [Chapter(text: text)])
        let reimported = Document(title: "book", chapters: [
            Chapter(text: text, sourceReadings: [
                SourceReading(start: 0, length: 1, surface: "吾", reading: "わが")]),
        ])

        XCTAssertEqual(
            AppServices.purgeableTexts(of: original, in: [original, reimported]), [],
            "deleting the stale copy must not reclaim audio the new one still keys to")
        XCTAssertEqual(AppServices.purgeableTexts(of: original, in: [original]),
                       [CanonicalText(text)])
    }

    func testPurgeScopeIsDeduplicatedAndRespectsOtherBooks() {
        let shared = "共有", mine = "固有"
        let doc = Document(title: "a", chapters: [
            Chapter(text: mine), Chapter(text: mine), Chapter(text: shared),
        ])
        let other = Document(title: "b", chapters: [Chapter(text: shared)])
        XCTAssertEqual(AppServices.purgeableTexts(of: doc, in: [doc, other]),
                       [CanonicalText(mine)])
    }

    func testDiskStoreSaveLoadHasRemove() {
        let store = DiskAudioStore()
        let key = SynthesisRequest(text: "ねこ-\(UUID().uuidString)", voice: .shizuka).cacheKey
        XCTAssertFalse(store.has(key))
        XCTAssertNil(store.load(key))

        let audio = SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04]),
                                     alignment: Alignment(characters: ["猫"], startTimes: [0], endTimes: [1]),
                                     text: "猫")
        store.save(audio, for: key)
        XCTAssertTrue(store.has(key))
        let loaded = store.load(key)
        XCTAssertEqual(loaded?.text, "猫")
        XCTAssertEqual(loaded?.audio, audio.audio)
        XCTAssertEqual(loaded?.alignment, audio.alignment)

        store.remove(key)
        XCTAssertFalse(store.has(key))
        XCTAssertNil(store.load(key))
    }

    func testSaveNeverPairsNewAudioWithAStaleSidecar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NarrationTests-\(UUID().uuidString)")
        let store = DiskAudioStore(dir: dir)
        let key = SynthesisRequest(text: "ねこ-\(UUID().uuidString)", voice: .shizuka).cacheKey
        let old = SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04]),
                                   alignment: Alignment(characters: ["旧"], startTimes: [0], endTimes: [1]),
                                   text: "旧")
        store.save(old, for: key)
        XCTAssertTrue(store.has(key))

        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(key.value).mp3"))

        let fresh = SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04, 0x00]),
                                     alignment: Alignment(characters: ["新"], startTimes: [0], endTimes: [2]),
                                     text: "新")
        store.save(fresh, for: key)

        let loaded = store.load(key)
        XCTAssertEqual(loaded?.text, "新")
        XCTAssertEqual(loaded?.alignment, fresh.alignment)
        XCTAssertEqual(loaded?.audio, fresh.audio)
        try? FileManager.default.removeItem(at: dir)
    }

    func testFailedReplacementKeepsThePreviouslyCommittedEntry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NarrationTests-\(UUID().uuidString)")
        let store = DiskAudioStore(dir: dir)
        let key = SynthesisRequest(text: "ねこ-\(UUID().uuidString)", voice: .shizuka).cacheKey
        let old = SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04]),
                                   alignment: Alignment(characters: ["旧"], startTimes: [0], endTimes: [1]),
                                   text: "旧")
        store.save(old, for: key)
        XCTAssertTrue(store.has(key))

        let staged = dir.appendingPathComponent("\(key.value).mp3.staging")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)

        store.save(SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04, 0x00]),
                                    alignment: Alignment(characters: ["新"], startTimes: [0], endTimes: [2]),
                                    text: "新"),
                   for: key)

        XCTAssertTrue(store.has(key), "a failed replacement must not destroy the committed entry")
        let loaded = store.load(key)
        XCTAssertEqual(loaded?.text, "旧")
        XCTAssertEqual(loaded?.alignment, old.alignment)
        XCTAssertEqual(loaded?.audio, old.audio)
        try? FileManager.default.removeItem(at: dir)
    }

    func testClearWipesEverythingAndTotalBytesTracksIt() {
        let store = DiskAudioStore()
        let audio = SynthesizedAudio(audio: Data(count: 4096),
                                     alignment: Alignment(characters: ["あ"], startTimes: [0], endTimes: [1]),
                                     text: "あ")
        let before = store.totalBytes()
        store.save(audio, for: SynthesisRequest(text: "a-\(UUID().uuidString)",
                                               voice: .shizuka).cacheKey)
        store.save(audio, for: SynthesisRequest(text: "b-\(UUID().uuidString)",
                                               voice: .shizuka).cacheKey)
        XCTAssertGreaterThan(store.totalBytes(), before)

        store.clear()
        XCTAssertEqual(store.totalBytes(), 0)
    }

    func testChunkedSynthesisPrunesPerSegmentEntries() async throws {
        let store = MemoryAudioStore()
        let chunking = ChunkingTTSService(inner: FakeTTS(), store: store, maxChars: 5, maxConcurrent: 2)
        let text = "あいうえおかきくけこさしすせそたちつてと"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertGreaterThan(segments.count, 1, "text must split into multiple segments")

        let result = try await chunking.synthesize(SynthesisRequest(text: text, voice: .shizuka))

        XCTAssertEqual(result.text, Normalize.nfkc(text))
        for segment in segments {
            XCTAssertFalse(store.has(SynthesisRequest(text: segment, voice: .shizuka).cacheKey),
                           "segment entry should be pruned after stitch")
        }
        XCTAssertTrue(store.has(SynthesisRequest(text: text, voice: .shizuka).cacheKey),
                      "the whole chapter must be cached before the segments are pruned")
        XCTAssertEqual(store.count, 1)
    }

    func testTheChunkedPathNormalizesTheChapterExactlyOnce() async throws {
        let store = MemoryAudioStore()
        let chunking = ChunkingTTSService(inner: FakeTTS(), store: store,
                                          maxChars: 8, maxConcurrent: 2)
        let text = "ﾊﾞｽに乗った。ﾊﾟﾝを買った。"
        let canonical = Normalize.nfkc(text)
        XCTAssertGreaterThan(Chunker.split(canonical, maxChars: 8).count, 1,
                             "text must split into multiple segments")

        let result = try await chunking.synthesize(SynthesisRequest(text: text, voice: .shizuka))

        XCTAssertEqual(Array(result.text.utf8), Array(canonical.utf8),
                       "compare bytes: String == is canonical equivalence and passes either way")
        XCTAssertTrue(store.has(SynthesisRequest(text: text, voice: .shizuka).cacheKey))
        XCTAssertEqual(store.count, 1)
    }

    func testPurgeLooksUpTheKeyTheReaderWrote() {
        let text = "ﾊﾞｽに乗った。"
        let doc = Document(title: "book", chapters: [Chapter(text: text)])
        let reader = SynthesisRequest(text: text, voice: .shizuka).cacheKey
        let purged = AppServices.purgeableTexts(of: doc, in: [doc]).map {
            SynthesisRequest(canonical: $0, voice: .shizuka).cacheKey
        }
        XCTAssertEqual(purged, [reader],
                       "audio the reader can find must be audio swipe-to-delete can reclaim")
    }

    /// A chapter split across requests must still be read with the book's own readings. Every
    /// segment is a separate synthesis, so rules dropped here are dropped from the narration —
    /// and because pronunciation is not in the cache key, the wrong audio would then be cached
    /// under the right name. Dormant while chapters cap below the request limit; it stops being
    /// dormant the moment either number moves.
    func testChunkedSynthesisCarriesTheBookLexiconIntoEverySegment() async throws {
        let recorder = RuleRecorder()
        let chunking = ChunkingTTSService(inner: RecordingTTS(recorder: recorder),
                                          store: MemoryAudioStore(),
                                          maxChars: 5, maxConcurrent: 2)
        let text = "あいうえおかきくけこさしすせそたちつてと"
        let rules = [PronunciationRule(surface: "甲乙", reading: "こうおつ"),
                     PronunciationRule(surface: "丙丁", reading: "へいてい")]
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertGreaterThan(segments.count, 1, "text must split into multiple segments")

        _ = try await chunking.synthesize(
            SynthesisRequest(text: text, voice: .shizuka, pronunciation: rules))

        XCTAssertEqual(recorder.seen.count, segments.count)
        for sent in recorder.seen {
            XCTAssertEqual(sent, rules, "every segment must carry the whole book's lexicon")
        }
    }

    func testIdenticalSegmentsAreBilledOnce() async throws {
        let store = MemoryAudioStore()
        let calls = Counter()
        let text = "あいう。あいう。あいう。"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertEqual(segments, ["あいう。", "あいう。", "あいう。"])

        let chunking = ChunkingTTSService(inner: FakeTTS(calls: calls), store: store,
                                          maxChars: 5, maxConcurrent: 2)
        let result = try await chunking.synthesize(SynthesisRequest(text: text, voice: .shizuka))

        XCTAssertEqual(calls.value, 1, "identical segments must coalesce into one billed request")
        XCTAssertEqual(result.text, Normalize.nfkc(text))
        XCTAssertEqual(result.alignment.characters.count, Normalize.nfkc(text).count)
        XCTAssertTrue(store.has(SynthesisRequest(text: text, voice: .shizuka).cacheKey))
    }

    func testPartialFailureKeepsCachedSegmentsForRetry() async {
        let store = MemoryAudioStore()
        let text = "あいうえおかきくけこさしすせそ"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertGreaterThanOrEqual(segments.count, 2)

        let chunking = ChunkingTTSService(inner: FakeTTS(failOn: segments.last!),
                                          store: store, maxChars: 5, maxConcurrent: 1)
        do {
            _ = try await chunking.synthesize(SynthesisRequest(text: text, voice: .shizuka))
            XCTFail("synthesis should have thrown on the failing segment")
        } catch {}

        XCTAssertTrue(store.has(SynthesisRequest(text: segments.first!, voice: .shizuka).cacheKey))
        XCTAssertFalse(store.has(SynthesisRequest(text: segments.last!, voice: .shizuka).cacheKey))
    }

    func testConcurrentSiblingsStillCacheWhenAnotherSegmentFails() async {
        let store = MemoryAudioStore()
        let text = "あいうえおかきくけこさしすせそ"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertGreaterThanOrEqual(segments.count, 3)

        let chunking = ChunkingTTSService(inner: FakeTTS(failOn: segments.first!, slowByMillis: 120),
                                          store: store, maxChars: 5, maxConcurrent: 2)
        do {
            _ = try await chunking.synthesize(SynthesisRequest(text: text, voice: .shizuka))
            XCTFail("synthesis should have thrown on the failing segment")
        } catch {}

        XCTAssertTrue(store.has(SynthesisRequest(text: segments[1], voice: .shizuka).cacheKey),
                      "an in-flight sibling must finish and cache — it may already have been billed")
        XCTAssertFalse(store.has(SynthesisRequest(text: segments.first!, voice: .shizuka).cacheKey))
    }

    private func sampleAudio(_ text: String = "あ") -> SynthesizedAudio {
        let chars = text.map(String.init)
        return SynthesizedAudio(
            audio: Data(repeating: 0x55, count: 2_048),
            alignment: Alignment(characters: chars,
                                 startTimes: chars.indices.map(Double.init),
                                 endTimes: chars.indices.map { Double($0 + 1) }),
            text: text)
    }

    /// Narration is paid for, so it must not ride along in the reader's iCloud backup — a novel
    /// is several hundred megabytes. Read the flag back off the filesystem: what this asserts is
    /// the state on disk, not that we remembered to call the setter.
    func testGeneratedAudioIsHeldOutOfBackup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DiskAudioStore(dir: dir)
        store.save(sampleAudio(), for: SynthesisRequest(text: "excluded", voice: .shizuka).cacheKey)

        XCTAssertTrue(store.isExcludedFromBackup)
        XCTAssertEqual(
            try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    /// `clear()` removes the directory, which takes the exclusion with it. A cleared cache that
    /// silently began backing itself up would be the same bug in a different place.
    func testClearingTheCacheDoesNotReadmitItToBackup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DiskAudioStore(dir: dir)
        store.save(sampleAudio(), for: SynthesisRequest(text: "cleared", voice: .shizuka).cacheKey)
        XCTAssertGreaterThan(store.totalBytes(), 0)

        store.clear()

        XCTAssertEqual(store.totalBytes(), 0, "the user's manual clear must actually free the space")
        XCTAssertFalse(store.has(SynthesisRequest(text: "cleared", voice: .shizuka).cacheKey))
        XCTAssertTrue(store.isExcludedFromBackup, "clearing must not re-admit the store to backup")
        // And the store stays usable afterwards rather than needing a relaunch.
        store.save(sampleAudio(), for: SynthesisRequest(text: "after-clear", voice: .shizuka).cacheKey)
        XCTAssertTrue(store.has(SynthesisRequest(text: "after-clear", voice: .shizuka).cacheKey))
    }

    /// The update that moves narration out of Caches must bring the existing narration with it.
    /// Without this the release that fixes the purge is itself a purge, and from the reader's
    /// side the two are indistinguishable.
    func testExistingNarrationSurvivesTheMoveOutOfCaches() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("Caches/Narration", isDirectory: true)
        let target = root.appendingPathComponent("Support/Narration", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        try Data("audio".utf8).write(to: legacy.appendingPathComponent("abc.mp3"))
        try Data("timings".utf8).write(to: legacy.appendingPathComponent("abc.json"))

        DiskAudioStore.adoptLegacyCache(from: legacy, into: target)

        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("abc.mp3")),
                       Data("audio".utf8))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("abc.json").path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "the emptied directory should be gone")
    }

    /// `removeItem` on a directory is recursive, so clearing the old location unconditionally
    /// would delete precisely the files whose move had just failed — this code destroying the
    /// audio it exists to rescue. A file that could not move must still be there to retry.
    func testAFileThatCannotMoveIsNotDeletedInstead() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("Caches/Narration", isDirectory: true)
        let target = root.appendingPathComponent("Support/Narration", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        try Data("audio".utf8).write(to: legacy.appendingPathComponent("abc.mp3"))
        // Make the destination unwritable so the move genuinely fails, which is the only way to
        // reach the branch that used to delete the file instead.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }

        DiskAudioStore.adoptLegacyCache(from: legacy, into: target)

        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("abc.mp3").path),
                       "the move was supposed to fail — otherwise this test proves nothing")
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("abc.mp3").path),
                      "what could not move must survive for the next attempt")
        XCTAssertTrue(fm.fileExists(atPath: legacy.path),
                      "and the directory holding it must not be removed")
    }

    /// Re-running must not clobber audio already in the new location with a stale copy.
    func testAlreadyMigratedAudioIsNotOverwrittenByTheOldCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("Caches/Narration", isDirectory: true)
        let target = root.appendingPathComponent("Support/Narration", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        try Data("old".utf8).write(to: legacy.appendingPathComponent("abc.mp3"))
        try Data("current".utf8).write(to: target.appendingPathComponent("abc.mp3"))

        DiskAudioStore.adoptLegacyCache(from: legacy, into: target)

        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("abc.mp3")),
                       Data("current".utf8))
    }

    /// Nothing to adopt is the normal case on every launch after the first.
    func testMigrationIsAQuietNoOpWhenThereIsNothingToMove() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("Support/Narration", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)

        DiskAudioStore.adoptLegacyCache(
            from: root.appendingPathComponent("Caches/Narration", isDirectory: true), into: target)

        XCTAssertTrue(fm.fileExists(atPath: target.path))
    }
}
