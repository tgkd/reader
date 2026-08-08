import XCTest
import ReaderCore
@testable import Reader

final class WorkerTTSServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService(
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> WorkerTTSService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return WorkerTTSService(baseURL: URL(string: "https://test.example.com")!,
                                userId: { "user-123" },
                                session: URLSession(configuration: config),
                                onProgress: onProgress)
    }

    private func streamed(_ text: String, audioBytesPerChunk: Int = 8_000) -> Data {
        var out = Data()
        let slice = Data(repeating: 0x55, count: audioBytesPerChunk)
        for (i, ch) in text.enumerated() {
            let line = """
            {"audio_base64":"\(slice.base64EncodedString())",\
            "alignment":{"characters":["\(ch)"],\
            "character_start_times_seconds":[\(Double(i) * 0.5)],\
            "character_end_times_seconds":[\(Double(i + 1) * 0.5)]}}

            """
            out.append(Data(line.utf8))
        }
        return out
    }

    private func alignedResponse(_ text: String = "あ", audioBytesPerChunk: Int = 8_000)
        -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = streamed(text, audioBytesPerChunk: audioBytesPerChunk)
        return { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
    }

    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.lastBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSendsOnlyTextVoiceAndTheStreamFlag() async throws {
        MockURLProtocol.handler = alignedResponse("日本橋")
        _ = try await makeService().synthesize(SynthesisRequest(text: "日本橋", voice: .shizuka))

        let body = try sentBody()
        XCTAssertEqual(Set(body.keys), ["text", "voice_id", "stream"])
        XCTAssertEqual(body["text"] as? String, "日本橋")
        XCTAssertEqual(body["voice_id"] as? String, Voice.shizuka.id)

        XCTAssertNil(body["model_id"], "the Worker picks the model")
        XCTAssertNil(body["language_code"], "the Worker pins language_code: ja")
        XCTAssertNil(body["voice_settings"], "the Worker pins delivery")
    }

    func testDoesNotSendLanguageTextNormalization() async throws {
        MockURLProtocol.handler = alignedResponse("三人")
        _ = try await makeService().synthesize(SynthesisRequest(text: "三人", voice: .shizuka))

        XCTAssertNil(try sentBody()["apply_language_text_normalization"])
    }

    func testAlwaysRequestsAStream() async throws {
        MockURLProtocol.handler = alignedResponse("本")
        _ = try await makeService().synthesize(SynthesisRequest(text: "本", voice: .shizuka))

        XCTAssertEqual(try sentBody()["stream"] as? Bool, true)
    }

    func testConcatenatesChunksInOrderPreservingAbsoluteTimes() async throws {
        MockURLProtocol.handler = alignedResponse("吾輩は猫")
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))

        XCTAssertEqual(out.alignment.characters, ["吾", "輩", "は", "猫"])
        XCTAssertEqual(out.alignment.startTimes, [0.0, 0.5, 1.0, 1.5])
        XCTAssertEqual(out.alignment.endTimes, [0.5, 1.0, 1.5, 2.0])
        XCTAssertEqual(out.audio.count, 8_000 * 4)
    }

    func testRejectsATruncatedStream() async {
        MockURLProtocol.handler = alignedResponse("吾輩")
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected a truncated stream to throw")
        } catch {
            XCTAssertEqual(error as? WorkerTTSService.WorkerError, .truncatedStream)
        }
    }

    func testRejectsAStreamWhoseCharactersDoNotReproduceTheText() async {
        MockURLProtocol.handler = alignedResponse("吾輩吾輩")
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected a misaligned stream to throw")
        } catch {
            XCTAssertEqual(error as? WorkerTTSService.WorkerError, .misalignedStream)
        }
    }

    func testRejectsAlignmentThatDoesNotCoverTheAudio() async {
        MockURLProtocol.handler = alignedResponse("吾輩は猫", audioBytesPerChunk: 40_000)
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected undescribed audio to throw")
        } catch let error as WorkerTTSService.WorkerError {
            guard case .audioAlignmentMismatch(let seconds) = error else {
                return XCTFail("Expected .audioAlignmentMismatch, got \(error)")
            }
            XCTAssertEqual(seconds, 8.0, accuracy: 0.01)
        } catch {
            XCTFail("Expected a WorkerError, got \(error)")
        }
    }

    func testRejectsAudioShorterThanTheAlignment() async {
        MockURLProtocol.handler = alignedResponse("吾輩は猫", audioBytesPerChunk: 1)
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected audio shorter than the alignment to throw")
        } catch let error as WorkerTTSService.WorkerError {
            guard case .audioAlignmentMismatch(let seconds) = error else {
                return XCTFail("Expected .audioAlignmentMismatch, got \(error)")
            }
            XCTAssertLessThan(seconds, -1.9)
        } catch {
            XCTFail("Expected a WorkerError, got \(error)")
        }
    }

    func testRejectsMultiCharacterAlignmentElements() async {
        let body = """
        {"audio_base64":"\(Data([0x55]).base64EncodedString())",\
        "alignment":{"characters":["吾輩",""],\
        "character_start_times_seconds":[0.0,0.5],\
        "character_end_times_seconds":[0.5,0.5]}}

        """
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩", voice: .shizuka))
            XCTFail("Expected multi-character elements to throw")
        } catch {
            XCTAssertEqual(error as? WorkerTTSService.WorkerError, .misalignedStream)
        }
    }

    func testRejectsAnAlignmentPaddedWithAnEmptyElement() async {
        let body = """
        {"audio_base64":"\(Data(repeating: 0x55, count: 160_000).base64EncodedString())",\
        "alignment":{"characters":["あ",""],\
        "character_start_times_seconds":[0.0,0.5],\
        "character_end_times_seconds":[0.5,10.0]}}

        """
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        do {
            _ = try await makeService().synthesize(SynthesisRequest(text: "あ", voice: .shizuka))
            XCTFail("Expected an empty alignment element to throw")
        } catch {
            XCTAssertEqual(error as? WorkerTTSService.WorkerError, .misalignedStream,
                           "an empty element would let its end time describe unspoken audio")
        }
    }

    func testAcceptsAnAlignmentThatSplitsAVariationSequence() async throws {
        let text = "葛\u{E0100}城"
        let body = """
        {"audio_base64":"\(Data(repeating: 0x55, count: 16_000).base64EncodedString())",\
        "alignment":{"characters":["葛","\u{E0100}","城"],\
        "character_start_times_seconds":[0.0,0.5,0.5],\
        "character_end_times_seconds":[0.5,0.5,1.0]}}

        """
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))

        XCTAssertEqual(out.alignment.characters.count, 3,
                       "a scalar-split grapheme still describes the submitted text")
        XCTAssertEqual(out.alignment.characters.joined(), text)
    }

    func testAcceptsAStreamWhoseCharactersReproduceTheText() async throws {
        MockURLProtocol.handler = alignedResponse("吾輩は猫")
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))

        XCTAssertEqual(out.alignment.characters.joined(), out.text)
    }

    func testReportsProgressAsCharactersArrive() async throws {
        let samples = ProgressSamples()
        MockURLProtocol.handler = alignedResponse("吾輩は猫")
        _ = try await makeService(onProgress: { samples.append($0) }).synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))

        let values = samples.values
        XCTAssertEqual(values, [0.25, 0.5, 0.75, 1.0])
    }

    func testSendsRequestedVoiceNotTheDefault() async throws {
        MockURLProtocol.handler = alignedResponse("本")
        _ = try await makeService().synthesize(SynthesisRequest(text: "本", voice: .george))

        XCTAssertEqual(try sentBody()["voice_id"] as? String, Voice.george.id)
    }

    func testChunkCapHoldsForEveryModelTheWorkerMayPick() {
        XCTAssertLessThan(SynthesisLimits.maxRequestChars, 5_000)
        XCTAssertLessThanOrEqual(Chapter.maxRenderableChars, SynthesisLimits.maxRequestChars)
    }

    func testOmitsPronunciationRulesWhenTheBookHasNone() async throws {
        _ = try? await makeService().synthesize(
            SynthesisRequest(text: "本", voice: .shizuka))
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["pronunciation_rules"],
                     "an empty lexicon must not reach the wire as an empty array")
    }

    func testSendsTheBookLexiconWhenThereIsOne() async throws {
        _ = try? await makeService().synthesize(
            SynthesisRequest(text: "黄前久美子", voice: .shizuka,
                             pronunciation: [
                                PronunciationRule(surface: "黄前", reading: "おうまえ"),
                                PronunciationRule(surface: "久美子", reading: "くみこ"),
                             ]))
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        let rules = try XCTUnwrap(json["pronunciation_rules"] as? [[String: String]])
        XCTAssertEqual(rules, [["surface": "黄前", "reading": "おうまえ"],
                               ["surface": "久美子", "reading": "くみこ"]])
    }


    /// A subscriber who has spent the period's narration must not be shown a Membership
    /// prompt — they already pay. The status alone cannot carry that distinction, so the
    /// client has to read the body it previously threw away.
    func testSpentAllowanceIsDistinctFromNeedingASubscription() async {
        MockURLProtocol.handler = { request in
            let body = Data("""
            {"error":{"code":"narration_allowance_exhausted","used_characters":45000,            "limit_characters":46000,"remaining_characters":1000}}
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 402,
                                    httpVersion: nil, headerFields: nil)!, body)
        }
        do {
            _ = try await makeService().synthesize(SynthesisRequest(text: "あ"))
            XCTFail("expected the request to fail")
        } catch let error as WorkerTTSService.WorkerError {
            guard case .allowanceExhausted(let remaining, let limit) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(remaining, 1_000)
            XCTAssertEqual(limit, 46_000)
        } catch {
            XCTFail("got \(error)")
        }
    }

    /// An error body we cannot read is not worth failing differently over: fall back to the
    /// status code rather than inventing a reason.
    func testUnreadableErrorBodyFallsBackToTheStatusCode() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 402,
                             httpVersion: nil, headerFields: nil)!, Data("not json".utf8))
        }
        do {
            _ = try await makeService().synthesize(SynthesisRequest(text: "あ"))
            XCTFail("expected the request to fail")
        } catch let error as WorkerTTSService.WorkerError {
            XCTAssertEqual(error, .http(402))
        } catch {
            XCTFail("got \(error)")
        }
    }

    /// 401/403 still mean "buy a subscription" and must not be diverted into the allowance path.
    func testUnauthorizedStillAsksForASubscription() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeService().synthesize(SynthesisRequest(text: "あ"))
            XCTFail("expected the request to fail")
        } catch let error as WorkerTTSService.WorkerError {
            XCTAssertEqual(error, .subscriptionRequired)
        } catch {
            XCTFail("got \(error)")
        }
    }
}

private final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []

    func append(_ v: Double) { lock.lock(); samples.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return samples }
}
