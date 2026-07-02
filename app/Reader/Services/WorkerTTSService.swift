import Foundation
import ReaderCore

/// The production TTS path (wired in `AppServices`, wrapped by
/// `ChunkingTTSService`): POSTs text to the aiwork Worker's `/tts/aligned` route,
/// which proxies ElevenLabs `with-timestamps` behind the Worker's global RevenueCat
/// gate. The ElevenLabs key stays server-side; the client sends only `X-User-ID`
/// (the RevenueCat appUserID). End-to-end synthesis requires a subscribed user.
final class WorkerTTSService: TTSService {
    enum WorkerError: LocalizedError {
        case subscriptionRequired
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .subscriptionRequired: return "Subscription required"
            case .http(let code): return "TTS failed (\(code))"
            case .badResponse: return "Malformed TTS response"
            }
        }
    }

    private let baseURL: URL
    private let userId: String?
    private let session: URLSession

    /// The production endpoint is a private deployment. `AppServices` injects the real
    /// URL from the `WorkerBaseURL` Info.plist key (set via the gitignored
    /// `Signing.xcconfig`'s `WORKER_HOST`). This committed default is a non-functional
    /// placeholder so a fresh clone still builds.
    init(baseURL: URL = URL(string: "https://your-worker.example.workers.dev")!,
         userId: String?,
         session: URLSession? = nil) {
        self.baseURL = baseURL
        self.userId = userId
        // `/tts/aligned` buffers the WHOLE ElevenLabs `with-timestamps` response
        // server-side, so no bytes reach us until a chunk (up to ~9k chars) is fully
        // synthesized — well past URLSession's default 60s request timeout for long
        // chapters. Use a synthesis-appropriate window so long chapters don't fail
        // with `URLError.timedOut` (which the caller does NOT retry) while ElevenLabs
        // still bills the abandoned generation.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: config)
        }
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        // Normalize once, identically to the tokenizer; the Worker passes text through.
        let text = Normalize.nfkc(request.text)

        var req = URLRequest(url: baseURL.appendingPathComponent("tts/aligned"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userId, !userId.isEmpty { req.setValue(userId, forHTTPHeaderField: "X-User-ID") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": request.model.rawValue,
            "voice_id": request.voice.id,
        ])

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw http.statusCode == 403 ? WorkerError.subscriptionRequired : WorkerError.http(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(TimestampedAudio.self, from: data)
        guard let alignment = decoded.alignment,
              let audio = Data(base64Encoded: decoded.audioBase64) else {
            throw WorkerError.badResponse
        }
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
}
