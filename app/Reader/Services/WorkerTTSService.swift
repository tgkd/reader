import Foundation
import ReaderCore

final class WorkerTTSService: TTSService {
    enum WorkerError: LocalizedError, Equatable {
        case subscriptionRequired
        case allowanceExhausted(remaining: Int, limit: Int)
        case http(Int)
        case badResponse
        case truncatedStream
        case misalignedStream
        case audioAlignmentMismatch(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .subscriptionRequired: return L10n.readerFailedSubscription
            case .allowanceExhausted: return L10n.readerFailedAllowance
            case .http(let code): return "TTS failed (\(code))"
            case .badResponse: return "Malformed TTS response"
            case .truncatedStream: return "Narration ended early"
            case .misalignedStream: return "Narration timings didn't match the text"
            case .audioAlignmentMismatch: return "Narration timings didn't match the audio"
            }
        }
    }

    /// What the Worker says when a subscriber has spent their period's narration.
    ///
    /// A distinct case rather than another `.http(code)`, because the two failures need opposite
    /// responses from the user: 401/403 means buy a subscription, and showing that to someone who
    /// already pays is worse than saying nothing. The status alone is not enough — the Worker
    /// distinguishes several conditions by `code`, so branch on that and treat an unreadable body
    /// as a plain HTTP failure rather than guessing.
    private struct WorkerErrorBody: Decodable {
        struct Payload: Decodable {
            let code: String
            let remaining_characters: Int?
            let limit_characters: Int?
        }
        let error: Payload
    }

    /// Read a failed response's body before deciding what went wrong.
    ///
    /// The body arrives on the same byte stream as audio would, so this is a few lines rather
    /// than a restructuring — but it has to be drained, and it is bounded because a body that
    /// large is not one of ours. Any failure to read or decode falls back to the status code:
    /// an error message is not worth failing differently over.
    private static func failure(status: Int, body: URLSession.AsyncBytes) async -> WorkerError {
        var data = Data()
        do {
            for try await byte in body {
                data.append(byte)
                if data.count > 8_192 { break }
            }
        } catch {
            return .http(status)
        }
        guard let decoded = try? JSONDecoder().decode(WorkerErrorBody.self, from: data) else {
            return .http(status)
        }
        switch decoded.error.code {
        case "narration_allowance_exhausted":
            return .allowanceExhausted(remaining: decoded.error.remaining_characters ?? 0,
                                       limit: decoded.error.limit_characters ?? 0)
        default:
            return .http(status)
        }
    }

    private static let mp3BytesPerSecond = 16_000.0
    private static let alignmentAudioTolerance = 1.0

    private let baseURL: URL
    private let userId: @Sendable () -> String?
    private let session: URLSession
    private let onProgress: (@Sendable (Double) -> Void)?
    private let onChunk: (@Sendable (ContentKey, Data, Alignment) -> Void)?

    init(baseURL: URL = URL(string: "https://api.thetango.org")!,
         userId: @escaping @Sendable () -> String?,
         session: URLSession? = nil,
         onProgress: (@Sendable (Double) -> Void)? = nil,
         onChunk: (@Sendable (ContentKey, Data, Alignment) -> Void)? = nil) {
        self.baseURL = baseURL
        self.userId = userId
        self.onProgress = onProgress
        self.onChunk = onChunk
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
        let text = Normalize.nfkc(request.text)

        var req = URLRequest(url: baseURL.appendingPathComponent("tts/aligned"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userId = userId(), !userId.isEmpty { req.setValue(userId, forHTTPHeaderField: "X-User-ID") }
        var payload: [String: Any] = [
            "text": text,
            "voice_id": request.voice.id,
            "stream": true,
        ]
        if !request.pronunciation.isEmpty {
            payload["pronunciation_rules"] = request.pronunciation.map {
                ["surface": $0.surface, "reading": $0.reading]
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if [401, 403].contains(http.statusCode) { throw WorkerError.subscriptionRequired }
            throw await Self.failure(status: http.statusCode, body: bytes)
        }

        let (audio, alignment) = try await accumulate(bytes, expecting: text.count,
                                                      key: request.cacheKey)
        guard !audio.isEmpty else { throw WorkerError.badResponse }
        guard !alignment.characters.isEmpty,
              alignment.startTimes.count == alignment.characters.count,
              alignment.endTimes.count == alignment.characters.count else {
            throw WorkerError.badResponse
        }
        guard alignment.characters.joined() == text,
              alignment.characters.allSatisfy({ $0.count == 1 }) else {
            throw WorkerError.misalignedStream
        }
        let audioSeconds = Double(audio.count) / Self.mp3BytesPerSecond
        let describedSeconds = alignment.endTimes.last ?? 0
        let delta = audioSeconds - describedSeconds
        guard abs(delta) <= Self.alignmentAudioTolerance else {
            throw WorkerError.audioAlignmentMismatch(seconds: delta)
        }
        return SynthesizedAudio(audio: audio, alignment: alignment, text: text)
    }

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
            onChunk?(key, slice, chunk.alignment
                     ?? Alignment(characters: [], startTimes: [], endTimes: []))
        }

        guard characters.count >= characterCount else { throw WorkerError.truncatedStream }
        return (audio, Alignment(characters: characters, startTimes: startTimes, endTimes: endTimes))
    }
}
