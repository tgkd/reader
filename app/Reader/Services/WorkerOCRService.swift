import CryptoKit
import Foundation
import UIKit

struct OCRPageCache {
    let dir: URL

    static func standard() -> OCRPageCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("OCR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return OCRPageCache(dir: dir)
    }

    static func digest(of payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    func text(for digest: String) -> String? {
        try? String(contentsOf: url(for: digest), encoding: .utf8)
    }

    func store(_ text: String, for digest: String) {
        try? Data(text.utf8).write(to: url(for: digest), options: .atomic)
    }

    private func url(for digest: String) -> URL {
        dir.appendingPathComponent("\(digest).txt")
    }
}

actor OCRInFlightPages {
    private var tasks: [String: Task<String, Error>] = [:]

    func text(for digest: String,
              cached: @Sendable () -> String?,
              work: @Sendable @escaping () async throws -> String) async throws -> String {
        if let running = tasks[digest] { return try await running.value }
        if let hit = cached() { return hit }
        let task = Task { try await work() }
        tasks[digest] = task
        defer { if tasks[digest] == task { tasks[digest] = nil } }
        return try await task.value
    }
}

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
    private let cache: OCRPageCache?
    private let inFlight: OCRInFlightPages

    init(baseURL: URL = URL(string: "https://api.thetango.org")!,
         userId: String?,
         session: URLSession = .shared,
         maxConcurrent: Int = 2,
         jpegQuality: CGFloat = 0.7,
         cache: OCRPageCache? = .standard(),
         inFlight: OCRInFlightPages = OCRInFlightPages()) {
        self.baseURL = baseURL
        self.userId = userId
        self.session = session
        self.maxConcurrent = max(1, maxConcurrent)
        self.jpegQuality = jpegQuality
        self.cache = cache
        self.inFlight = inFlight
    }

    func recognize(_ images: [CGImage],
                   progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) async throws -> [String] {
        guard !images.isEmpty else { return [] }
        var results = [String](repeating: "", count: images.count)
        var completed = 0
        var failure: Error?
        var owner: [String: Int] = [:]
        var duplicates: [(index: Int, digest: String)] = []

        await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            var next = 0
            func dispatchNext() {
                while next < images.count, failure == nil {
                    let i = next
                    next += 1
                    guard let jpeg = UIImage(cgImage: images[i]).jpegData(compressionQuality: jpegQuality) else {
                        failure = WorkerError.badResponse
                        return
                    }
                    let digest = OCRPageCache.digest(of: jpeg)
                    if let cached = cache?.text(for: digest) {
                        results[i] = cached
                        completed += 1
                        progress?(completed, images.count)
                        continue
                    }
                    if owner[digest] != nil {
                        duplicates.append((i, digest))
                        continue
                    }
                    owner[digest] = i
                    group.addTask {
                        do {
                            let text = try await self.inFlight.text(
                                for: digest,
                                cached: { self.cache?.text(for: digest) }
                            ) {
                                try await self.withBackoff {
                                    try await self.recognizePage(jpeg, digest: digest)
                                }
                            }
                            return (i, .success(text))
                        } catch {
                            return (i, .failure(error))
                        }
                    }
                    return
                }
            }
            for _ in 0..<min(maxConcurrent, images.count) { dispatchNext() }
            while let (i, result) = await group.next() {
                switch result {
                case .success(let text):
                    results[i] = text
                    completed += 1
                    progress?(completed, images.count)
                case .failure(let error):
                    if failure == nil { failure = error }
                }
                dispatchNext()
            }
        }
        if let failure { throw failure }
        for (i, digest) in duplicates {
            if let source = owner[digest] { results[i] = results[source] }
        }
        if !duplicates.isEmpty {
            completed += duplicates.count
            progress?(completed, images.count)
        }
        return results
    }

    private func recognizePage(_ jpeg: Data, digest: String) async throws -> String {
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
            throw [401, 403].contains(http.statusCode)
                ? WorkerError.subscriptionRequired : WorkerError.http(http.statusCode)
        }

        struct OCRResponse: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(OCRResponse.self, from: data) else {
            throw WorkerError.badResponse
        }
        cache?.store(decoded.text, for: digest)
        return decoded.text
    }

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
