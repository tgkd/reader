import XCTest
import UIKit
@testable import Reader

/// Exercises `WorkerOCRService` against a mocked URL session (`MockURLProtocol`):
/// the request shape (route, auth header, base64 body), the 403→subscription
/// mapping, 429 retry, page-order preservation, and progress reporting. No network.
final class WorkerOCRServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService(userId: String? = "user-123", maxConcurrent: Int = 2) -> WorkerOCRService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return WorkerOCRService(baseURL: URL(string: "https://test.example.com")!,
                                userId: userId, session: URLSession(configuration: config),
                                maxConcurrent: maxConcurrent)
    }

    private func makeImage() -> CGImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
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
        XCTAssertNotNil(Data(base64Encoded: b64))   // a real base64 payload
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
        XCTAssertEqual(calls.value, 2)   // one 429, one retry
    }

    func testPreservesPageOrder() async throws {
        let calls = Counter()
        MockURLProtocol.handler = { _ in
            let n = calls.incrementAndGet() - 1
            return self.ok("P\(n)")
        }
        // maxConcurrent 1 → deterministic call order maps to page order.
        let out = try await makeService(maxConcurrent: 1)
            .recognize([makeImage(), makeImage(), makeImage()], progress: nil)
        XCTAssertEqual(out, ["P0", "P1", "P2"])
    }

    func testProgressFiresPerPage() async throws {
        MockURLProtocol.handler = { _ in self.ok("x") }
        let last = Counter()
        _ = try await makeService().recognize([makeImage(), makeImage()]) { done, total in
            last.set(done)
            XCTAssertEqual(total, 2)
        }
        XCTAssertEqual(last.value, 2)   // reached total
    }
}

/// Thread-safe counter for assertions inside `@Sendable` mock handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    func incrementAndGet() -> Int { lock.lock(); defer { lock.unlock() }; _value += 1; return _value }
    func set(_ v: Int) { lock.lock(); _value = v; lock.unlock() }
}

/// Intercepts URLSession traffic, returning canned responses and recording the
/// last request + its (stream-or-data) body for assertions.
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

    /// URLSession turns `httpBody` into `httpBodyStream` by the time a protocol sees
    /// it, so read whichever is present.
    private static func body(of request: URLRequest) -> Data? {
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
