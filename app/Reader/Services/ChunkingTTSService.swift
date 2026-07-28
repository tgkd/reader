import Foundation
import ReaderCore

/// Wraps a `TTSService` so a chapter over the ElevenLabs per-request char cap is
/// synthesized in pieces and stitched back into one continuous narration —
/// transparently, so the reader and the on-disk cache still see a single
/// `SynthesizedAudio` keyed by the whole-chapter `ContentKey`. Short chapters pass
/// straight through to the inner service.
///
/// For long chapters it: splits with `Chunker`, synthesizes each segment through
/// the inner service with **bounded concurrency** (the free tier allows ~2 in
/// flight) and **exponential backoff on HTTP 429**, caches each segment by its own
/// `ContentKey` (so a partially-failed batch resumes cheaply on retry), then
/// `AlignmentStitcher.stitch`es the ordered results into the full chapter.
final class ChunkingTTSService: TTSService {
    private let inner: TTSService
    private let store: GeneratedAudioStore?
    private let maxChars: Int
    private let maxConcurrent: Int

    init(inner: TTSService, store: GeneratedAudioStore?,
         maxChars: Int = Chunker.defaultMaxChars, maxConcurrent: Int = 2) {
        self.inner = inner
        self.store = store
        self.maxChars = maxChars
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        let text = Normalize.nfkc(request.text)
        let segments = Chunker.split(text, maxChars: maxChars)
        // Common case: fits in one request — no chunking, no stitching. Still wrap in
        // the 429 backoff so a short chapter (the majority) retries rate limits just
        // like the chunked path, instead of failing on the first 429.
        if segments.count <= 1 { return try await withBackoff { try await self.inner.synthesize(request) } }

        let ordered = try await synthesizeSegments(segments, voice: request.voice, model: request.model)
        let stitched = AlignmentStitcher.stitch(ordered)
        // Durably cache the whole chapter under its own key BEFORE reclaiming the
        // per-segment entries. The caller caches it too, but only after we return —
        // saving here first means a crash in that gap can't leave the chapter with
        // neither its segments nor its whole-chapter entry (all paid work lost).
        store?.save(stitched, for: request.cacheKey)
        // Reclaim the per-segment entries ONLY once the whole-chapter entry is
        // verifiably on disk. `save` can't report failure (disk full, a directory
        // race), and pruning against a save that didn't land would delete every
        // paid segment at once — the whole chapter would have to be re-billed.
        if store?.has(request.cacheKey) != false {
            for segment in segments {
                store?.remove(SynthesisRequest(text: segment, voice: request.voice, model: request.model).cacheKey)
            }
        }
        return stitched
    }

    /// Synthesize the segments in order with at most `maxConcurrent` in flight,
    /// assembling the results back into spine order by index.
    private func synthesizeSegments(_ segments: [String], voice: Voice,
                                    model: SynthesisModel) async throws -> [SynthesizedAudio] {
        // Identical segments (a repeated passage in an oversized chapter) share ONE
        // `ContentKey`: dispatched separately, two of them in the same concurrency
        // window both miss the per-segment cache before either writes it, and the same
        // text is billed twice. Request each DISTINCT text once and fan its result out
        // to every occurrence — which is what the cache would have served anyway.
        var distinct: [String] = []
        var slot: [String: Int] = [:]
        for segment in segments where slot[segment] == nil {
            slot[segment] = distinct.count
            distinct.append(segment)
        }
        var results = [SynthesizedAudio?](repeating: nil, count: distinct.count)
        var failure: Error?

        // A NON-throwing group on purpose: rethrowing out of `group.next()` unwinds
        // the group and cancels the siblings still in flight — segments ElevenLabs
        // may already have generated and billed, whose audio would then never reach
        // the per-segment cache and would be paid for a second time on retry.
        // Collect per-task results instead, let everything already dispatched finish
        // (and cache itself), then propagate the failure.
        await withTaskGroup(of: (Int, Result<SynthesizedAudio, Error>).self) { group in
            var dispatched = 0
            func dispatchNext() {
                // Don't spend on further segments once one has failed — the chapter
                // can't be stitched anyway. In-flight ones still run to completion.
                guard dispatched < distinct.count, failure == nil else { return }
                let i = dispatched
                let text = distinct[i]
                dispatched += 1
                group.addTask {
                    do { return (i, .success(try await self.synthesizeSegment(text, voice: voice, model: model))) }
                    catch { return (i, .failure(error)) }
                }
            }
            // Prime the window, then refill as each task completes.
            for _ in 0..<min(maxConcurrent, distinct.count) { dispatchNext() }
            while let (i, result) = await group.next() {
                switch result {
                case .success(let audio): results[i] = audio
                case .failure(let error): if failure == nil { failure = error }
                }
                dispatchNext()
            }
        }
        if let failure { throw failure }

        let assembled = results.compactMap { $0 }
        guard assembled.count == distinct.count else { throw WorkerTTSService.WorkerError.badResponse }
        // Back to spine order, repeats included.
        let ordered = segments.compactMap { slot[$0].map { assembled[$0] } }
        guard ordered.count == segments.count else { throw WorkerTTSService.WorkerError.badResponse }
        return ordered
    }

    /// One segment: served from the per-segment cache if present, else synthesized
    /// (with 429 backoff) and cached so a later retry / re-read is free.
    private func synthesizeSegment(_ text: String, voice: Voice,
                                   model: SynthesisModel) async throws -> SynthesizedAudio {
        let request = SynthesisRequest(text: text, voice: voice, model: model)
        let key = request.cacheKey
        if let cached = store?.load(key) { return cached }
        let audio = try await withBackoff { try await self.inner.synthesize(request) }
        store?.save(audio, for: key)
        return audio
    }

    /// Retry on HTTP 429 (rate limited) with exponential backoff (1s, 2s, 4s);
    /// any other error propagates immediately.
    private func withBackoff(_ op: () async throws -> SynthesizedAudio) async throws -> SynthesizedAudio {
        var delay: UInt64 = 1_000_000_000
        for attempt in 0..<4 {
            do {
                return try await op()
            } catch let error as WorkerTTSService.WorkerError {
                guard case .http(429) = error, attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw WorkerTTSService.WorkerError.http(429)
    }
}
