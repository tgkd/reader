import XCTest
import ReaderCore
@testable import Reader

/// Pins the `/tts/aligned` request body. The narration parameters are invisible in
/// the UI and only surface as "the voice reads Japanese wrong", so a silent
/// regression here is expensive: `language_code` is what stops the multilingual
/// model resolving kanji through Chinese, and explicit `voice_settings` are what
/// stop a shared-library voice's own saved settings deciding delivery.
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

    /// One NDJSON line per character, mirroring the live stream: each chunk carries
    /// its own audio slice, and chunk timestamps are ABSOLUTE (chunk N+1 starts
    /// where N ended), which is what lets the client concatenate rather than offset.
    ///
    /// The default slice size is what 0.5 s of `mp3_44100_128` actually weighs, so the
    /// mock is internally consistent the way a real response is — the service now
    /// checks the alignment's extent against the audio's real length, and a token
    /// three-byte "mp3" would (correctly) read as a chapter of timings over no audio.
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

    func testSendsJapaneseLanguageCodeAndExplicitVoiceSettings() async throws {
        MockURLProtocol.handler = alignedResponse("日本橋")
        _ = try await makeService().synthesize(
            SynthesisRequest(text: "日本橋", voice: .shizuka, model: .multilingualV2))

        let body = try sentBody()
        XCTAssertEqual(body["language_code"] as? String, "ja")
        XCTAssertEqual(body["voice_id"] as? String, Voice.shizuka.id)
        XCTAssertEqual(body["model_id"] as? String, "eleven_multilingual_v2")

        let settings = try XCTUnwrap(body["voice_settings"] as? [String: Any])
        XCTAssertEqual(settings["stability"] as? Double, NarrationSettings.stability)
        XCTAssertEqual(settings["similarity_boost"] as? Double, NarrationSettings.similarityBoost)
        XCTAssertEqual(settings["style"] as? Double, NarrationSettings.style)
        XCTAssertEqual(settings["use_speaker_boost"] as? Bool, NarrationSettings.useSpeakerBoost)
        XCTAssertEqual(settings["speed"] as? Double, NarrationSettings.speed)
    }

    /// `apply_language_text_normalization` produces correct Japanese readings but
    /// speaks the normalizer's own reasoning aloud and wrecks the char alignment
    /// (measured 2026-07-29). It must stay off the wire until that is fixed
    /// upstream — asserted rather than commented so re-adding it fails loudly.
    func testDoesNotSendLanguageTextNormalization() async throws {
        MockURLProtocol.handler = alignedResponse("三人")
        _ = try await makeService().synthesize(SynthesisRequest(text: "三人", voice: .shizuka))

        XCTAssertNil(try sentBody()["apply_language_text_normalization"])
    }

    // MARK: - Streaming

    /// Buffered synthesis of a whole chapter cannot complete: ElevenLabs emits no
    /// bytes until it is done and its own edge returns 524 first. The stream flag
    /// is what makes chapter narration possible at all, so it is asserted, not
    /// assumed.
    func testAlwaysRequestsAStream() async throws {
        MockURLProtocol.handler = alignedResponse("本")
        _ = try await makeService().synthesize(SynthesisRequest(text: "本", voice: .shizuka))

        XCTAssertEqual(try sentBody()["stream"] as? Bool, true)
    }

    /// Chunks concatenate in order, and their ABSOLUTE timestamps carry through
    /// untouched — CharTokenMapper folds these onto token spans, so a mis-ordered
    /// or re-based array would desync the highlight for the whole chapter.
    func testConcatenatesChunksInOrderPreservingAbsoluteTimes() async throws {
        MockURLProtocol.handler = alignedResponse("吾輩は猫")
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))

        XCTAssertEqual(out.alignment.characters, ["吾", "輩", "は", "猫"])
        XCTAssertEqual(out.alignment.startTimes, [0.0, 0.5, 1.0, 1.5])
        XCTAssertEqual(out.alignment.endTimes, [0.5, 1.0, 1.5, 2.0])
        XCTAssertEqual(out.audio.count, 8_000 * 4)   // 0.5 s of 128 kbps audio per chunk
    }

    /// A dropped connection mid-chapter yields a SHORT but internally consistent
    /// alignment — which would otherwise be cached as a complete chapter, leaving
    /// the reader permanently missing its tail with nothing to signal why.
    func testRejectsATruncatedStream() async {
        MockURLProtocol.handler = alignedResponse("吾輩")   // 2 of 4 characters
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected a truncated stream to throw")
        } catch {
            XCTAssertEqual(error as? WorkerTTSService.WorkerError, .truncatedStream)
        }
    }

    /// A stream that delivers ENOUGH characters but not the RIGHT ones — an
    /// overlapping or repeated chunk — passes the truncation check, is internally
    /// consistent, and would be cached as paid narration whose timings never match
    /// the audio: `CharTokenMapper`'s tolerant resync absorbs the mismatch and
    /// expresses it as a highlight that drifts. Fail loudly instead.
    func testRejectsAStreamWhoseCharactersDoNotReproduceTheText() async {
        MockURLProtocol.handler = alignedResponse("吾輩吾輩")   // right count, wrong text
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected a misaligned stream to throw")
        } catch {
            XCTAssertEqual(error as? WorkerTTSService.WorkerError, .misalignedStream)
        }
    }

    /// `eleven_v3` sometimes speaks material it returns no timings for. Measured on a
    /// real 851-char chapter: the alignment tracks the audio to ±0.1 s and then stops
    /// at 220.00 s while the mp3 runs to 227.68 s. Every other check passes — the
    /// arrays are parallel and monotonic and the characters reproduce the text — so
    /// without this the entry caches as paid narration whose highlight is permanently
    /// out of step with what is being said.
    func testRejectsAlignmentThatDoesNotCoverTheAudio() async {
        // 4 chars timed to 2.0 s, against 160,000 bytes = 10 s of 128 kbps audio.
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

    /// The mirror case, which a one-sided check would wave through: `accumulate`
    /// silently drops NDJSON lines it cannot decode, so a lost audio slice leaves
    /// complete text over incomplete audio — and `ReaderModel`'s
    /// `max(timeline.duration, bytes/16000)` would then paper over it.
    func testRejectsAudioShorterThanTheAlignment() async {
        // 4 chars timed to 2.0 s, against 4 bytes = a quarter of a millisecond.
        MockURLProtocol.handler = alignedResponse("吾輩は猫", audioBytesPerChunk: 1)
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected audio shorter than the alignment to throw")
        } catch let error as WorkerTTSService.WorkerError {
            guard case .audioAlignmentMismatch(let seconds) = error else {
                return XCTFail("Expected .audioAlignmentMismatch, got \(error)")
            }
            XCTAssertLessThan(seconds, -1.9)   // audio - alignment, so negative
        } catch {
            XCTFail("Expected a WorkerError, got \(error)")
        }
    }

    /// `joined() == text` cannot see element boundaries: `["AB", ""]` joins to "AB"
    /// and passes, while `CharTokenMapper` reads only the FIRST grapheme of each
    /// element and silently loses the "B". One element per character is the contract
    /// the fold actually depends on.
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

    /// The guard above must not fire on a healthy response — the alignment of a
    /// good stream reproduces the request text exactly (verified against the live
    /// API on v3 and multilingual_v2).
    func testAcceptsAStreamWhoseCharactersReproduceTheText() async throws {
        MockURLProtocol.handler = alignedResponse("吾輩は猫")
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))

        XCTAssertEqual(out.alignment.characters.joined(), out.text)
    }

    /// Progress is measured from characters actually delivered, not eased from a
    /// guess — it must climb during the stream and finish at 1.
    func testReportsProgressAsCharactersArrive() async throws {
        let samples = ProgressSamples()
        MockURLProtocol.handler = alignedResponse("吾輩は猫")
        _ = try await makeService(onProgress: { samples.append($0) }).synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))

        let values = samples.values
        XCTAssertEqual(values, [0.25, 0.5, 0.75, 1.0])
    }

    /// The voice must travel per-request: `ContentKey` includes it, so a request
    /// that quietly used the default would miss the cache and re-bill synthesis.
    func testSendsRequestedVoiceNotTheDefault() async throws {
        MockURLProtocol.handler = alignedResponse("本")   // must echo the requested text
        _ = try await makeService().synthesize(SynthesisRequest(text: "本", voice: .george))

        XCTAssertEqual(try sentBody()["voice_id"] as? String, Voice.george.id)
    }

    /// v3's input limit is half of multilingual_v2's, so a chunk size fixed for v2
    /// would exceed it and take a 400 rather than splitting. The cap must follow
    /// the model, and must stay under every model's real API limit.
    func testChunkCapFollowsTheModel() {
        XCTAssertLessThan(SynthesisModel.v3.maxRequestChars, 5_000)
        XCTAssertLessThan(SynthesisModel.multilingualV2.maxRequestChars, 10_000)
        XCTAssertLessThan(SynthesisModel.flashV2_5.maxRequestChars, 40_000)
        // A chapter is capped well under v3's limit, so the common path stays a
        // single unchunked request even on the most restrictive model.
        XCTAssertLessThanOrEqual(Chapter.maxRenderableChars, SynthesisModel.v3.maxRequestChars)
    }
}

/// Collects progress callbacks, which arrive off the test's thread.
private final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []

    func append(_ v: Double) { lock.lock(); samples.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return samples }
}
