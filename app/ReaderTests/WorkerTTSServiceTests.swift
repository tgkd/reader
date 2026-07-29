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

    private func makeService() -> WorkerTTSService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return WorkerTTSService(baseURL: URL(string: "https://test.example.com")!,
                                userId: { "user-123" },
                                session: URLSession(configuration: config))
    }

    /// A minimal well-formed `with-timestamps` response: one character, parallel
    /// timing arrays, non-empty audio (an empty `audio_base64` is rejected).
    private func alignedResponse() -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            let json = """
            {"audio_base64":"\(Data("mp3".utf8).base64EncodedString())",
             "alignment":{"characters":["あ"],
                          "character_start_times_seconds":[0.0],
                          "character_end_times_seconds":[0.5]}}
            """
            return (resp, Data(json.utf8))
        }
    }

    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.lastBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSendsJapaneseLanguageCodeAndExplicitVoiceSettings() async throws {
        MockURLProtocol.handler = alignedResponse()
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
        MockURLProtocol.handler = alignedResponse()
        _ = try await makeService().synthesize(SynthesisRequest(text: "三人", voice: .shizuka))

        XCTAssertNil(try sentBody()["apply_language_text_normalization"])
    }

    /// The voice must travel per-request: `ContentKey` includes it, so a request
    /// that quietly used the default would miss the cache and re-bill synthesis.
    func testSendsRequestedVoiceNotTheDefault() async throws {
        MockURLProtocol.handler = alignedResponse()
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
