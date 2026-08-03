import Foundation
import ReaderCore

/// The production TTS path (wired in `AppServices`, wrapped by
/// `ChunkingTTSService`): POSTs text to the aiwork Worker's `/tts/aligned` route,
/// which proxies ElevenLabs `with-timestamps` behind the Worker's global RevenueCat
/// gate. The ElevenLabs key stays server-side; the client sends only `X-User-ID`
/// (the RevenueCat appUserID). End-to-end synthesis requires a subscribed user.
final class WorkerTTSService: TTSService {
    enum WorkerError: LocalizedError, Equatable {
        case subscriptionRequired
        case http(Int)
        case badResponse
        case truncatedStream
        case misalignedStream
        case audioAlignmentMismatch(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .subscriptionRequired: return "Subscription required"
            case .http(let code): return "TTS failed (\(code))"
            case .badResponse: return "Malformed TTS response"
            case .truncatedStream: return "Narration ended early"
            case .misalignedStream: return "Narration timings didn't match the text"
            case .audioAlignmentMismatch: return "Narration timings didn't match the audio"
            }
        }
    }

    /// ElevenLabs' output format is `mp3_44100_128` — constant bitrate, never
    /// overridden by the app or the Worker — so bytes over this is the audio's real
    /// length, not an estimate.
    private static let mp3BytesPerSecond = 16_000.0
    /// How far the alignment's extent may sit from the audio's real length before the
    /// response is unusable, in EITHER direction. Fixed, not proportional: healthy
    /// responses land 55-75 ms out at every length measured (44 s through 578 s), so
    /// this is container overhead rather than duration-proportional uncertainty, and a
    /// percentage rule would license seconds of desync on a long chapter.
    private static let alignmentAudioTolerance = 1.0

    private let baseURL: URL
    private let userId: @Sendable () -> String?
    private let session: URLSession
    private let onProgress: (@Sendable (Double) -> Void)?
    private let onChunk: (@Sendable (ContentKey, Data, Alignment) -> Void)?

    /// `AppServices` injects the URL from the `WorkerBaseURL` Info.plist key
    /// (overridable via the gitignored `Signing.xcconfig`'s `WORKER_HOST`); this
    /// default mirrors its production fallback. `userId` is read per request, not
    /// captured — a purchase/restore that rotates the RevenueCat appUserID after
    /// launch must reach this long-lived service (built once in `AppServices.init`).
    ///
    /// `onProgress` receives the fraction of the chapter's characters that have
    /// actually arrived, as they arrive — a measurement, unlike the reader's
    /// current eased estimate, which exists only because the buffered route
    /// produced no signal at all.
    init(baseURL: URL = URL(string: "https://api.thetango.org")!,
         userId: @escaping @Sendable () -> String?,
         session: URLSession? = nil,
         onProgress: (@Sendable (Double) -> Void)? = nil,
         onChunk: (@Sendable (ContentKey, Data, Alignment) -> Void)? = nil) {
        self.baseURL = baseURL
        self.userId = userId
        self.onProgress = onProgress
        self.onChunk = onChunk
        // Streaming changes what each timeout means. `timeoutIntervalForRequest` is
        // the gap BETWEEN chunks, which is now seconds rather than the whole
        // synthesis, so 300 s is generous. `timeoutIntervalForResource` caps the
        // total — a 3,900-char chapter on v3 measured ~200 s end to end, so 300 s
        // left almost no headroom for a slower one; 900 s does. Timing out here is
        // the expensive failure: `URLError.timedOut` is not retried by the caller,
        // and ElevenLabs bills the generation we abandoned.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 900
            self.session = URLSession(configuration: config)
        }
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        // Normalize once, identically to the tokenizer; the Worker passes text through.
        let text = Normalize.nfkc(request.text)

        var req = URLRequest(url: baseURL.appendingPathComponent("tts/aligned"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userId = userId(), !userId.isEmpty { req.setValue(userId, forHTTPHeaderField: "X-User-ID") }
        // `language_code` and `voice_settings` are forwarded by the Worker when
        // present; an older Worker simply drops them (no error, no behaviour
        // change), so the app can ship ahead of a Worker deploy.
        //
        // NOT sent: `apply_language_text_normalization`. It reads as the obvious fix
        // for Japanese misreadings — and its readings ARE right — but it is an LLM
        // pass that leaks its own reasoning into the spoken output ("Wait, let me
        // redo this properly: …" narrated aloud, 4x the expected duration, one
        // character absorbing 15 s of the alignment). Measured 2026-07-29; do not
        // re-enable without re-measuring.
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": request.model.rawValue,
            "voice_id": request.voice.id,
            "language_code": NarrationSettings.languageCode,
            // Stream, always. On the buffered route ElevenLabs emits nothing until a
            // whole chapter is synthesized and its own edge 524s first (~200 s of
            // work against roughly a 100 s ceiling) — a chapter simply could not be
            // generated. Streaming also turns synthesis progress into a measurement
            // rather than an easing curve.
            "stream": true,
            "voice_settings": [
                "stability": NarrationSettings.stability,
                "similarity_boost": NarrationSettings.similarityBoost,
                "style": NarrationSettings.style,
                "use_speaker_boost": NarrationSettings.useSpeakerBoost,
                "speed": NarrationSettings.speed,
            ],
        ])

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 403 = entitlement rejected; 401 = no X-User-ID reached the Worker (no
            // RevenueCat identity on this install). Both mean "this user can't bill
            // synthesis" — re-lock instead of surfacing a raw status code.
            throw [401, 403].contains(http.statusCode)
                ? WorkerError.subscriptionRequired : WorkerError.http(http.statusCode)
        }

        let (audio, alignment) = try await accumulate(bytes, expecting: text.count,
                                                      key: request.cacheKey)
        // `Data(base64Encoded: "")` SUCCEEDS with zero bytes, so an empty
        // `audio_base64` would otherwise be cached as paid narration: `AVAudioPlayer`
        // then fails to init (a chapter that can never play until the cache is
        // cleared), or the stitched chapter silently loses a segment.
        guard !audio.isEmpty else { throw WorkerError.badResponse }
        // The three alignment arrays are parallel and indexed together downstream
        // (CharTokenMapper → Alignment.startTime/endTime(at:)). Reject a malformed
        // response here rather than letting a length mismatch surface as bad timing.
        guard !alignment.characters.isEmpty,
              alignment.startTimes.count == alignment.characters.count,
              alignment.endTimes.count == alignment.characters.count else {
            throw WorkerError.badResponse
        }
        // The alignment must index THIS text, character for character. `accumulate`'s
        // count check only catches a stream that stopped early; it cannot see a stream
        // that delivered enough characters but not the right ones — an overlapping or
        // repeated chunk, a multi-character element, whitespace the API re-emitted.
        // Such a response is internally consistent, so nothing downstream rejects it:
        // `CharTokenMapper`'s tolerant ±8 resync absorbs the mismatch and expresses it
        // as TIMINGS THAT DRIFT FROM THE AUDIO, and `DiskAudioStore` then caches it as
        // paid narration that plays out of sync forever. Verified to hold on every
        // captured response (v3 and multilingual_v2), so failing here costs nothing and
        // turns a silent, permanent desync into one visible, retryable error.
        // Element-wise, not `joined() == text`: `CharTokenMapper` reads only the FIRST
        // grapheme of each element, so `["AB", ""]` joins to "AB" and passes while the
        // mapper silently loses the "B". One element per character is the contract the
        // fold actually depends on, and every captured response satisfies it.
        guard alignment.characters == text.map(String.init) else {
            throw WorkerError.misalignedStream
        }
        // The alignment must also describe ALL of the audio, not just the right
        // characters. `eleven_v3` sometimes speaks material it returns no timings
        // for — measured on a real chapter (851 chars): timings track the audio to
        // ±0.1 s and then simply stop at 220.00 s, while the mp3 runs to 227.68 s.
        // Every other check passes: the arrays are parallel, monotonic, and the
        // characters reproduce the text exactly.
        //
        // Where that undescribed audio lands decides the damage. At the END the
        // player merely thinks the chapter is short. ANYWHERE ELSE, every timing
        // after it describes audio that now plays later than it says — a highlight
        // running ahead of the narration by a fixed few seconds, from the first
        // second of the chapter, with nothing downstream able to notice. The client
        // cannot repair that; it can only refuse to cache it as paid narration.
        //
        // `mp3_44100_128` is constant bitrate and neither the app nor the Worker
        // overrides it, so bytes/16000 is a measurement, not an estimate (3,643,812
        // bytes → 227.74 s vs ffprobe's 227.68 s). Clean responses land within
        // ~50 ms across 44 s, 121 s, 220 s and 578 s chapters, so this tolerance is
        // two orders of magnitude looser than the noise it has to survive.
        // Checked in BOTH directions, and against a FIXED allowance rather than a
        // proportional one. The observed discrepancy on healthy responses is ~55–75 ms
        // regardless of length (44 s, 121 s, 157 s, 199 s, 220 s, 578 s chapters) —
        // container overhead, not something that grows with duration. A proportional
        // rule would have accepted 11 s of desync on a ten-minute chapter, which is
        // just as unlistenable there as it is in a one-minute one.
        //
        // The other direction matters because `accumulate` silently drops NDJSON lines
        // it cannot decode: a lost audio slice with the later alignment intact yields
        // complete text over incomplete audio, and `ReaderModel`'s
        // `max(timeline.duration, bytes/16000)` would then hide it.
        let audioSeconds = Double(audio.count) / Self.mp3BytesPerSecond
        let describedSeconds = alignment.endTimes.last ?? 0
        let delta = audioSeconds - describedSeconds
        guard abs(delta) <= Self.alignmentAudioTolerance else {
            throw WorkerError.audioAlignmentMismatch(seconds: delta)
        }
        return SynthesizedAudio(audio: audio, alignment: alignment, text: text)
    }

    /// Fold the NDJSON stream into one audio blob and one alignment.
    ///
    /// Each line is a `TimestampedAudio` covering a slice of the chapter, and the
    /// chunk timestamps are ABSOLUTE — verified against the live API, chunk N+1
    /// starts where chunk N ended — so the arrays concatenate directly and no
    /// `AlignmentStitcher` offsetting is involved.
    ///
    /// A truncated stream (connection dropped mid-chapter) therefore yields a
    /// SHORT but internally consistent alignment. `expecting` is the guard: a
    /// partial result must fail rather than be cached as a complete chapter, which
    /// would leave the reader permanently missing its tail with no way to notice.
    private func accumulate(_ bytes: URLSession.AsyncBytes,
                            expecting characterCount: Int,
                            key: ContentKey) async throws -> (Data, Alignment) {
        var audio = Data()
        var characters: [String] = []
        var startTimes: [Double] = []
        var endTimes: [Double] = []
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let chunk = try? decoder.decode(TimestampedAudio.self, from: data) else { continue }
            let slice = Data(base64Encoded: chunk.audioBase64) ?? Data()
            audio.append(slice)
            if let a = chunk.alignment {
                characters.append(contentsOf: a.characters)
                startTimes.append(contentsOf: a.startTimes)
                endTimes.append(contentsOf: a.endTimes)
            }
            onProgress?(Double(characters.count) / Double(max(characterCount, 1)))
            // Hand the chunk on so the reader can play it now rather than after the
            // whole chapter — the reason for streaming in the first place. The
            // accumulation above still runs to completion, so the cached result is
            // identical whether or not anyone is listening.
            onChunk?(key, slice, chunk.alignment
                     ?? Alignment(characters: [], startTimes: [], endTimes: []))
        }

        guard characters.count >= characterCount else { throw WorkerError.truncatedStream }
        return (audio, Alignment(characters: characters, startTimes: startTimes, endTimes: endTimes))
    }
}
