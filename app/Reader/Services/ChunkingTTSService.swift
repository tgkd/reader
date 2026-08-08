import Foundation
import ReaderCore

final class ChunkingTTSService: TTSService {
    private let inner: TTSService
    private let store: GeneratedAudioStore?
    private let maxChars: Int?
    private let maxConcurrent: Int

    init(inner: TTSService, store: GeneratedAudioStore?,
         maxChars: Int? = nil, maxConcurrent: Int = 2) {
        self.inner = inner
        self.store = store
        self.maxChars = maxChars
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        let text = Normalize.nfkc(request.text)
        let segments = Chunker.split(text, maxChars: maxChars ?? SynthesisLimits.maxRequestChars)
        if segments.count <= 1 { return try await withBackoff { try await self.inner.synthesize(request) } }

        let ordered = try await synthesizeSegments(segments, voice: request.voice,
                                                   pronunciation: request.pronunciation)
        let stitched = AlignmentStitcher.stitch(ordered)
        store?.save(stitched, for: request.cacheKey)
        if store?.has(request.cacheKey) != false {
            for segment in segments {
                store?.remove(SynthesisRequest(text: segment, voice: request.voice).cacheKey)
            }
        }
        return stitched
    }

    private func synthesizeSegments(_ segments: [String],
                                    voice: Voice,
                                    pronunciation: [PronunciationRule]) async throws -> [SynthesizedAudio] {
        var distinct: [String] = []
        var slot: [String: Int] = [:]
        for segment in segments where slot[segment] == nil {
            slot[segment] = distinct.count
            distinct.append(segment)
        }
        var results = [SynthesizedAudio?](repeating: nil, count: distinct.count)
        var failure: Error?

        await withTaskGroup(of: (Int, Result<SynthesizedAudio, Error>).self) { group in
            var dispatched = 0
            func dispatchNext() {
                guard dispatched < distinct.count, failure == nil else { return }
                let i = dispatched
                let text = distinct[i]
                dispatched += 1
                group.addTask {
                    do {
                        return (i, .success(try await self.synthesizeSegment(
                            text, voice: voice, pronunciation: pronunciation)))
                    }
                    catch { return (i, .failure(error)) }
                }
            }
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
        let ordered = segments.compactMap { slot[$0].map { assembled[$0] } }
        guard ordered.count == segments.count else { throw WorkerTTSService.WorkerError.badResponse }
        return ordered
    }

    private func synthesizeSegment(_ text: String, voice: Voice,
                                   pronunciation: [PronunciationRule]) async throws -> SynthesizedAudio {
        let request = SynthesisRequest(text: text, voice: voice, pronunciation: pronunciation)
        // Rules are deliberately absent from the key: a segment cached before the book had a
        // lexicon must still be found, exactly as at chapter level.
        let key = request.cacheKey
        if let cached = store?.load(key) { return cached }
        let audio = try await withBackoff { try await self.inner.synthesize(request) }
        store?.save(audio, for: key)
        return audio
    }

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
