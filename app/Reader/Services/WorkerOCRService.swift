import CryptoKit
import Foundation
import UIKit

/// Content-addressed cache of recognized page text, keyed by a hash of the exact
/// JPEG bytes POSTed for that page. OCR is billed PER PAGE and an import can fail
/// after several bounded windows have already been recognized (a dropped
/// connection on page 60 of 100 throws away pages 1–59); re-importing the same
/// file renders the same pages to the same bytes, so those pages come back from
/// here instead of being paid for twice. Mirrors `DiskAudioStore`: content-
/// addressed, in Caches, regenerable and OS-evictable.
struct OCRPageCache {
    let dir: URL

    /// The app's shared page cache (`Caches/OCR`), or nil if it can't be created.
    static func standard() -> OCRPageCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("OCR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return OCRPageCache(dir: dir)
    }

    /// A page's cache key: the SHA-256 of the exact JPEG bytes POSTed for it.
    /// Computed once per page by the caller, which also uses it to collapse
    /// identical pages onto a single billed request.
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

/// Session-scoped registry of page requests currently in flight, keyed by image
/// digest. `recognize`'s own dedupe only spans ONE call, but nothing serializes
/// imports (`AppModel.importFile` starts a Task per pick) and each import gets its
/// OWN `WorkerOCRService`, so two imports of the same scanned file overlap: both
/// miss the disk cache for a page neither has stored yet and the per-page billed
/// route is hit twice. Sharing the task collapses them onto one request. The entry
/// is dropped as soon as it settles, so a failure never sticks — everything after
/// it is served by `OCRPageCache`.
actor OCRInFlightPages {
    private var tasks: [String: Task<String, Error>] = [:]

    /// The in-flight request for `digest`, starting `work` if none is running.
    ///
    /// `cached` re-probes the page cache from INSIDE the actor, and that second look
    /// is what makes this airtight. The caller's own probe ran before the hop in
    /// here, so an owner that settled in the meantime has both stored its text and
    /// dropped its entry — an arriving page would find an empty registry, read it as
    /// "nobody is doing this", and pay for a page already sitting on disk. The order
    /// rules that out: `store` completes before the owner's task resolves, which
    /// completes before `defer` clears the entry, so "no entry" always implies "text
    /// is on disk". Reaching `work` therefore requires both to be genuinely empty.
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
    private let cache: OCRPageCache?
    /// Shared with every other recognizer of the same session (see `AppServices`), so
    /// concurrent imports of the same page ride one billed request. The default is a
    /// private one — an isolated recognizer coalesces only within itself.
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
        // Page digest → the index whose request owns it, plus the later pages that
        // are byte-identical to it and will copy its text.
        var owner: [String: Int] = [:]
        var duplicates: [(index: Int, digest: String)] = []

        // A NON-throwing group on purpose: rethrowing out of `group.next()` unwinds
        // the group and cancels the pages still in flight — pages the Worker may
        // already have recognized and BILLED, whose text would then never reach the
        // page cache and would be paid for again on the next import. Collect
        // per-task results instead, let everything already dispatched finish (and
        // checkpoint itself), then propagate the failure. Mirrors `ChunkingTTSService`.
        await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            var next = 0
            // Walk pages until one actually needs a request: a cache hit and a
            // duplicate of a page already in flight both resolve without spending,
            // so neither may consume a concurrency slot.
            func dispatchNext() {
                while next < images.count, failure == nil {
                    let i = next
                    next += 1
                    guard let jpeg = UIImage(cgImage: images[i]).jpegData(compressionQuality: jpegQuality) else {
                        failure = WorkerError.badResponse
                        return
                    }
                    let digest = OCRPageCache.digest(of: jpeg)
                    // A page already recognized once (an earlier import of the same
                    // file that failed in a later window, a retry after a dropped
                    // connection) is served from disk: this route is billed per page,
                    // so the user must never pay twice for the same image.
                    if let cached = cache?.text(for: digest) {
                        results[i] = cached
                        completed += 1
                        progress?(completed, images.count)
                        continue
                    }
                    // The same image twice in one book (blank leaves between chapters
                    // in a scan) hashes to one key, but inside a single concurrency
                    // window both would look up the cache before either wrote it —
                    // two misses, two billed POSTs of the same JPEG. Send the first
                    // only; the rest copy its text once the group drains.
                    if owner[digest] != nil {
                        duplicates.append((i, digest))
                        continue
                    }
                    owner[digest] = i
                    group.addTask {
                        do {
                            // Coalesce across imports too: `owner` above only covers
                            // the pages of THIS call. The cache probe is repeated in
                            // there because the one above ran before this hop.
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

    /// One page: the JPEG and its digest are computed by the caller (which needs
    /// the digest to dedupe identical pages), so this is purely the billed request
    /// plus its checkpoint.
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
            // 401 (no X-User-ID / no RevenueCat identity) and 403 (entitlement
            // rejected) both mean "this user can't bill OCR" — same as the TTS path.
            throw [401, 403].contains(http.statusCode)
                ? WorkerError.subscriptionRequired : WorkerError.http(http.statusCode)
        }

        struct OCRResponse: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(OCRResponse.self, from: data) else {
            throw WorkerError.badResponse
        }
        // Checkpoint the paid result immediately: a failure later in this batch (or
        // in a later window) must not discard the pages already recognized.
        cache?.store(decoded.text, for: digest)
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
