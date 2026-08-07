import Foundation
import ReaderCore

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
            throw [401, 403].contains(http.statusCode)
                ? WorkerError.subscriptionRequired : WorkerError.http(http.statusCode)
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
