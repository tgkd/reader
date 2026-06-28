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
        // Common case: fits in one request — no chunking, no stitching.
        if segments.count <= 1 { return try await inner.synthesize(request) }

        let ordered = try await synthesizeSegments(segments, voice: request.voice, model: request.model)
        return AlignmentStitcher.stitch(ordered)
    }

    /// Synthesize the segments in order with at most `maxConcurrent` in flight,
    /// assembling the results back into spine order by index.
    private func synthesizeSegments(_ segments: [String], voice: Voice,
                                    model: SynthesisModel) async throws -> [SynthesizedAudio] {
        var results = [SynthesizedAudio?](repeating: nil, count: segments.count)

        try await withThrowingTaskGroup(of: (Int, SynthesizedAudio).self) { group in
            var dispatched = 0
            func dispatchNext() {
                guard dispatched < segments.count else { return }
                let i = dispatched
                let text = segments[i]
                dispatched += 1
                group.addTask { (i, try await self.synthesizeSegment(text, voice: voice, model: model)) }
            }
            // Prime the window, then refill as each task completes.
            for _ in 0..<min(maxConcurrent, segments.count) { dispatchNext() }
            while let (i, audio) = try await group.next() {
                results[i] = audio
                dispatchNext()
            }
        }

        let assembled = results.compactMap { $0 }
        guard assembled.count == segments.count else { throw WorkerTTSService.WorkerError.badResponse }
        return assembled
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
