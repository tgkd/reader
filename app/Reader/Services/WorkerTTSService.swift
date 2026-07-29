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

        var errorDescription: String? {
            switch self {
            case .subscriptionRequired: return "Subscription required"
            case .http(let code): return "TTS failed (\(code))"
            case .badResponse: return "Malformed TTS response"
            case .truncatedStream: return "Narration ended early"
            }
        }
    }

    private let baseURL: URL
    private let userId: @Sendable () -> String?
    private let session: URLSession
    private let onProgress: (@Sendable (Double) -> Void)?

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
         onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.baseURL = baseURL
        self.userId = userId
        self.onProgress = onProgress
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

        let (audio, alignment) = try await accumulate(bytes, expecting: text.count)
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
                            expecting characterCount: Int) async throws -> (Data, Alignment) {
        var audio = Data()
        var characters: [String] = []
        var startTimes: [Double] = []
        var endTimes: [Double] = []
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let chunk = try? decoder.decode(TimestampedAudio.self, from: data) else { continue }
            if let decoded = Data(base64Encoded: chunk.audioBase64) { audio.append(decoded) }
            if let a = chunk.alignment {
                characters.append(contentsOf: a.characters)
                startTimes.append(contentsOf: a.startTimes)
                endTimes.append(contentsOf: a.endTimes)
            }
            onProgress?(Double(characters.count) / Double(max(characterCount, 1)))
        }

        guard characters.count >= characterCount else { throw WorkerError.truncatedStream }
        return (audio, Alignment(characters: characters, startTimes: startTimes, endTimes: endTimes))
    }
}
