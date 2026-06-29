import Foundation
import UIKit

/// Enhanced OCR path: POSTs each page image to the aiwork Worker's `/pdf/ocr`
/// route, which runs a vision model behind the Worker's global RevenueCat gate.
/// Subscription-gated and opt-in (see `AppServices.ocrRecognizer`). The client
/// sends only `X-User-ID` (the RevenueCat appUserID); the model key stays
/// server-side. Mirrors `WorkerTTSService` for the request/auth shape and
/// `ChunkingTTSService` for bounded concurrency + 429 backoff.
///
/// Transport is per-page base64 JPEG in JSON (there is no R2 binding): small bodies,
/// client-side parallelism, and cheap resume on partial failure.
final class WorkerOCRService: PDFTextRecognizer {
    enum WorkerError: LocalizedError {
        case subscriptionRequired
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .subscriptionRequired: return "Subscription required"
            case .http(let code):       return "OCR failed (\(code))"
            case .badResponse:          return "Malformed OCR response"
            }
        }
    }

    private let baseURL: URL
    private let userId: String?
    private let session: URLSession
    private let maxConcurrent: Int
    private let jpegQuality: CGFloat

    init(baseURL: URL = URL(string: "https://your-worker.example.workers.dev")!,
         userId: String?,
         session: URLSession = .shared,
         maxConcurrent: Int = 2,
         jpegQuality: CGFloat = 0.7) {
        self.baseURL = baseURL
        self.userId = userId
        self.session = session
        self.maxConcurrent = max(1, maxConcurrent)
        self.jpegQuality = jpegQuality
    }

    func recognize(_ images: [CGImage],
                   progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) async throws -> [String] {
        guard !images.isEmpty else { return [] }
        var results = [String](repeating: "", count: images.count)
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var dispatched = 0
            func dispatchNext() {
                guard dispatched < images.count else { return }
                let i = dispatched
                let image = images[i]
                dispatched += 1
                group.addTask { (i, try await self.withBackoff { try await self.recognizePage(image) }) }
            }
            for _ in 0..<min(maxConcurrent, images.count) { dispatchNext() }
            while let (i, text) = try await group.next() {
                results[i] = text
                completed += 1
                progress?(completed, images.count)
                dispatchNext()
            }
        }
        return results
    }

    private func recognizePage(_ image: CGImage) async throws -> String {
        guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: jpegQuality) else {
            throw WorkerError.badResponse
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("pdf/ocr"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userId, !userId.isEmpty { req.setValue(userId, forHTTPHeaderField: "X-User-ID") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "image_base64": jpeg.base64EncodedString(),
        ])

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw http.statusCode == 403 ? WorkerError.subscriptionRequired : WorkerError.http(http.statusCode)
        }

        struct OCRResponse: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(OCRResponse.self, from: data) else {
            throw WorkerError.badResponse
        }
        return decoded.text
    }

    /// Retry on HTTP 429 (rate limited) with exponential backoff (1s, 2s, 4s); any
    /// other error propagates immediately. Same shape as `ChunkingTTSService`.
    private func withBackoff(_ op: () async throws -> String) async throws -> String {
        var delay: UInt64 = 1_000_000_000
        for attempt in 0..<4 {
            do {
                return try await op()
            } catch let error as WorkerError {
                guard case .http(429) = error, attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw WorkerError.http(429)
    }
}
