import XCTest
import UIKit
@testable import Reader

final class WorkerOCRServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService(userId: String? = "user-123", maxConcurrent: Int = 2,
                             cacheDir: URL? = nil,
                             inFlight: OCRInFlightPages = OCRInFlightPages()) -> WorkerOCRService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return WorkerOCRService(baseURL: URL(string: "https://test.example.com")!,
                                userId: userId, session: URLSession(configuration: config),
                                maxConcurrent: maxConcurrent,
                                cache: OCRPageCache(dir: cacheDir ?? Self.tempCacheDir()),
                                inFlight: inFlight)
    }

    private static func tempCacheDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRCacheTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeImage(shade: CGFloat = 1) -> CGImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor(white: shade, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.cgImage!
    }

    private func ok(_ text: String) -> (HTTPURLResponse, Data) {
        let resp = HTTPURLResponse(url: URL(string: "https://test.example.com/pdf/ocr")!,
                                   statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (resp, Data(#"{"text":"\#(text)"}"#.utf8))
    }
    private func status(_ code: Int) -> (HTTPURLResponse, Data) {
        let resp = HTTPURLResponse(url: URL(string: "https://test.example.com/pdf/ocr")!,
                                   statusCode: code, httpVersion: nil, headerFields: nil)!
        return (resp, Data("{}".utf8))
    }

    func testPostsToOCRRouteWithAuthAndBase64Body() async throws {
        MockURLProtocol.handler = { _ in self.ok("認識結果") }
        let out = try await makeService().recognize([makeImage()], progress: nil)
        XCTAssertEqual(out, ["認識結果"])

        let req = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(req.url?.path.hasSuffix("/pdf/ocr") ?? false, req.url?.path ?? "nil")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-User-ID"), "user-123")
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let b64 = try XCTUnwrap(json["image_base64"] as? String)
        XCTAssertFalse(b64.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: b64))
    }

    func testForbiddenMapsToSubscriptionRequired() async {
        MockURLProtocol.handler = { _ in self.status(403) }
        do {
            _ = try await makeService().recognize([makeImage()], progress: nil)
            XCTFail("expected subscriptionRequired")
        } catch let error as WorkerOCRService.WorkerError {
            guard case .subscriptionRequired = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("unexpected \(error)") }
    }

    func testUnauthorizedMapsToSubscriptionRequired() async {
        MockURLProtocol.handler = { _ in self.status(401) }
        do {
            _ = try await makeService().recognize([makeImage()], progress: nil)
            XCTFail("expected subscriptionRequired")
        } catch let error as WorkerOCRService.WorkerError {
            guard case .subscriptionRequired = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("unexpected \(error)") }
    }

    func testRetriesOn429ThenSucceeds() async throws {
        let calls = Counter()
        MockURLProtocol.handler = { _ in
            calls.increment()
            return calls.value == 1 ? self.status(429) : self.ok("ok")
        }
        let out = try await makeService(maxConcurrent: 1).recognize([makeImage()], progress: nil)
        XCTAssertEqual(out, ["ok"])
        XCTAssertEqual(calls.value, 2)
    }

    func testPreservesPageOrder() async throws {
        let calls = Counter()
        MockURLProtocol.handler = { _ in
            let n = calls.incrementAndGet() - 1
            return self.ok("P\(n)")
        }
        let out = try await makeService(maxConcurrent: 1)
            .recognize([makeImage(shade: 1), makeImage(shade: 0.5), makeImage(shade: 0)], progress: nil)
        XCTAssertEqual(out, ["P0", "P1", "P2"])
    }

    func testProgressFiresPerPage() async throws {
        MockURLProtocol.handler = { _ in self.ok("x") }
        let last = Counter()
        _ = try await makeService().recognize([makeImage(shade: 1), makeImage(shade: 0)]) { done, total in
            last.set(done)
            XCTAssertEqual(total, 2)
        }
        XCTAssertEqual(last.value, 2)
    }

    func testRecognizedPageIsCheckpointedAndNotRequestedAgain() async throws {
        let calls = Counter()
        MockURLProtocol.handler = { _ in calls.increment(); return self.ok("認識済み") }
        let dir = Self.tempCacheDir()
        let page = makeImage()

        let first = try await makeService(cacheDir: dir).recognize([page], progress: nil)
        let second = try await makeService(cacheDir: dir).recognize([page], progress: nil)

        XCTAssertEqual(first, ["認識済み"])
        XCTAssertEqual(second, ["認識済み"])
        XCTAssertEqual(calls.value, 1, "the second pass must be served from the page cache — OCR is billed per page")
    }

    func testIdenticalPagesInOneWindowAreBilledOnce() async throws {
        let calls = Counter()
        MockURLProtocol.handler = { _ in calls.increment(); return self.ok("同じページ") }
        let page = makeImage(shade: 0.25)

        let out = try await makeService(maxConcurrent: 2).recognize([page, page, page], progress: nil)

        XCTAssertEqual(out, ["同じページ", "同じページ", "同じページ"])
        XCTAssertEqual(calls.value, 1, "identical pages must coalesce into one billed request")
    }

    func testSamePageAcrossConcurrentServicesIsBilledOnce() async throws {
        let calls = Counter()
        MockURLProtocol.handler = { _ in
            calls.increment()
            Thread.sleep(forTimeInterval: 0.2)
            return self.ok("重複ページ")
        }
        let dir = Self.tempCacheDir()
        let shared = OCRInFlightPages()
        let page = makeImage(shade: 0.75)
        let first = makeService(cacheDir: dir, inFlight: shared)
        let second = makeService(cacheDir: dir, inFlight: shared)

        async let a = first.recognize([page], progress: nil)
        async let b = second.recognize([page], progress: nil)
        let (outA, outB) = try await (a, b)

        XCTAssertEqual(outA, ["重複ページ"])
        XCTAssertEqual(outB, ["重複ページ"])
        XCTAssertEqual(calls.value, 1, "concurrent imports of the same page must share one billed request")
    }

    func testRegistryServesACachedPageWithoutStartingWork() async throws {
        let cache = OCRPageCache(dir: Self.tempCacheDir())
        let registry = OCRInFlightPages()
        let digest = "deadbeef"
        let calls = Counter()

        let first = try await registry.text(for: digest, cached: { cache.text(for: digest) }) {
            calls.increment()
            cache.store("認識済み", for: digest)
            return "認識済み"
        }
        let second = try await registry.text(for: digest, cached: { cache.text(for: digest) }) {
            calls.increment()
            return "再課金"
        }

        XCTAssertEqual(first, "認識済み")
        XCTAssertEqual(second, "認識済み")
        XCTAssertEqual(calls.value, 1,
                       "a page already on disk must never start a second billed request")
    }

    func testInFlightPagesStillCheckpointWhenAnotherPageFails() async throws {
        let dir = Self.tempCacheDir()
        let good = makeImage(shade: 0)
        let bad = makeImage(shade: 1)
        let goodPayload = try XCTUnwrap(UIImage(cgImage: good).jpegData(compressionQuality: 0.7))
            .base64EncodedString()
        let calls = Counter()
        MockURLProtocol.handler = { req in
            calls.increment()
            let body = MockURLProtocol.body(of: req)
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let payload = json?["image_base64"] as? String
            guard payload == goodPayload else { return self.status(500) }
            Thread.sleep(forTimeInterval: 0.15)
            return self.ok("二ページ目")
        }

        do {
            _ = try await makeService(maxConcurrent: 2, cacheDir: dir).recognize([bad, good], progress: nil)
            XCTFail("the failing page should propagate")
        } catch {}

        let before = calls.value
        let out = try await makeService(maxConcurrent: 1, cacheDir: dir).recognize([good], progress: nil)
        XCTAssertEqual(out, ["二ページ目"])
        XCTAssertEqual(calls.value, before,
                       "an in-flight page must finish and checkpoint — it may already have been billed")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    func incrementAndGet() -> Int { lock.lock(); defer { lock.unlock() }; _value += 1; return _value }
    func set(_ v: Int) { lock.lock(); _value = v; lock.unlock() }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); handler = nil; lastRequest = nil; lastBody = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol.lastRequest = request
        MockURLProtocol.lastBody = MockURLProtocol.body(of: request)
        let handler = MockURLProtocol.handler
        MockURLProtocol.lock.unlock()

        guard let handler else { client?.urlProtocolDidFinishLoading(self); return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
