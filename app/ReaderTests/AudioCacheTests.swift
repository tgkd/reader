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
    private struct FakeTTS: TTSService {
        var failOn: String? = nil
        func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
            if let failOn, request.text == failOn { throw FakeError.failed }
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
        // Per-segment entries are pruned post-stitch; the whole chapter is cached by
        // the caller (ReaderModel), not here — so the store is left empty.
        for segment in segments {
            XCTAssertFalse(store.has(SynthesisRequest(text: segment).cacheKey),
                           "segment entry should be pruned after stitch")
        }
        XCTAssertEqual(store.count, 0)
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
}
