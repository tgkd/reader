import XCTest
import ReaderCore
@testable import Reader

/// Exercises the TTS cache: the on-disk store's round-trip + removal, and
/// `ChunkingTTSService`'s post-stitch pruning of per-segment entries (and that a
/// partially-failed batch keeps its cached segments so a retry resumes cheaply).
final class AudioCacheTests: XCTestCase {

    // MARK: - Test doubles

    /// Deterministic TTS: emits one alignment character per input character, and
    /// (optionally) throws for one exact segment text to simulate a mid-batch fail.
    /// `slowByMillis` delays the successful segments, so a sibling is still in
    /// flight when another segment fails (the request the Worker may already have
    /// billed).
    private struct FakeTTS: TTSService {
        var failOn: String? = nil
        var slowByMillis: UInt64 = 0
        /// Counts the requests that actually reached the service (billed work).
        var calls: Counter? = nil
        func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
            calls?.increment()
            if let failOn, request.text == failOn { throw FakeError.failed }
            if slowByMillis > 0 { try await Task.sleep(nanoseconds: slowByMillis * 1_000_000) }
            let chars = request.text.map(String.init)
            let starts = chars.indices.map(Double.init)
            let ends = chars.indices.map { Double($0 + 1) }
            return SynthesizedAudio(audio: Data(request.text.utf8),
                                    alignment: Alignment(characters: chars, startTimes: starts, endTimes: ends),
                                    text: request.text)
        }
    }
    private enum FakeError: Error { case failed }

    /// Lock-guarded in-memory cache (the task group writes from several tasks).
    private final class MemoryAudioStore: GeneratedAudioStore, @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: SynthesizedAudio] = [:]
        func load(_ key: ContentKey) -> SynthesizedAudio? { lock.withLock { map[key.value] } }
        func save(_ audio: SynthesizedAudio, for key: ContentKey) { lock.withLock { map[key.value] = audio } }
        func has(_ key: ContentKey) -> Bool { lock.withLock { map[key.value] != nil } }
        func remove(_ key: ContentKey) { lock.withLock { _ = map.removeValue(forKey: key.value) } }
        var count: Int { lock.withLock { map.count } }
    }

    // MARK: - DiskAudioStore round-trip

    func testDiskStoreSaveLoadHasRemove() {
        let store = DiskAudioStore()
        // Unique text → unique key, so this never collides with the real cache.
        let key = SynthesisRequest(text: "ねこ-\(UUID().uuidString)").cacheKey
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

    /// The mp3 and its sidecar are one entry: a save that lands on a stale sidecar
    /// (the OS evicts the two files independently, so "old sidecar, no mp3" is a real
    /// state) must never publish NEW audio against OLD timings — that reads as valid
    /// to `has`, plays with a drifting highlight, and is enough for
    /// `ChunkingTTSService` to prune the paid per-segment entries behind it.
    func testSaveNeverPairsNewAudioWithAStaleSidecar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NarrationTests-\(UUID().uuidString)")
        let store = DiskAudioStore(dir: dir)
        let key = SynthesisRequest(text: "ねこ-\(UUID().uuidString)").cacheKey
        let old = SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04]),
                                   alignment: Alignment(characters: ["旧"], startTimes: [0], endTimes: [1]),
                                   text: "旧")
        store.save(old, for: key)
        XCTAssertTrue(store.has(key))

        // Evict the audio, leaving the OLD sidecar behind — the exact partial state
        // the OS can produce.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(key.value).mp3"))

        let fresh = SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04, 0x00]),
                                     alignment: Alignment(characters: ["新"], startTimes: [0], endTimes: [2]),
                                     text: "新")
        store.save(fresh, for: key)

        // Either a clean miss or the fresh pair — never the fresh audio under the old
        // timings.
        let loaded = store.load(key)
        XCTAssertEqual(loaded?.text, "新")
        XCTAssertEqual(loaded?.alignment, fresh.alignment)
        XCTAssertEqual(loaded?.audio, fresh.audio)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A replacement that can't be written must leave the entry already on disk
    /// alone: it is paid narration, and the same key IS legitimately re-saved over a
    /// good entry (`ChunkingTTSService` saves the stitched chapter, then
    /// `SynthesisCoordinator` saves it again). Destroying it on a failed rewrite
    /// costs the user a full re-synthesis.
    func testFailedReplacementKeepsThePreviouslyCommittedEntry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NarrationTests-\(UUID().uuidString)")
        let store = DiskAudioStore(dir: dir)
        let key = SynthesisRequest(text: "ねこ-\(UUID().uuidString)").cacheKey
        let old = SynthesizedAudio(audio: Data([0x49, 0x44, 0x33, 0x04]),
                                   alignment: Alignment(characters: ["旧"], startTimes: [0], endTimes: [1]),
                                   text: "旧")
        store.save(old, for: key)
        XCTAssertTrue(store.has(key))

        // Make the staging path unwritable (a directory) — the stand-in for the disk
        // that can't take the replacement's bytes.
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
        store.save(audio, for: SynthesisRequest(text: "a-\(UUID().uuidString)").cacheKey)
        store.save(audio, for: SynthesisRequest(text: "b-\(UUID().uuidString)").cacheKey)
        XCTAssertGreaterThan(store.totalBytes(), before)

        store.clear()
        XCTAssertEqual(store.totalBytes(), 0)
    }

    // MARK: - ChunkingTTSService pruning

    func testChunkedSynthesisPrunesPerSegmentEntries() async throws {
        let store = MemoryAudioStore()
        let chunking = ChunkingTTSService(inner: FakeTTS(), store: store, maxChars: 5, maxConcurrent: 2)
        let text = "あいうえおかきくけこさしすせそたちつてと"   // 20 chars > maxChars → multi-segment
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertGreaterThan(segments.count, 1, "text must split into multiple segments")

        let result = try await chunking.synthesize(SynthesisRequest(text: text))

        // The stitched whole-chapter text is the lossless concatenation of segments.
        XCTAssertEqual(result.text, Normalize.nfkc(text))
        // Per-segment entries are pruned post-stitch, and the whole chapter is saved
        // durably (before the prune) under its own key — so exactly that one entry
        // remains, never an empty store that lost all the paid segments.
        for segment in segments {
            XCTAssertFalse(store.has(SynthesisRequest(text: segment).cacheKey),
                           "segment entry should be pruned after stitch")
        }
        XCTAssertTrue(store.has(SynthesisRequest(text: text).cacheKey),
                      "the whole chapter must be cached before the segments are pruned")
        XCTAssertEqual(store.count, 1)
    }

    /// Identical segments (a repeated passage in an oversized chapter) resolve to ONE
    /// `ContentKey`. Dispatched separately, two of them in the same concurrency window
    /// both miss the per-segment cache before either writes it — two billed requests
    /// for the same text. Only one may be sent, and the chapter must still stitch with
    /// every occurrence in place.
    func testIdenticalSegmentsAreBilledOnce() async throws {
        let store = MemoryAudioStore()
        let calls = Counter()
        // maxChars 5 packs each "あいう。" unit into its own segment → three identical.
        let text = "あいう。あいう。あいう。"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertEqual(segments, ["あいう。", "あいう。", "あいう。"])

        let chunking = ChunkingTTSService(inner: FakeTTS(calls: calls), store: store,
                                          maxChars: 5, maxConcurrent: 2)
        let result = try await chunking.synthesize(SynthesisRequest(text: text))

        XCTAssertEqual(calls.value, 1, "identical segments must coalesce into one billed request")
        // Lossless: the stitched text is still the whole chapter, repeats included.
        XCTAssertEqual(result.text, Normalize.nfkc(text))
        XCTAssertEqual(result.alignment.characters.count, Normalize.nfkc(text).count)
        XCTAssertTrue(store.has(SynthesisRequest(text: text).cacheKey))
    }

    func testPartialFailureKeepsCachedSegmentsForRetry() async {
        let store = MemoryAudioStore()
        let text = "あいうえおかきくけこさしすせそ"   // 15 chars → ≥2 segments at maxChars 5
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertGreaterThanOrEqual(segments.count, 2)

        // Sequential (maxConcurrent 1) so earlier segments cache before the last fails.
        let chunking = ChunkingTTSService(inner: FakeTTS(failOn: segments.last!),
                                          store: store, maxChars: 5, maxConcurrent: 1)
        do {
            _ = try await chunking.synthesize(SynthesisRequest(text: text))
            XCTFail("synthesis should have thrown on the failing segment")
        } catch {}

        // The completed segment stays cached (cheap resume); the failed one doesn't,
        // and nothing was pruned (no successful stitch).
        XCTAssertTrue(store.has(SynthesisRequest(text: segments.first!).cacheKey))
        XCTAssertFalse(store.has(SynthesisRequest(text: segments.last!).cacheKey))
    }

    /// A segment failing must not cancel the siblings ALREADY in flight: the Worker
    /// may have billed them, so their audio has to reach the per-segment cache even
    /// though the chapter as a whole fails. (Rethrowing straight out of the task
    /// group used to cancel them, forcing a re-bill on retry.)
    func testConcurrentSiblingsStillCacheWhenAnotherSegmentFails() async {
        let store = MemoryAudioStore()
        let text = "あいうえおかきくけこさしすせそ"   // ≥3 segments at maxChars 5
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 5)
        XCTAssertGreaterThanOrEqual(segments.count, 3)

        // The FIRST segment fails immediately while its sibling is still awaiting a
        // (slow) response — exactly the window where cancellation destroyed paid work.
        let chunking = ChunkingTTSService(inner: FakeTTS(failOn: segments.first!, slowByMillis: 120),
                                          store: store, maxChars: 5, maxConcurrent: 2)
        do {
            _ = try await chunking.synthesize(SynthesisRequest(text: text))
            XCTFail("synthesis should have thrown on the failing segment")
        } catch {}

        XCTAssertTrue(store.has(SynthesisRequest(text: segments[1]).cacheKey),
                      "an in-flight sibling must finish and cache — it may already have been billed")
        XCTAssertFalse(store.has(SynthesisRequest(text: segments.first!).cacheKey))
    }
}
