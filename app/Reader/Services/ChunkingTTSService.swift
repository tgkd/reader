import Foundation
import os
import ReaderCore

final class ChunkingTTSService: TTSService {
    private let inner: TTSService
    private let store: GeneratedAudioStore?
    private let maxChars: @Sendable () -> Int
    private let onChunk: (@Sendable (ContentKey, Data, Alignment) -> Void)?

    init(inner: TTSService, store: GeneratedAudioStore?,
         maxChars: @escaping @Sendable () -> Int = { VoiceCatalog.maxRequestChars() },
         onChunk: (@Sendable (ContentKey, Data, Alignment) -> Void)? = nil) {
        self.inner = inner
        self.store = store
        self.maxChars = maxChars
        self.onChunk = onChunk
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        let text = request.text.value
        let segments = Chunker.split(text, maxChars: maxChars())
        if segments.count <= 1 { return try await withBackoff { try await self.inner.synthesize(request) } }

        WorkerTTSService.log.info("""
            [yomi] chapter.begin parent=\(request.cacheKey.value.prefix(12), privacy: .public) \
            chars=\(text.count, privacy: .public) segments=\(segments.count, privacy: .public) \
            sizes=\(segments.map(\.count).description, privacy: .public)
            """)
        let ordered = try await synthesizeSegments(segments, request: request)
        let stitched = AlignmentStitcher.stitch(ordered)
        store?.save(stitched, for: request.cacheKey)
        if store?.has(request.cacheKey) != false {
            for segment in segments {
                store?.remove(segmentRequest(segment, request).cacheKey)
            }
        }
        return stitched
    }

    private func segmentRequest(_ text: String, _ request: SynthesisRequest) -> SynthesisRequest {
        SynthesisRequest(canonical: CanonicalText(alreadyCanonical: text),
                         voice: request.voice, pronunciation: request.pronunciation)
    }

    private func synthesizeSegments(_ segments: [String],
                                    request: SynthesisRequest) async throws -> [SynthesizedAudio] {
        var ordered: [SynthesizedAudio] = []
        var billed: [String: SynthesizedAudio] = [:]
        var offset = 0.0

        for segment in segments {
            let audio: SynthesizedAudio
            if let done = billed[segment] {
                audio = done
                publish(done.audio, done.alignment, to: request.cacheKey, at: offset)
            } else {
                audio = try await synthesizeSegment(segment, request: request, at: offset,
                                                    index: ordered.count, of: segments.count)
                billed[segment] = audio
            }
            ordered.append(audio)
            offset += audio.stitchAdvance
        }
        return ordered
    }

    private func synthesizeSegment(_ text: String, request: SynthesisRequest,
                                   at offset: Double, index: Int, of total: Int) async throws -> SynthesizedAudio {
        let segment = segmentRequest(text, request)
        // Rules are deliberately absent from the key: a segment cached before the book had a
        // lexicon must still be found, exactly as at chapter level.
        let key = segment.cacheKey
        let cachedAlready = store?.has(key) ?? false
        WorkerTTSService.log.info("""
            [yomi] segment.begin \(index, privacy: .public)/\(total, privacy: .public) \
            key=\(key.value.prefix(12), privacy: .public) chars=\(text.count, privacy: .public) \
            offset=\(offset, privacy: .public) cached=\(cachedAlready, privacy: .public)
            """)
        if let cached = store?.load(key) {
            publish(cached.audio, cached.alignment, to: request.cacheKey, at: offset)
            return cached
        }
        let parent = request.cacheKey
        let sink = onChunk.map { publish -> SynthesisChunkForwarding.Sink in
            { data, alignment in publish(parent, data, alignment.shifted(by: offset)) }
        }
        let audio = try await SynthesisChunkForwarding.$sink.withValue(sink) {
            try await withBackoff { try await self.inner.synthesize(segment) }
        }
        WorkerTTSService.log.info("""
            [yomi] segment.innerReturned \(index, privacy: .public)/\(total, privacy: .public) \
            bytes=\(audio.audio.count, privacy: .public)
            """)
        store?.save(audio, for: key)
        let landed = store?.has(key) ?? false
        WorkerTTSService.log.info("""
            [yomi] segment.cacheSave \(index, privacy: .public)/\(total, privacy: .public) \
            landed=\(landed, privacy: .public)
            """)
        return audio
    }

    private func publish(_ audio: Data, _ alignment: Alignment,
                         to key: ContentKey, at offset: Double) {
        onChunk?(key, audio, alignment.shifted(by: offset))
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
