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

    private func streamed(_ text: String, endTimes: [Double], audioBytesPerChunk: Int) -> Data {
        var out = Data()
        let slice = Data(repeating: 0x55, count: audioBytesPerChunk)
        for (i, ch) in text.enumerated() {
            let start = i == 0 ? 0 : endTimes[i - 1]
            let line = """
            {"audio_base64":"\(slice.base64EncodedString())",\
            "alignment":{"characters":["\(ch)"],\
            "character_start_times_seconds":[\(start)],\
            "character_end_times_seconds":[\(endTimes[i])]}}

            """
            out.append(Data(line.utf8))
        }
        return out
    }

    private func trailerLine(_ text: String, endTimes: [Double], loss: Double? = 2.0) -> String {
        let chars = text.map { "\"\($0)\"" }.joined(separator: ",")
        let startValues: [Double] = [0.0] + Array(endTimes.dropLast())
        let starts = startValues.map { String($0) }.joined(separator: ",")
        let ends = endTimes.map { String($0) }.joined(separator: ",")
        let lossField = loss.map { ",\"forced_alignment_loss\":\($0)" } ?? ""
        return "{\"forced_alignment\":{\"characters\":[\(chars)],"
            + "\"character_start_times_seconds\":[\(starts)],"
            + "\"character_end_times_seconds\":[\(ends)]}\(lossField)}\n"
    }

    private func response(_ body: Data) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
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

    func testKeepsPaidAudioTheAlignmentDoesNotDescribe() async throws {
        MockURLProtocol.handler = alignedResponse("吾輩は猫", audioBytesPerChunk: 40_000)
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
        XCTAssertEqual(out.audioSeconds - (out.alignment.endTimes.last ?? 0), 8.0, accuracy: 0.01)
        XCTAssertEqual(out.alignment.collapsedSpeechRuns, [])
    }

    func testKeepsAudioShorterThanTheAlignment() async throws {
        MockURLProtocol.handler = alignedResponse("吾輩は猫", audioBytesPerChunk: 1)
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
        XCTAssertLessThan(out.audioSeconds - (out.alignment.endTimes.last ?? 0), -1.9)
    }

    func testRejectsAGenerationThatStoppedTimingSpeech() async {
        MockURLProtocol.handler = response(
            streamed("吾輩は猫", endTimes: [0.5, 1.0, 1.0, 1.0], audioBytesPerChunk: 4_000))
        do {
            _ = try await makeService().synthesize(
                SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
            XCTFail("Expected a truncated generation to throw")
        } catch let error as WorkerTTSService.WorkerError {
            guard case .truncatedGeneration(let untimed) = error else {
                return XCTFail("Expected .truncatedGeneration, got \(error)")
            }
            XCTAssertEqual(untimed, 2)
        } catch {
            XCTFail("Expected a WorkerError, got \(error)")
        }
    }

    func testAcceptsAFlatTailThatCarriesNoSpeech() async throws {
        MockURLProtocol.handler = response(
            streamed("吾輩は。」", endTimes: [0.5, 1.0, 1.5, 1.5, 1.5], audioBytesPerChunk: 8_000))
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は。」", voice: .shizuka))
        XCTAssertEqual(out.alignment.untimedTrailingCharacters, 2)
        XCTAssertEqual(out.alignment.untimedTrailingSpeech, 0)
    }

    func testAcceptsCompleteAudioWithTrailingSilenceTheAlignmentDoesNotDescribe() async throws {
        MockURLProtocol.handler = response(
            streamed("吾輩は猫", endTimes: [0.03, 0.06, 0.09, 0.12], audioBytesPerChunk: 8_000))
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
        XCTAssertEqual(out.audioSeconds - (out.alignment.endTimes.last ?? 0), 1.88, accuracy: 0.01)
    }

    func testAcceptsAnAlignmentSlightlyAheadOfItsAudio() async throws {
        MockURLProtocol.handler = response(
            streamed("吾輩は猫", endTimes: [0.3, 0.6, 0.9, 1.05], audioBytesPerChunk: 4_000))
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
        XCTAssertEqual(out.audioSeconds - (out.alignment.endTimes.last ?? 0), -0.05, accuracy: 0.001)
    }

    func testKeepsAnAlignmentAheadOfItsAudio() async throws {
        MockURLProtocol.handler = response(
            streamed("吾輩は猫", endTimes: [0.4, 0.8, 1.2, 1.5], audioBytesPerChunk: 4_000))
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
        XCTAssertEqual(out.audioSeconds - (out.alignment.endTimes.last ?? 0), -0.5, accuracy: 0.001)
    }

    func testUnexplainedTrailingAudioLeavesTheAlignmentUntouched() async throws {
        MockURLProtocol.handler = response(
            streamed("吾輩は猫", endTimes: [0.15, 0.3, 0.45, 0.6], audioBytesPerChunk: 12_000))
        let out = try await makeService().synthesize(
            SynthesisRequest(text: "吾輩は猫", voice: .shizuka))
        XCTAssertEqual(out.audioSeconds - (out.alignment.endTimes.last ?? 0), 2.4, accuracy: 0.001)
        XCTAssertEqual(out.alignment.endTimes, [0.15, 0.3, 0.45, 0.6])
    }

    func testRepairsACollapsedPhraseAtSeal() async throws {
        let text = "吾輩は猫。名前はまだ無いのだ。"
        var ends: [Double] = [0.2, 0.4, 0.6, 0.8, 1.0]
        for i in 0..<9 { ends.append(1.0 + Double(i + 1) * 0.01) }
        ends.append(1.5)
        MockURLProtocol.handler = response(
            streamed(text, endTimes: ends, audioBytesPerChunk: 3_600))
        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(out.audioSeconds, 3.375, accuracy: 0.001)
        XCTAssertEqual(out.alignment.endTimes.last ?? 0, out.audioSeconds, accuracy: 1e-6)
        XCTAssertEqual(out.alignment.startTimes[14], 1.09 + 1.875, accuracy: 1e-6)
        XCTAssertEqual(out.alignment.startTimes[4], 0.8, accuracy: 1e-9)
        XCTAssertEqual(out.alignment.collapsedSpeechRuns, [])
    }


    func testPrefersTheForcedAlignmentTrailerOverTheStreamedTimings() async throws {
        let text = "吾輩は猫"
        var body = streamed(text, endTimes: [0.1, 0.2, 0.3, 0.4], audioBytesPerChunk: 8_000)
        body.append(Data(trailerLine(text, endTimes: [0.5, 1.0, 1.5, 2.0]).utf8))
        MockURLProtocol.handler = response(body)

        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(out.audioSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(out.alignment.endTimes, [0.5, 1.0, 1.5, 2.0])
    }

    func testAcceptsATrailerWithoutALoss() async throws {
        let text = "吾輩は猫"
        var body = streamed(text, endTimes: [0.1, 0.2, 0.3, 0.4], audioBytesPerChunk: 8_000)
        body.append(Data(trailerLine(text, endTimes: [0.5, 1.0, 1.5, 2.0], loss: nil).utf8))
        MockURLProtocol.handler = response(body)

        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(out.alignment.endTimes, [0.5, 1.0, 1.5, 2.0])
    }

    func testKeepsTheStreamedTimingsWhenTheTrailerDescribesOtherText() async throws {
        let text = "吾輩は猫"
        var body = streamed(text, endTimes: [0.5, 1.0, 1.5, 2.0], audioBytesPerChunk: 8_000)
        body.append(Data(trailerLine("吾輩は犬", endTimes: [0.5, 1.0, 1.5, 2.0]).utf8))
        MockURLProtocol.handler = response(body)

        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(out.alignment.characters.joined(), text)
        XCTAssertEqual(out.alignment.endTimes, [0.5, 1.0, 1.5, 2.0])
    }

    func testKeepsTheStreamedTimingsWhenTheTrailerDoesNotReachTheAudio() async throws {
        let text = "吾輩は猫"
        var body = streamed(text, endTimes: [0.5, 1.0, 1.5, 2.0], audioBytesPerChunk: 8_000)
        body.append(Data(trailerLine(text, endTimes: [0.1, 0.2, 0.3, 0.4]).utf8))
        MockURLProtocol.handler = response(body)

        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(out.alignment.endTimes, [0.5, 1.0, 1.5, 2.0])
    }

    func testKeepsTheStreamedTimingsWhenTheTrailerStopsTimingItsOwnSpeech() async throws {
        let text = "吾輩は猫"
        var body = streamed(text, endTimes: [0.5, 1.0, 1.5, 2.0], audioBytesPerChunk: 8_000)
        body.append(Data(trailerLine(text, endTimes: [0.5, 1.0, 2.0, 2.0]).utf8))
        MockURLProtocol.handler = response(body)

        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(out.alignment.endTimes, [0.5, 1.0, 1.5, 2.0])
    }

    func testATrailerIsNotForwardedAsAChunk() async throws {
        let text = "吾輩は猫"
        var body = streamed(text, endTimes: [0.5, 1.0, 1.5, 2.0], audioBytesPerChunk: 8_000)
        body.append(Data(trailerLine(text, endTimes: [0.5, 1.0, 1.5, 2.0]).utf8))
        MockURLProtocol.handler = response(body)

        let forwarded = ChunkCounter()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = WorkerTTSService(
            baseURL: URL(string: "https://test.example.com")!,
            userId: { "user-123" },
            session: URLSession(configuration: config),
            onChunk: { _, _, _ in forwarded.increment() })
        _ = try await service.synthesize(SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(forwarded.value, text.count)
    }

    func testRepairsACollapsedPhraseWhenNoTrailerArrives() async throws {
        let text = "吾輩は猫。名前はまだ無いのだ。"
        var ends: [Double] = [0.2, 0.4, 0.6, 0.8, 1.0]
        for i in 0..<9 { ends.append(1.0 + Double(i + 1) * 0.01) }
        ends.append(1.5)
        MockURLProtocol.handler = response(
            streamed(text, endTimes: ends, audioBytesPerChunk: 3_600))
        let out = try await makeService().synthesize(
            SynthesisRequest(text: text, voice: .shizuka))
        XCTAssertEqual(out.alignment.endTimes.last ?? 0, out.audioSeconds, accuracy: 1e-6)
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

    func testTheFallbackCapStaysWellBelowTheMeasuredTruncationCeiling() {
        let slowestCharsPerSecond = 3.6
        let earliestObservedCut = 534.3
        let predicted = Double(SynthesisLimits.maxRequestChars) / slowestCharsPerSecond
        XCTAssertLessThan(predicted, earliestObservedCut * 0.8)
    }

    func testADisplayedChapterAlwaysFitsInOneRequest() {
        XCTAssertLessThanOrEqual(Chapter.renderableHardMax, SynthesisLimits.maxRequestChars)
        XCTAssertLessThanOrEqual(Chapter.maxRenderableChars, Chapter.renderableHardMax)
    }

    func testAServedLimitIsHonouredOnlyInsideTheSanityRange() {
        let key = "reader.voiceCatalog.maxRequestChars"
        let defaults = UserDefaults(suiteName: "cap-\(UUID().uuidString)")!

        defaults.set(50_000, forKey: key)
        XCTAssertEqual(VoiceCatalog.maxRequestChars(defaults), SynthesisLimits.maxRequestChars)

        defaults.set(4_500, forKey: key)
        XCTAssertEqual(VoiceCatalog.maxRequestChars(defaults), 4_500)
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
            _ = try await makeService().synthesize(SynthesisRequest(text: "あ", voice: .shizuka))
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
            _ = try await makeService().synthesize(SynthesisRequest(text: "あ", voice: .shizuka))
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
            _ = try await makeService().synthesize(SynthesisRequest(text: "あ", voice: .shizuka))
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

private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
